# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = [
#   "torch==2.15.0",
#   "torchvision==0.29.2",
#   "transformers==5.23.0",
#   "sentence-transformers==6.3.0",
#   "coremltools==9.0",
#   "pillow==13.0.0",
#   "pandas==3.1.1",
#   "pyarrow==26.0.1",
#   "numpy==2.5.5",
# ]
# ///
"""Builds the search model: EmbeddingGemma 2 (google/embeddinggemma-2, Apache 2.0), which puts
text and photos in one space: "dog on the beach" near a photo of one, and near a message about
one, in any of its languages. Two Core ML functions, both float16 (8-bit weights save download but
the Neural Engine unpacks them, so they take more memory, not less):

- TextEncoder: token ids (padded with 0 to 64) -> the text's unit embedding.
- ImageEncoder: a photo squashed to 384 x 384 -> its unit embedding (the vision tower's 64 soft
  tokens among the prompt's ids, through the text model, as the library does).

    uv run scripts/image-search/convert.py <out folder>

The folder then holds `Encoders.mlpackage` (both, as its functions "image" and "text", sharing the
text model's weights), `embeddings.bin` (every token's input vector, which the app looks up),
`tokenizer.json` and `model.json`: sizes, the prompts a query and a message are read with, and the least similarity
a photo or a message must have to the words to be found (measured here). The script checks that
each Core ML model gives the embeddings PyTorch gives before it writes them.

float16 needs three changes to the model's arithmetic, which leave its results as they are:
RMSNorm scales its input down before squaring it, the mean pooling weighs before it sums, and the
vision pooler is a fixed matrix with its sqrt(hidden) scale folded into the standardization.
"""

import io
import json
import shutil
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import pandas as pd
import torch
import transformers.models.embedding_gemma2.modeling_embedding_gemma2 as gemma2_module
import transformers.models.gemma4.modeling_gemma4 as gemma4_module
from huggingface_hub import hf_hub_download
from PIL import Image
from sentence_transformers import SentenceTransformer

MODEL = "google/embeddinggemma-2"
# the revision the app's model is built from, so a rebuild gives the same model.
REVISION = "f9972ac22e696a105c482202646979e33e4b5a1e"
SIDE = 384
PATCH = 16
TEXT_LENGTH = 64
# what the model reads a search's words and a message with (its "query" and "document" prompts).
QUERY = "task: search result | query: "
DOCUMENT = "title: none | text: "


def additive_mask(config=None, inputs_embeds=None, attention_mask=None, **_):
    """The bidirectional mask as an additive float tensor: no boolean ops, which coremltools
    cannot convert. The sliding window (512) is longer than any input, so it is the same mask."""
    if attention_mask is None:
        return None
    keep = attention_mask.to(inputs_embeds.dtype)
    return (1.0 - keep)[:, None, None, :] * -10000.0


def float16_safe_norm(self, hidden_states):
    """RMSNorm with the input scaled down before it is squared: x/s * mean((x/s)^2)^-1/2 is
    x * mean(x^2)^-1/2, but (x/s)^2 stays inside float16 where x^2 (x up to ~3000) does not."""
    scaled = hidden_states * (1.0 / 64.0)
    mean_squared = scaled.pow(2).mean(-1, keepdim=True) + self.eps / 4096.0
    return scaled * torch.pow(mean_squared, -0.5)


gemma4_module.Gemma4RMSNorm._norm = float16_safe_norm
if hasattr(gemma2_module, "EmbeddingGemma2RMSNorm") and hasattr(gemma2_module.EmbeddingGemma2RMSNorm, "_norm"):
    gemma2_module.EmbeddingGemma2RMSNorm._norm = float16_safe_norm
for module in (gemma2_module, gemma4_module):
    for name in ("create_bidirectional_mask", "create_bidirectional_sliding_window_mask"):
        if hasattr(module, name):
            setattr(module, name, additive_mask)


def mean_pooled(states, mask):
    """The unit mean of the real tokens' states, weighed before it is summed: a sum of 68 states
    (each up to ~3000) leaves float16."""
    weights = mask.unsqueeze(-1).to(states.dtype)
    pooled = (states * (weights / weights.sum(1, keepdim=True))).sum(1)
    return torch.nn.functional.normalize(pooled, dim=-1)


class TextEncoder(torch.nn.Module):
    """The tokens' vectors (looked up by the app in `embeddings.bin`, padding's left zero) and
    which are real (1) or padding (0), both floats, to the text's unit embedding. No integers in
    the graph: the token lookup and its index checks are integer ops the Neural Engine cannot run,
    and iOS 27's compiler for it fails on them instead of leaving them to the CPU."""

    def __init__(self, language):
        super().__init__()
        self.language = language

    def forward(self, embeds, mask):
        states = self.language(inputs_embeds=embeds, attention_mask=mask).last_hidden_state
        return mean_pooled(states, mask)


def token_table(language):
    """Every token's input vector, as the model's embedding layer gives it (its scale included):
    rows of float16, in id order, for the app to read by id from a mapped file."""
    layer = language.get_input_embeddings()
    with torch.no_grad():
        rows = layer(torch.arange(layer.weight.shape[0])[None])[0]
    return rows.to(torch.float16).numpy()


# the off-Neural-Engine ops each function may have, and why: the image's pixels scaled to [0, 1]
# as they come in (Core ML's image input), before any of the model runs.
OFF_ENGINE = {"image": {"cast", "mul"}, "text": set()}


def check_engine(name, built):
    """Fails the build unless every op of `built` runs on the Neural Engine (but those
    `OFF_ENGINE` names): a model that falls back is slow to compile on the iPhone, and its
    compiler for the Neural Engine has crashed on ops it cannot run (iOS 27)."""
    from coremltools.models.compute_plan import MLComputePlan

    plan = MLComputePlan.load_from_path(built.get_compiled_model_path(), compute_units=ct.ComputeUnit.CPU_AND_NE)
    off, total = {}, 0

    def walk(block):
        nonlocal total
        for op in block.operations:
            for inner in op.blocks:
                walk(inner)
            kind = op.operator_name.split(".")[-1]
            if kind == "const":
                continue
            total += 1
            usage = plan.get_compute_device_usage_for_mlprogram_operation(op)
            if usage is None or type(usage.preferred_compute_device).__name__ != "MLNeuralEngineComputeDevice":
                off[kind] = off.get(kind, 0) + 1

    for function in plan.model_structure.program.functions.values():
        walk(function.block)
    unexpected = {kind: count for kind, count in off.items() if kind not in OFF_ENGINE[name]}
    print(f"{name}: {total - sum(off.values())} of {total} ops on the Neural Engine; off: {off or 'none'}")
    if unexpected:
        sys.exit(f"{name}: ops off the Neural Engine: {unexpected}")


class ImageEncoder(torch.nn.Module):
    """A 384 x 384 photo, its channels in [0, 1], to its unit embedding. The photo is cut into
    16 x 16 patches, row by row, each its pixels row by row (as the processor lays them out); the
    vision tower's soft tokens go in the image's place among the prompt's fixed ids (what the
    library's masked_scatter does, as a concatenation); the text model reads them; the mean."""

    def __init__(self, model, example):
        super().__init__()
        self.model = model
        ids, mask, positions = example["input_ids"], example["attention_mask"], example["image_position_ids"]
        image = model.config.image_token_id
        slots = (ids[0] == image).nonzero().flatten()
        self.first, self.count = int(slots[0]), len(slots)
        assert bool((slots == torch.arange(self.first, self.first + self.count)).all()), "the soft tokens are one run"
        self.register_buffer("text_ids", torch.where(ids == image, model.config.text_config.pad_token_id, ids))
        self.register_buffer("mask", mask)
        self.register_buffer("positions", positions)
        padding = (positions == -1).all(dim=-1)
        self.register_buffer("padding", padding)
        self.slots = positions.shape[1]
        tower = model.vision_tower
        k = tower.config.pooling_kernel_size
        length = positions.shape[1] // (k * k)
        clamped = positions.clamp(min=0)
        max_x = clamped[..., 0].max(dim=-1, keepdim=True)[0] + 1
        kernels = torch.div(clamped, k, rounding_mode="floor")
        kernels = kernels[..., 0] + (max_x // k) * kernels[..., 1]
        weights = torch.nn.functional.one_hot(kernels.long(), length).float() / (k * k)
        self.register_buffer("pool", weights.transpose(1, 2)[:, : self.count])
        root = tower.config.hidden_size ** 0.5
        if tower.config.standardize:
            self.register_buffer("scale", (root * tower.std_scale.float()).reshape(1, 1, -1))
            self.register_buffer("shift", (tower.std_bias.float() * tower.std_scale.float()).reshape(1, 1, -1))
        else:
            self.register_buffer("scale", torch.full((1, 1, 1), root))
            self.register_buffer("shift", torch.zeros(1, 1, 1))

    def patches(self, image):
        """[1, 3, 384, 384] -> [1, slots, 768]: 24 x 24 patches row by row, each its 16 x 16
        pixels row by row with their 3 channels, then the processor's padding (zeros)."""
        side = SIDE // PATCH
        cut = image.reshape(1, 3, side, PATCH, side, PATCH).permute(0, 2, 4, 3, 5, 1)
        cut = cut.reshape(1, side * side, PATCH * PATCH * 3)
        return torch.cat([cut, cut.new_zeros(1, self.slots - side * side, PATCH * PATCH * 3)], dim=1)

    def vision(self, pixels):
        tower = self.model.vision_tower
        embeds = tower.patch_embedder(pixels, self.positions, self.padding)
        states = tower.encoder(inputs_embeds=embeds, attention_mask=~self.padding,
                               pixel_position_ids=self.positions).last_hidden_state
        # the pooler's average over each k x k block as a fixed matrix (the positions never
        # change), its sqrt(hidden) scale folded into the standardization: no float16 overflow.
        states = states.masked_fill(self.padding.unsqueeze(-1), 0.0)
        pooled = self.pool @ states
        return (pooled * self.scale - self.shift).to(embeds.dtype)

    def forward(self, image):
        soft = self.model.embed_vision(inputs_embeds=self.vision(self.patches(image)))
        around = self.model.get_input_embeddings()(self.text_ids)
        embeds = torch.cat([around[:, : self.first], soft.to(around.dtype), around[:, self.first + self.count :]], dim=1)
        states = self.model.language_model(inputs_embeds=embeds, attention_mask=self.mask).last_hidden_state
        return mean_pooled(states, self.mask)


def exported(module, example):
    with torch.no_grad():
        graph = torch.export.export(module, (example,)).run_decompositions({})
    # the model's `image_mask | video_mask | audio_mask` on booleans: a logical or coremltools knows.
    for node in graph.graph.nodes:
        if node.target == torch.ops.aten.__or__.Tensor:
            node.target = torch.ops.aten.logical_or.default
    graph.graph_module.recompile()
    return graph


def cosines(a, b):
    a, b = np.asarray(a, dtype=np.float32), np.asarray(b, dtype=np.float32)
    a = a / np.linalg.norm(a, axis=-1, keepdims=True)
    b = b / np.linalg.norm(b, axis=-1, keepdims=True)
    return (a * b).sum(-1)


def threshold(positive, negative):
    """The least similarity to be found: above all but 5 % of the unrelated pairs, as long as that
    keeps most related ones (else the point between them). The model's cosines lie close (a photo
    of what the words say some 0.64 to 0.7, others 0.57 to 0.64): the order finds, this only
    keeps the unrelated tail out."""
    strict = float(np.percentile(negative, 95))
    return strict if (np.asarray(positive) >= strict).mean() >= 0.5 else float((np.median(positive) + strict) / 2)


CHAT = [
    ("Jedem v sobotu na Sněžku? Vezmi pohorky", "výlet na hory"),
    ("Kup cestou mlíko, chleba a nějaký sýr", "nákupní seznam"),
    ("Zítra mám v 8 zubaře, nestihnu ráno", "návštěva lékaře"),
    ("Posílám fakturu za září, splatnost do 15.", "platba za služby"),
    ("Ten film včera v kině byl fakt hroznej", "recenze filmu"),
    ("Malej má horečku 38,5, zůstanu s ním doma", "nemocné dítě"),
    ("Letenky do Lisabonu jsou teď za 1900 tam i zpět", "levné lety na dovolenou"),
    ("Pronajímatel chce zvednout nájem o tři tisíce", "bydlení a peníze"),
    ("Kdo jde v pátek na pivo k Ferdovi?", "posezení v hospodě"),
    ("Auto neprošlo STK, prý brzdy", "oprava vozu"),
    ("Mám nový foťák, Sony A7 IV, je to bomba", "fotografická technika"),
    ("Babička slaví v neděli osmdesátiny, přijdeš?", "rodinná oslava narozenin"),
    ("Na chalupě praskla trubka, všude voda", "havárie vody"),
    ("Spadla mi appka při přihlašování, hází chybu 500", "problém s aplikací"),
    ("Pejsek se zaběhl v lese u Hostivaře", "ztracený pes"),
    ("Zkouška z matiky byla za jedna!", "výsledek testu ve škole"),
    ("Na Vánoce jedem k našim do Brna", "svátky u rodičů"),
    ("Upekla jsem štrúdl podle babiččina receptu", "pečení moučníku"),
    ("Byla jsem si zaběhat 10 km pod 50 minut", "sportovní výkon"),
    ("Prosím pošli mi heslo k wifi na chatě", "připojení k internetu"),
    ("Volala pojišťovna, kryjou jen polovinu škody", "pojistná událost"),
    ("Kocour zase rozškrábal gauč", "domácí mazlíček dělá neplechu"),
    ("Hraje Sparta zítra doma?", "fotbalový zápas"),
    ("Nestíhám deadline, šéf bude zuřit", "stres v práci"),
    ("Jaký je kód na zvonek u vás?", "jak se dostat do domu"),
    ("Objednal jsem pizzu, bude tu za půl hodiny", "jídlo s sebou"),
    ("Mám dva lístky na Coldplay, chceš jeden?", "koncert"),
    ("Banka mi zablokovala kartu kvůli podezřelé platbě", "problém s bankou"),
    ("Na horách napadlo 30 cm prašanu", "lyžování"),
    ("Potřebuju půjčit vrtačku na víkend", "nářadí"),
]


def main(out: Path):
    out.mkdir(parents=True, exist_ok=True)
    eg = SentenceTransformer(MODEL, revision=REVISION, device="cpu", model_kwargs={"dtype": torch.float32},
                             config_kwargs={"audio_config": None})
    processor = eg[0].processor
    # 70 soft tokens: better recall than 280, and five times as fast.
    processor.image_processor.image_seq_length = 70
    processor.image_processor.max_soft_tokens = 70
    tokenizer = processor.tokenizer
    model = eg[0].auto_model.eval()
    for config in (model.config, model.language_model.config, model.vision_tower.config):
        config._attn_implementation = "eager"

    def ids(texts):
        return tokenizer(texts, return_tensors="pt", padding="max_length", max_length=TEXT_LENGTH,
                         truncation=True)["input_ids"].int()

    print("converting the text encoder", flush=True)
    table = token_table(model.language_model)

    def token_inputs(texts):
        """What the app gives the text encoder for each text: its tokens' rows of the table
        (zeros for padding) and its mask."""
        batch = ids(texts).numpy()
        mask = (batch != 0).astype(np.float32)
        embeds = table[batch].astype(np.float32) * mask[..., None]
        return embeds, mask

    text = TextEncoder(model.language_model).eval()
    example_embeds, example_mask = token_inputs([QUERY + "výlet na hory"])
    with torch.no_grad():
        graph = torch.export.export(text, (torch.from_numpy(example_embeds), torch.from_numpy(example_mask)))
        graph = graph.run_decompositions({})
    text_model = ct.convert(
        graph,
        inputs=[ct.TensorType(name="embeds", shape=example_embeds.shape, dtype=np.float16),
                ct.TensorType(name="mask", shape=example_mask.shape, dtype=np.float16)],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
    )
    check_engine("text", text_model)

    print("converting the image encoder", flush=True)
    square = Image.radial_gradient("L").convert("RGB").resize((SIDE, SIDE))
    image = ImageEncoder(model, eg[0].preprocess([square])).eval()
    as_tensor = torch.from_numpy(np.asarray(square, dtype=np.float32) / 255).permute(2, 0, 1)[None].contiguous()
    # the patches laid out here are the processor's.
    assert torch.allclose(image.patches(as_tensor), eg[0].preprocess([square])["pixel_values"], atol=1e-6)
    image_model = ct.convert(
        exported(image, as_tensor),
        inputs=[ct.ImageType(name="image", shape=(1, 3, SIDE, SIDE), scale=1 / 255, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
    )

    check_engine("image", image_model)

    # the Core ML models give what the library gives.
    photos_cs = pd.read_parquet(hf_hub_download("floschne/xm3600_1k", "data/cs-00000-of-00001.parquet",
                                                repo_type="dataset")).iloc[:200]
    photos = [Image.open(io.BytesIO(row["bytes"])).convert("RGB").resize((SIDE, SIDE), Image.BICUBIC)
              for row in photos_cs.image]
    library_photos = eg.encode(photos[:20], normalize_embeddings=True)
    got_photos = [image_model.predict({"image": photo})["embedding"][0] for photo in photos[:20]]
    words = [QUERY + "pes na pláži", DOCUMENT + "Zítra jedeme na hory, vezmi lyže"]
    library_words = eg.encode(words, normalize_embeddings=True)
    got_words = []
    for w in words:
        embeds, mask = token_inputs([w])
        got_words.append(text_model.predict({"embeds": embeds.astype(np.float16), "mask": mask.astype(np.float16)})["embedding"][0])
    image_match, text_match = float(cosines(library_photos, got_photos).min()), float(cosines(library_words, got_words).min())
    print(f"Core ML vs the library: image {image_match:.4f}, text {text_match:.4f}")
    # the image encoder on the Neural Engine drifts in float16 (about 0.9 to 0.95 to PyTorch's,
    # 1.0 on the GPU): its recall stays above SigLIP 2's (58 vs 50 % in Czech), and the GPU is
    # not the iPhone's to use in the background, where most photos are read.
    if image_match < 0.85 or text_match < 0.99:
        sys.exit("the Core ML models differ from the library")

    # how alike the words are to the photos they describe, and to others: the photos' threshold.
    # the photos as the app reads them: on the Neural Engine, whose float16 drifts a little.
    captions = [list(c)[0] for c in photos_cs.captions]
    photo_embeddings = np.stack([image_model.predict({"image": photo})["embedding"][0] for photo in photos])
    photo_embeddings /= np.linalg.norm(photo_embeddings, axis=-1, keepdims=True)
    caption_embeddings = eg.encode([QUERY + c for c in captions], normalize_embeddings=True)
    scores = caption_embeddings @ photo_embeddings.T
    positive = np.diag(scores)
    negative = scores[~np.eye(len(scores), dtype=bool)]
    photo_threshold = threshold(positive, negative)
    # and a message to the words about it, both less the messages' mean (as the app keeps them).
    messages = eg.encode([DOCUMENT + m for m, _ in CHAT], normalize_embeddings=True)
    queries = eg.encode([QUERY + q for _, q in CHAT], normalize_embeddings=True)
    mean = messages.mean(0, keepdims=True)
    centred = lambda e: (e - mean) / np.linalg.norm(e - mean, axis=-1, keepdims=True)
    scores = centred(queries) @ centred(messages).T
    message_threshold = threshold(np.diag(scores), scores[~np.eye(len(scores), dtype=bool)])
    print(f"thresholds: photos {photo_threshold:.3f}, messages {message_threshold:.3f}")

    # one model with two functions, "image" and "text": the text model's weights, which both
    # run, are kept once.
    parts = out / "parts"
    shutil.rmtree(parts, ignore_errors=True)
    parts.mkdir()
    for name, built in (("image", image_model), ("text", text_model)):
        built.short_description = f"{MODEL}, {name} to unit embedding"
        built.license = "Apache-2.0"
        built.save(str(parts / f"{name}.mlpackage"))
    encoders = ct.utils.MultiFunctionDescriptor()
    for name in ("image", "text"):
        encoders.add_function(str(parts / f"{name}.mlpackage"), src_function_name="main", target_function_name=name)
    encoders.default_function_name = "image"
    target = out / "Encoders.mlpackage"
    shutil.rmtree(target, ignore_errors=True)
    ct.utils.save_multifunction(encoders, str(target))
    shutil.rmtree(parts)
    # the cache's file is read-only: a copy of its bytes, not of its mode.
    # the tokens' rows, float16, in id order: the app maps the file and reads a row by its id.
    table.astype("<f2").tofile(out / "embeddings.bin")
    (out / "tokenizer.json").unlink(missing_ok=True)
    shutil.copyfile(hf_hub_download(MODEL, "tokenizer.json", revision=REVISION), out / "tokenizer.json")
    (out / "model.json").write_text(json.dumps({
        "model": MODEL,
        "side": SIDE,
        "textLength": TEXT_LENGTH,
        "dimension": int(library_photos.shape[-1]),
        "lowercase": False,
        "padId": int(tokenizer.pad_token_id),
        "eosId": int(tokenizer.eos_token_id),
        "tokens": int(table.shape[0]),
        "width": int(table.shape[1]),
        "queryPrompt": QUERY,
        "documentPrompt": DOCUMENT,
        "photoSimilarity": round(photo_threshold, 3),
        "messageSimilarity": round(message_threshold, 3),
    }, indent=2) + "\n")
    print(f"written to {out}")


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "build/image-search"))

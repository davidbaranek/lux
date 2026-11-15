# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = [
#   "torch==2.7.0",
#   "transformers==4.56.2",
#   "coremltools==9.0",
#   "sentencepiece==0.2.1",
#   "pillow==11.3.0",
#   "numpy<2.3",
# ]
# ///
"""Builds the image search model: SigLIP 2 (google/siglip2-base-patch16-256, Apache 2.0) as two
Core ML models, an image encoder and a text encoder, whose embeddings share one space, plus the
tokenizer the text encoder reads.

    uv run scripts/image-search/convert.py <out folder>

The folder then holds `ImageEncoder.mlpackage`, `TextEncoder.mlpackage`, `tokenizer.json` and
`model.json` (sizes and the score's scale and bias). The script checks that each Core ML model
gives the embeddings PyTorch gives before it writes them.
"""

import json
import shutil
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
from huggingface_hub import hf_hub_download
from PIL import Image
from transformers import AutoModel, AutoProcessor

MODEL = "google/siglip2-base-patch16-256"
# the revision the app's model is built from, so a rebuild gives the same model.
REVISION = "main"
SIDE = 256
TEXT_LENGTH = 64


class ImageEncoder(torch.nn.Module):
    """Pixels in [-1, 1] to the image's unit embedding."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, pixels):
        embedding = self.model.get_image_features(pixel_values=pixels)
        return embedding / embedding.norm(dim=-1, keepdim=True)


class TextEncoder(torch.nn.Module):
    """Token ids (padded to TEXT_LENGTH) to the text's unit embedding."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, ids):
        embedding = self.model.get_text_features(input_ids=ids)
        return embedding / embedding.norm(dim=-1, keepdim=True)


def quantized(model):
    """Weights as 8-bit integers, one scale per output channel: half the 16-bit size."""
    config = OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", granularity="per_channel"))
    return linear_quantize_weights(model, config)


def cosine(a, b):
    a, b = np.asarray(a, dtype=np.float32).ravel(), np.asarray(b, dtype=np.float32).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))


def main(out: Path):
    out.mkdir(parents=True, exist_ok=True)
    model = AutoModel.from_pretrained(MODEL, revision=REVISION, dtype=torch.float32).eval()
    processor = AutoProcessor.from_pretrained(MODEL, revision=REVISION)

    # the image: squashed to SIDE × SIDE (no crop), as the processor does; [0, 255] → [-1, 1].
    image_example = torch.rand(1, 3, SIDE, SIDE) * 2 - 1
    traced_image = torch.jit.trace(ImageEncoder(model), image_example)
    image_model = ct.convert(
        traced_image,
        inputs=[ct.ImageType(name="image", shape=(1, 3, SIDE, SIDE), scale=1 / 127.5, bias=[-1, -1, -1],
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
    )
    # the image encoder stays in 16-bit floats: 8-bit weights move its embeddings too far (0.92
    # cosine to PyTorch's); the text encoder's are mostly its 256k-word table, which 8 bits keep.

    text_example = torch.zeros(1, TEXT_LENGTH, dtype=torch.int32)
    traced_text = torch.jit.trace(TextEncoder(model), text_example)
    text_model = ct.convert(
        traced_text,
        inputs=[ct.TensorType(name="ids", shape=(1, TEXT_LENGTH), dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
    )
    text_model = quantized(text_model)

    # the Core ML models give what PyTorch gives.
    picture = Image.radial_gradient("L").convert("RGB").resize((SIDE, SIDE))
    pixels = processor(images=picture, return_tensors="pt")["pixel_values"]
    with torch.no_grad():
        expected_image = ImageEncoder(model)(pixels).numpy()
    got_image = image_model.predict({"image": picture})["embedding"]
    words = "a photo of a dog on the beach"
    ids = processor(text=[words], padding="max_length", max_length=TEXT_LENGTH, return_tensors="pt")["input_ids"]
    with torch.no_grad():
        expected_text = TextEncoder(model)(ids).numpy()
    got_text = text_model.predict({"ids": ids.numpy().astype(np.int32)})["embedding"]
    image_match, text_match = cosine(expected_image, got_image), cosine(expected_text, got_text)
    print(f"Core ML vs PyTorch: image {image_match:.4f}, text {text_match:.4f}")
    if min(image_match, text_match) < 0.98:
        sys.exit("the Core ML models differ from PyTorch")

    for name, built in (("ImageEncoder", image_model), ("TextEncoder", text_model)):
        target = out / f"{name}.mlpackage"
        shutil.rmtree(target, ignore_errors=True)
        built.short_description = f"{MODEL} {name}, unit embeddings"
        built.license = "Apache-2.0"
        built.save(str(target))
    shutil.copy(hf_hub_download(MODEL, "tokenizer.json", revision=REVISION), out / "tokenizer.json")
    (out / "model.json").write_text(json.dumps({
        "model": MODEL,
        "side": SIDE,
        "textLength": TEXT_LENGTH,
        "dimension": int(expected_image.shape[-1]),
        # SigLIP's score: sigmoid(scale · cosine + bias), the chance that the text fits the image.
        "scale": float(model.logit_scale.exp()),
        "bias": float(model.logit_bias),
        # SigLIP 2 learned from lowercased text.
        "lowercase": True,
        "padId": int(processor.tokenizer.pad_token_id),
        "eosId": int(processor.tokenizer.eos_token_id),
    }, indent=2) + "\n")
    print(f"written to {out}")


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "build/image-search"))

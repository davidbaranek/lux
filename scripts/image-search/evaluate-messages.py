# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = [
#   "torch==2.15.0",
#   "torchvision==0.29.2",
#   "transformers==5.23.0",
#   "sentence-transformers==6.3.0",
#   "pillow==13.0.0",
#   "numpy==2.5.5",
# ]
# ///
"""Measures how search by meaning finds messages, each read alone or with the messages before it,
on conversations written for this test (Czech and English, no real person's messages): recall@k
and MRR of each way of reading, at the encoder's length (`TEXT_LENGTH` in convert.py) and longer.

    uv run scripts/image-search/evaluate-messages.py

It runs EmbeddingGemma 2 in PyTorch (the weights convert.py builds the app's model from; the
Core ML model gives the same embeddings, convert.py checks it), and reads each message as
`MessageMeaning` does (`conversations.py`): the oldest context lines go first when they do not
fit, never the message, and the embeddings lose their mean before they are compared.

    uv run scripts/image-search/evaluate-messages.py --similarity

says whether the model's `messageSimilarity` keeps each reading's hits and keeps out the noise.
"""

import sys

import numpy as np
import torch
from sentence_transformers import SentenceTransformer

import conversations
from conversations import CHATS, DOCUMENT, SHORT, WHOLE, messages, threshold

MODEL = "google/embeddinggemma-2"
REVISION = "f9972ac22e696a105c482202646979e33e4b5a1e"
QUERY = "task: search result | query: "


def tokens(model, text):
    return len(model.tokenizer(text)["input_ids"])


def document(model, length, form, chat, index, count, names=True):
    """A message read as `conversations.document` reads it, to `length` tokens."""
    return conversations.document(lambda text: tokens(model, text) <= length, chat, index, count, form, names)


def centred(embeddings, mean):
    out = embeddings - mean
    return out / np.linalg.norm(out, axis=1, keepdims=True)


def evaluate(model, length, documents, kept):
    """Recall@1/5/10 and MRR for both query sets; `kept` says which messages have an embedding."""
    model.max_seq_length = length
    ids = [(chat, index) for chat, index, *_ in messages()]
    embedded = [i for i, key in enumerate(ids) if kept(key)]
    docs = model.encode([documents[ids[i]] for i in embedded], normalize_embeddings=True)
    mean = docs.mean(0)
    docs = centred(docs, mean)
    results = {}
    for name, queries in (("short", SHORT), ("whole", WHOLE)):
        q = centred(model.encode([QUERY + text for text, *_ in queries], normalize_embeddings=True), mean)
        scores = q @ docs.T
        ranks = []
        for row, (_, chat, index) in zip(scores, queries):
            order = [ids[embedded[i]] for i in np.argsort(-row)]
            ranks.append(order.index((chat, index)) + 1 if (chat, index) in order else None)
        n = len(ranks)
        results[name] = {
            "R@1": sum(r is not None and r <= 1 for r in ranks) / n,
            "R@3": sum(r is not None and r <= 3 for r in ranks) / n,
            "R@5": sum(r is not None and r <= 5 for r in ranks) / n,
            "R@10": sum(r is not None and r <= 10 for r in ranks) / n,
            "MRR": sum(1 / r for r in ranks if r) / n,
        }
    return results


def similarities(model, length, documents, kept, thresholds):
    """The centred cosines of each query to the message it looks for, and to the others: to
    those of other chats (noise), and to the others of its own chat (the messages a reply
    answers, related). How many expected hits each threshold keeps, and how much noise."""
    model.max_seq_length = length
    ids = [(chat, index) for chat, index, *_ in messages()]
    embedded = [i for i, key in enumerate(ids) if kept(key)]
    docs = model.encode([documents[ids[i]] for i in embedded], normalize_embeddings=True)
    mean = docs.mean(0)
    docs = centred(docs, mean)
    out = {}
    for name, queries in (("short", SHORT), ("whole", WHOLE)):
        q = centred(model.encode([QUERY + text for text, *_ in queries], normalize_embeddings=True), mean)
        scores = q @ docs.T
        hits, noise, near = [], [], []
        for row, (_, chat, index) in zip(scores, queries):
            for column, i in enumerate(embedded):
                key = ids[i]
                (hits if key == (chat, index) else near if key[0] == chat else noise).append(row[column])
        n_hits = len(SHORT if name == "short" else WHOLE)
        out[name] = {
            "hits": np.array(hits), "noise": np.array(noise), "near": np.array(near),
            "missing": n_hits - len(hits),
            "kept": {t: (np.array(hits) >= t).sum() for t in thresholds},
            "noise kept": {t: (np.array(noise) >= t).mean() for t in thresholds},
        }
    return out


def similarity_report(model, length):
    """`--similarity`: whether the model's `messageSimilarity` (convert.py measures it on lone
    messages) keeps the hits of each reading and keeps out the noise."""
    keys = [(chat, index) for chat, index, *_ in messages()]
    plain = {key: DOCUMENT + CHATS[key[0]][key[1]][1] for key in keys}
    reading = {key: document(model, length, "title", *key, 4) for key in keys}
    readings = (("body, at least 12 chars (reading 1)", plain, lambda key: len(CHATS[key[0]][key[1]][1]) >= 12),
                ("title, 4 before, at least 3 chars (reading 2)", reading, lambda key: len(CHATS[key[0]][key[1]][1]) >= 3))
    thresholds = [float(arg) for arg in THRESHOLDS]
    print("| reading | queries | hit cosine min / median | noise p95 / max | own chat's others median | "
          + " | ".join(f"hits ≥ {t} (noise ≥)" for t in thresholds) + " | convert.py's rule |")
    print("|---|---|---|---|---|" + "---|" * len(thresholds) + "---|")
    for name, documents, kept in readings:
        result = similarities(model, length, documents, kept, thresholds)
        both_hits = np.concatenate([result[k]["hits"] for k in result])
        both_noise = np.concatenate([result[k]["noise"] for k in result])
        for queries, r in result.items():
            total = len(r["hits"]) + r["missing"]
            cells = " | ".join(f"{r['kept'][t]}/{total} ({r['noise kept'][t]:.1%})" for t in thresholds)
            print(f"| {name} | {queries} | {r['hits'].min():.3f} / {np.median(r['hits']):.3f} "
                  f"| {np.percentile(r['noise'], 95):.3f} / {r['noise'].max():.3f} | {np.median(r['near']):.3f} "
                  f"| {cells} | {threshold(both_hits, both_noise):.3f} |")
    model.max_seq_length = length
    measured = conversations.message_threshold(lambda texts: model.encode(texts, normalize_embeddings=True),
                                               lambda text: tokens(model, text) <= length, QUERY)
    print(f"\nconvert.py's messageSimilarity for this reading: {measured:.3f}")


# the thresholds `--similarity` checks: the model's own (model.json, as convert.py measures it),
# and the app's default for a model.json without one.
THRESHOLDS = ("0.106", "0.25")


def main():
    model = SentenceTransformer(MODEL, revision=REVISION, device="cpu", model_kwargs={"dtype": torch.float32})
    if sys.argv[1:] == ["--similarity"]:
        similarity_report(model, 64)
        return
    lengths = [int(arg) for arg in sys.argv[1:]] or [64]
    keys = [(chat, index) for chat, index, *_ in messages()]
    every = lambda _: True
    at_least = lambda least: lambda key: len(CHATS[key[0]][key[1]][1]) >= least
    rows = []
    for length in lengths:
        plain = {key: DOCUMENT + CHATS[key[0]][key[1]][1] for key in keys}
        rows.append((length, "body, at least 12 chars (before)", evaluate(model, length, plain, at_least(12))))
        rows.append((length, "body, every message", evaluate(model, length, plain, every)))
        for form, counts in (("text", (1, 2, 3, 4)), ("title", (1, 2, 3, 4, 5, 6))):
            for count in counts:
                docs = {key: document(model, length, form, *key, count) for key in keys}
                rows.append((length, f"{form}, {count} before, names", evaluate(model, length, docs, every)))
        for count in (3, 4):
            docs = {key: document(model, length, "title", *key, count, names=False) for key in keys}
            rows.append((length, f"title, {count} before, no names", evaluate(model, length, docs, every)))
            docs = {key: document(model, length, "title", *key, count) for key in keys}
            for least in (2, 3, 4, 12):
                rows.append((length, f"title, {count} before, names, at least {least} chars",
                             evaluate(model, length, docs, at_least(least))))
    print(f"{len(SHORT)} short-reply queries, {len(WHOLE)} whole-message queries, {len(keys)} messages\n")
    print("| tokens | reading | short R@1 | R@3 | R@5 | R@10 | MRR | whole R@1 | R@3 | R@5 | MRR |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for length, name, result in rows:
        s, w = result["short"], result["whole"]
        print(f"| {length} | {name} | {s['R@1']:.2f} | {s['R@3']:.2f} | {s['R@5']:.2f} | {s['R@10']:.2f} "
              f"| {s['MRR']:.3f} | {w['R@1']:.2f} | {w['R@3']:.2f} | {w['R@5']:.2f} | {w['MRR']:.3f} |")


if __name__ == "__main__":
    main()



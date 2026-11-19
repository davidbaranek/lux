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
`MessageMeaning` does: the newest context lines go first when they do not fit, never the message,
and the embeddings lose their mean before they are compared.
"""

import sys

import numpy as np
import torch
from sentence_transformers import SentenceTransformer

MODEL = "google/embeddinggemma-2"
REVISION = "f9972ac22e696a105c482202646979e33e4b5a1e"
QUERY = "task: search result | query: "
DOCUMENT = "title: none | text: "
# how much of each message before one the store gives (lux-store's CONTEXT_CHARS).
CONTEXT_CHARS = 100

# Conversations: (chat, sender, text, thread root id or None). Ids are each message's index. A
# message in a thread names its root; the root and the chat's own messages name none.
CHATS = {
    "dinner": [
        ("Anna", "Are you guys free for dinner this weekend? We'd love to have you over", None),
        ("Me", "We'd love to! Which day works for you?", None),
        ("Anna", "Friday or Saturday, whichever suits", None),
        ("Me", "Friday is better for us", None),
        ("Anna", "yes, Friday at 5 at ours", None),
        ("Me", "Should we bring anything?", None),
        ("Anna", "just wine", None),
        ("Me", "👍", None),
    ],
    "work": [
        ("Tom", "The release build failed again on CI, the signing certificate expired", None),
        ("Me", "Can you renew it?", None),
        ("Tom", "done, valid until next March", None),
        ("Me", "rerun the pipeline then", None),
        ("Tom", "green now", None),
        ("Tom", "Also the staging database is running out of disk space", None),
        ("Me", "how much is left?", None),
        ("Tom", "about 3 GB", None),
        ("Me", "ok", None),
    ],
    "family": [
        ("Mum", "Did you book the flights for Christmas?", None),
        ("Me", "Not yet, prices are crazy", None),
        ("Mum", "Dad says try a Tuesday, it's cheaper", None),
        ("Me", "booked, landing on the 23rd at 14:10", None),
        ("Mum", "Who picks you up from the airport?", None),
        ("Me", "Dad, he offered", None),
        ("Mum", "Your sister's birthday is the week after, any gift ideas?", None),
        ("Me", "a yoga mat maybe", None),
        ("Mum", "good idea", None),
    ],
    "football": [
        ("Jake", "Five-a-side this Thursday, who's in?", None),
        ("Sam", "in", 0),
        ("Lucy", "can't, working late", 0),
        ("Me", "I'll bring the ball", 0),
        ("Sam", "pitch 3 at 7pm", 0),
        ("Jake", "Anyone selling a bike? My nephew needs one for school", None),
        ("Lucy", "mine's in the shed, 50 quid", None),
        ("Jake", "deal", None),
    ],
    "neighbours": [
        ("Pete", "Barbecue at ours on Saturday, bring your own meat", None),
        ("Me", "sounds great, what time?", None),
        ("Pete", "from 3", None),
        ("Pete", "The bins go out on Wednesday this week because of the bank holiday", None),
        ("Me", "thanks for the heads up", None),
        ("Pete", "Somebody's car alarm went off at 3am again, the silver Skoda by the gate", None),
        ("Me", "same here, woke the baby", None),
    ],
    "chalupa": [
        ("Jana", "Jedeme o víkendu na chalupu? Potřebuju vědět, kolik nás bude", None),
        ("Petr", "My jedeme všichni čtyři", None),
        ("Já", "my jen ve dvou", None),
        ("Jana", "Kdo veze nákup?", None),
        ("Petr", "beru to", None),
        ("Jana", "A klíče?", None),
        ("Já", "má je soused, pan Novák", None),
        ("Jana", "super", None),
    ],
    "prace": [
        ("Martin", "Zítra máme poradu s klientem, můžeme ji posunout na odpoledne?", None),
        ("Já", "na kolik?", None),
        ("Martin", "ve 14:30 u nich v kanceláři", None),
        ("Já", "Mám vzít notebook s prezentací?", None),
        ("Martin", "jo, a tištěnou smlouvu", None),
        ("Martin", "Faktura za říjen ještě nedorazila, můžeš to urgovat?", None),
        ("Já", "urgoval jsem, pošlou do pátku", None),
        ("Martin", "díky", None),
    ],
    "rodina": [
        ("Máma", "Kdy přijedete na Vánoce?", None),
        ("Já", "23. odpoledne", None),
        ("Máma", "Co chcete k večeři, kapra nebo řízek?", None),
        ("Já", "řízek, děti kapra nejí", None),
        ("Máma", "Babička je v nemocnici, operace kyčle dopadla dobře", None),
        ("Já", "díky bohu, pozdravuj ji", None),
    ],
    "byt": [
        ("Lucie", "Kdo zaplatí nájem za prosinec?", None),
        ("Ondra", "já, pošlu to v pondělí", 0),
        ("Lucie", "a elektřina?", 0),
        ("Ondra", "1 850 Kč, rozdělíme napůl", 0),
        ("Lucie", "Pračka zase teče, volala jsem opraváře", None),
        ("Ondra", "přijde ve středu ráno", None),
        ("Lucie", "ok", None),
    ],
    "sport": [
        ("Honza", "Hrajeme ve čtvrtek fotbal?", None),
        ("Já", "jasně, v kolik?", None),
        ("Honza", "v 7 na Strahově", None),
        ("Honza", "Potřebuju na víkend půjčit kolo, nemáš?", None),
        ("Já", "mám, stav se", None),
        ("Honza", "👍", None),
    ],
}

# Queries and the message each looks for. Short replies that mean something only with what came
# before them, then whole messages (which context must not push down).
SHORT = [
    ("what time is dinner at Anna's", "dinner", 4),
    ("what should we bring to Anna's dinner", "dinner", 6),
    ("how long is the signing certificate valid", "work", 2),
    ("did the release build pass after the rerun", "work", 4),
    ("free disk space on the staging database", "work", 7),
    ("when does my Christmas flight land", "family", 3),
    ("who picks me up from the airport", "family", 5),
    ("birthday present for my sister", "family", 7),
    ("who can't come to five-a-side", "football", 2),
    ("which pitch is five-a-side on", "football", 4),
    ("how much is Lucy's bike", "football", 6),
    ("what time does Pete's barbecue start", "neighbours", 2),
    ("kdo nakoupí na chalupu", "chalupa", 4),
    ("kdo má klíče od chalupy", "chalupa", 6),
    ("kolik lidí jede na chalupu od Petra", "chalupa", 1),
    ("v kolik je porada s klientem", "prace", 2),
    ("co vzít na schůzku s klientem", "prace", 4),
    ("kdy přijde faktura za říjen", "prace", 6),
    ("kdy přijedeme na Vánoce", "rodina", 1),
    ("co bude k vánoční večeři", "rodina", 3),
    ("kdo platí nájem za prosinec", "byt", 1),
    ("kolik stojí elektřina", "byt", 3),
    ("kdy přijde opravář pračky", "byt", 5),
    ("kde hrajeme ve čtvrtek fotbal", "sport", 2),
    ("kdo mi půjčí kolo", "sport", 4),
]
WHOLE = [
    ("dinner invitation for the weekend", "dinner", 0),
    ("release build failing on CI", "work", 0),
    ("staging database running out of space", "work", 5),
    ("booking Christmas flights", "family", 0),
    ("bike for a nephew", "football", 5),
    ("bins collection moved because of the holiday", "neighbours", 3),
    ("car alarm at night", "neighbours", 5),
    ("barbecue invitation", "neighbours", 0),
    ("kolik nás jede na chalupu", "chalupa", 0),
    ("posunutí porady s klientem", "prace", 0),
    ("faktura nedorazila", "prace", 5),
    ("babička po operaci", "rodina", 4),
    ("pračka teče", "byt", 4),
    ("nájem za prosinec", "byt", 0),
    ("hrajeme fotbal ve čtvrtek", "sport", 0),
]


def messages():
    """Every message: (chat, index, sender, text, thread)."""
    return [(chat, index, sender, text, thread) for chat, lines in CHATS.items()
            for index, (sender, text, thread) in enumerate(lines)]


def context(chat, index, count):
    """The `count` messages before one, oldest first: its thread's (the root and the replies
    before it) when it is in one, else its chat's own (not threads' replies)."""
    lines = CHATS[chat]
    thread = lines[index][2]
    before = [i for i in range(index) if (lines[i][2] == thread if thread is not None else lines[i][2] is None)
              or (thread is not None and i == thread)]
    return [lines[i] for i in before[-count:]]


def tokens(model, text):
    return len(model.tokenizer(text)["input_ids"])


def document(model, length, form, chat, index, count, names=True):
    """A message as the model reads it: the context lines (each cut to the store's
    CONTEXT_CHARS) that fit in `length` tokens, the oldest going first, then the message, which is
    never cut for them (`MessageToEmbed.text` in the app)."""
    sender, text, _ = CHATS[chat][index]
    line = (lambda s, t: f"{s}: {t}") if names else (lambda s, t: t)
    lines = [line(s, t[:CONTEXT_CHARS]) for s, t, _ in context(chat, index, count)]
    while True:
        if form == "text":
            built = DOCUMENT + "\n".join([*lines, line(sender, text)])
        else:  # the context as the document's title
            title = " / ".join(lines) if lines else "none"
            built = f"title: {title} | text: {line(sender, text)}"
        if not lines or tokens(model, built) <= length:
            return built
        lines = lines[1:]


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


def main():
    model = SentenceTransformer(MODEL, revision=REVISION, device="cpu", model_kwargs={"dtype": torch.float32})
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



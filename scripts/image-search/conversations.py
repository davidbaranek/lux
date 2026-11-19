"""Conversations written for search by meaning's measurements (Czech and English, no real
person's messages), and how the app reads a message for its embedding: convert.py measures the
model's `messageSimilarity` on them, evaluate-messages.py how each way of reading finds them.
"""

import numpy as np

# how messages are read now (`MessageMeaning.reading`, 2): with the CONTEXT_MESSAGES before it
# (lux-store), each cut to CONTEXT_CHARS, as the title; a message under MIN_CHARS is not read.
CONTEXT_MESSAGES = 4
CONTEXT_CHARS = 100
MIN_CHARS = 3
DOCUMENT = "title: none | text: "

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


def document(fits, chat, index, count=CONTEXT_MESSAGES, form="title", names=True):
    """A message as the model reads it (`MessageToEmbed.text` in the app): the context lines,
    each cut to CONTEXT_CHARS, as the title (`form="text"`: before the message in the text); the
    oldest go first until `fits` says the whole fits the encoder, never the message."""
    sender, text, _ = CHATS[chat][index]
    line = (lambda s, t: f"{s}: {t}") if names else (lambda s, t: t)
    lines = [line(s, t[:CONTEXT_CHARS]) for s, t, _ in context(chat, index, count)]
    while True:
        if form == "text":
            built = DOCUMENT + "\n".join([*lines, line(sender, text)])
        else:
            title = " / ".join(lines) if lines else "none"
            built = f"title: {title} | text: {line(sender, text)}"
        if not lines or fits(built):
            return built
        lines = lines[1:]


def read(fits):
    """Every message the app reads (at least MIN_CHARS), as it reads them: {(chat, index): text}."""
    return {(chat, index): document(fits, chat, index) for chat, index, _, text, _ in messages()
            if len(text) >= MIN_CHARS}


def threshold(positive, negative):
    """The least similarity to be found: above all but 5 % of the unrelated pairs, as long as that
    keeps most related ones (else the point between them). The model's cosines lie close: the
    order finds, this only keeps the unrelated tail out."""
    strict = float(np.percentile(negative, 95))
    return strict if (np.asarray(positive) >= strict).mean() >= 0.5 else float((np.median(positive) + strict) / 2)


def message_threshold(encode, fits, query_prompt):
    """The model's `messageSimilarity`: the rule above over the cosines (both less the messages'
    mean, as the app keeps them) of each query to the message it looks for and to the messages of
    other chats, every message read as the app reads it. `encode` takes texts, their prompts
    included, to unit embeddings; `fits` says whether a text fits the encoder whole."""
    docs = read(fits)
    keys = list(docs)
    embedded = encode([docs[key] for key in keys])
    mean = embedded.mean(0, keepdims=True)
    centred = lambda e: (e - mean) / np.linalg.norm(e - mean, axis=-1, keepdims=True)
    queries = SHORT + WHOLE
    scores = centred(encode([query_prompt + text for text, *_ in queries])) @ centred(embedded).T
    hits, others = [], []
    for row, (_, chat, index) in zip(scores, queries):
        for key, score in zip(keys, row):
            if key == (chat, index):
                hits.append(score)
            elif key[0] != chat:
                others.append(score)
    return threshold(hits, others)



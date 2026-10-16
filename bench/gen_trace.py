#!/usr/bin/env python3
"""
Synthetic long-horizon trace generator for the Chronomem evaluation.

Produces a deterministic, replayable stream of agent activity over N simulated
days. Every backend under test (Chronomem, flat recency, one-shot compaction)
receives the *same* stream and must answer the *same* probe questions, so the
only variable is the memory architecture.

Determinism matters: the generator is seeded, and `--seed` reproduces a trace
byte-for-byte. Without that, three backends cannot be compared on equal inputs.

Each simulated day emits a small number of *facts* (a decision, an edit, a
status change) plus filler activity. A probe targets a fact; the ground-truth
answer is the fact's value. Filler events exist so that a real memory system has
to discriminate — a trace where every event is a probe would let a flat store
score as well as a layered one.

Usage:
    python3 gen_trace.py --days 7 --agents 3 --seed 42 --out trace.json
"""

from __future__ import annotations

import argparse
import json
import random
from dataclasses import dataclass, field, asdict

# Domains kept small and unambiguous so that an exact-match scorer is fair.
# Topic codes are nonsense letter strings on purpose. English words get
# translated by the summarizer ("storage" -> "存储"), so a probe asking about
# "storage" cannot be located in a Chinese summary at all — the extraction step
# then fails and the level scores 0, which reads as "the summary lost
# everything". A token with no meaning survives verbatim in either language.
TOPICS = ["vun", "keb", "rix", "tas", "mox"]
CHOICES = ["A", "B", "C"]
OWNERS = ["alice", "bob", "carol"]
# Letters used to build the per-fact reference token (see `ref` in `generate`).
REF_LETTERS = ["Q", "R", "T", "U", "V", "W", "X", "Y"]


@dataclass
class Event:
    """One activity record. `fact_id` is set only on events that carry a fact."""
    day: int
    seq: int
    kind: str            # decision | edit | status | chatter | probe_anchor
    text: str            # what the agent would have seen
    fact_id: str | None = None
    answer: str | None = None   # ground truth, present only on fact-carrying events
    topic: str | None = None
    ref: str | None = None      # opaque token that survives summarization


@dataclass
class Probe:
    """A question whose answer is derivable from the trace."""
    qid: str
    question: str
    answer: str
    fact_id: str
    day_asked: int      # the probe is asked at the end of this day
    topic: str
    ref: str = ""       # reference token to locate the fact in a summary


@dataclass
class Trace:
    days: int
    agents: int
    seed: int
    events: list = field(default_factory=list)
    probes: list = field(default_factory=list)


def generate(days: int, agents: int, seed: int, facts_per_day: int = 2,
             filler_per_day: int = 6, no_ref: bool = False) -> Trace:
    """Build one trace. Facts accumulate across days; probes test recall of them.

    Answers are drawn *round-robin* over CHOICES rather than uniformly at
    random. A uniform draw over a small probe set clusters (with 9 probes, one
    choice can easily take 7), and a clustered answer key makes the majority
    class a strong baseline — always answering the most common option would
    score ~78%, leaving no headroom to detect a real difference between
    architectures. Round-robin bounds the majority-class baseline at about
    1/|CHOICES| whatever the probe count.
    """
    rng = random.Random(seed)
    tr = Trace(days=days, agents=agents, seed=seed)
    seq = 0
    fact_n = 0
    choice_n = 0

    for day in range(1, days + 1):
        # --- facts for this day -------------------------------------------------
        # Topics are drawn WITHOUT replacement within a day. Repeating a topic on
        # the same day makes a probe ambiguous: "what was chosen for storage on
        # day 6" no longer has one answer, and a reader that finds the *first*
        # mention reports a different (correct-looking) option than the fact the
        # probe was built from. Measured: 6 of 54 (day, topic) pairs were
        # ambiguous, and they accounted for every miss the layered backend
        # showed — the system had remembered the fact, the extractor picked the
        # other one. Determinism is preserved because the sample is seeded.
        day_topics = rng.sample(TOPICS, min(facts_per_day, len(TOPICS)))
        for topic in day_topics:
            fact_n += 1
            fid = f"f{fact_n:03d}"
            answer = CHOICES[choice_n % len(CHOICES)]
            choice_n += 1
            owner = rng.choice(OWNERS)
            # Opaque reference token carried inside the text.
            #
            # Why an extra token is needed at all: locating a fact in a *summary*
            # by (topic, day) is unreliable even when each day's topics are
            # distinct. The summarizer writes a prose conclusion naming several
            # topics and several options in one sentence ("keb and vun were
            # applied options A and C"), and a reader that takes the first option
            # letter there returns the wrong topic's answer. Measured: that one
            # sentence shape caused most of the summary-backed misses. A nonsense
            # token survives summarization verbatim in either language, so it
            # identifies the fact unambiguously.
            ref = f"Z{REF_LETTERS[fact_n % len(REF_LETTERS)]}{fact_n:02d}"

            # `no_ref` drops the opaque token from the text while leaving
            # everything else — topics, answers, lag structure, probe schedule —
            # identical, so a comparison isolates exactly one variable: whether a
            # fact is located by a token that survives summarisation verbatim, or
            # by natural-language (topic, day) reference. The token was introduced
            # to remove *ambiguity* in the reader; the question this variant asks
            # is whether it also removed *difficulty*, making exact recall look
            # better than it is when upstream text has no such marker.
            token = "" if no_ref else f"(ref {ref}) "
            tr.events.append(Event(
                day=day, seq=seq, kind="decision", fact_id=fid, answer=answer,
                topic=topic, ref=ref,
                text=f"[{topic}] {token}{owner} decided to go with option "
                     f"{answer} for the {topic} work on day {day}."))
            seq += 1

            tr.events.append(Event(
                day=day, seq=seq, kind="edit", fact_id=fid, answer=answer,
                topic=topic, ref=ref,
                text=f"{token}Applied option {answer} in the {topic} module "
                     f"({owner}, day {day})."))
            seq += 1

        # --- filler: activity that is not a fact --------------------------------
        for _ in range(filler_per_day):
            topic = rng.choice(TOPICS)
            tr.events.append(Event(
                day=day, seq=seq, kind="chatter", topic=topic,
                text=f"Ran a {topic} check; nothing changed. day {day}."))
            seq += 1

        # --- probes: ask about facts from *earlier* days ------------------------
        # Two things this must get right, both learned the hard way:
        #
        # 1. Never ask about a same-day fact. A recency window still holds that
        #    day, so the probe measures nothing about long-horizon memory.
        #    Measured: with same-day probes a 20-event window scored 7/9.
        # 2. The lag must GROW with the run. A fixed short lag is also answered
        #    by any bounded recency window: on a 30-day trace with a 1-day lag,
        #    a 20-event window (≈2 days) still scored 90.6%. The lag therefore
        #    grows with the day, which is exactly the axis a time-layered store
        #    is supposed to win on — and the reason a flat store degrades as the
        #    horizon extends.
        all_facts = [e for e in tr.events if e.kind == "decision" and e.day < day]
        if all_facts:
            target_day = max(1, day - max(1, day // 2))
            candidates = [e for e in all_facts if e.day == target_day] or all_facts
            target = candidates[0]
            # Without a reference token the probe must name the fact the way the
            # text does: by topic and day. That is exactly the reader's fallback
            # path, and it is the harder problem the variant is meant to pose.
            q = (f"What option was chosen for {target.topic} on day {target.day}?"
                 if no_ref else
                 f"What option was chosen for ref {target.ref} on day {target.day}?")
            tr.probes.append(Probe(
                qid=f"q{day:02d}", topic=target.topic, question=q,
                answer=target.answer, fact_id=target.fact_id, day_asked=day,
                ref=target.ref))

    # Long-range probes: the earliest and a mid-run fact, asked at the very end.
    decisions = [e for e in tr.events if e.kind == "decision"]
    for i, idx in enumerate([0, 1, len(decisions) // 2]):
        if idx >= len(decisions):
            continue
        ev = decisions[idx]
        q = (f"(recap) What option was chosen for {ev.topic} on day {ev.day}?"
             if no_ref else
             f"(recap) What option was chosen for ref {ev.ref} on day {ev.day}?")
        tr.probes.append(Probe(
            qid=f"q_long{i + 1}", topic=ev.topic, question=q,
            answer=ev.answer, fact_id=ev.fact_id, day_asked=days, ref=ev.ref))

    return tr


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--agents", type=int, default=3)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", required=True)
    ap.add_argument("--facts-per-day", type=int, default=2)
    ap.add_argument("--filler-per-day", type=int, default=6)
    ap.add_argument("--no-ref", action="store_true",
                    help="omit the opaque reference token from fact text and ask "
                         "probes by (topic, day) instead; isolates whether exact "
                         "recall depends on a token that survives summarisation "
                         "verbatim")
    args = ap.parse_args()

    tr = generate(args.days, args.agents, args.seed,
                  facts_per_day=args.facts_per_day,
                  filler_per_day=args.filler_per_day,
                  no_ref=args.no_ref)
    payload = {
        "meta": {"days": tr.days, "agents": tr.agents, "seed": tr.seed,
                 "events": len(tr.events), "probes": len(tr.probes)},
        "events": [asdict(e) for e in tr.events],
        "probes": [asdict(p) for p in tr.probes],
    }
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)
    print(f"wrote {args.out}: {len(tr.events)} events, {len(tr.probes)} probes, "
          f"{tr.days} days, seed {tr.seed}")


if __name__ == "__main__":
    main()

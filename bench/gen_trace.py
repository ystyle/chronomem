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
TOPICS = ["storage", "protocol", "retry", "schema", "scheduler"]
CHOICES = ["A", "B", "C"]
OWNERS = ["alice", "bob", "carol"]


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


@dataclass
class Probe:
    """A question whose answer is derivable from the trace."""
    qid: str
    question: str
    answer: str
    fact_id: str
    day_asked: int      # the probe is asked at the end of this day
    topic: str


@dataclass
class Trace:
    days: int
    agents: int
    seed: int
    events: list = field(default_factory=list)
    probes: list = field(default_factory=list)


def generate(days: int, agents: int, seed: int, facts_per_day: int = 2,
             filler_per_day: int = 6) -> Trace:
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
        for _ in range(facts_per_day):
            fact_n += 1
            fid = f"f{fact_n:03d}"
            topic = rng.choice(TOPICS)
            answer = CHOICES[choice_n % len(CHOICES)]
            choice_n += 1
            owner = rng.choice(OWNERS)

            # A decision names the choice; the edit/status events restate it in
            # different words so a summary can be built from several entries.
            tr.events.append(Event(
                day=day, seq=seq, kind="decision", fact_id=fid, answer=answer,
                topic=topic,
                text=f"[{topic}] {owner} decided to go with option {answer} "
                     f"for the {topic} work on day {day}."))
            seq += 1

            tr.events.append(Event(
                day=day, seq=seq, kind="edit", fact_id=fid, answer=answer,
                topic=topic,
                text=f"Applied option {answer} in the {topic} module "
                     f"({owner}, day {day})."))
            seq += 1

        # --- filler: activity that is not a fact --------------------------------
        for _ in range(filler_per_day):
            topic = rng.choice(TOPICS)
            tr.events.append(Event(
                day=day, seq=seq, kind="chatter", topic=topic,
                text=f"Ran a {topic} check; nothing changed. day {day}."))
            seq += 1

        # --- probe for the fact created *earliest* this day ---------------------
        # Asking about the oldest fact on the day it was created, and re-asking
        # older facts, is what separates architectures: a system that only keeps
        # recent context fails the older probes.
        day_facts = [e for e in tr.events if e.day == day and e.kind == "decision"]
        if day_facts:
            target = day_facts[0]
            tr.probes.append(Probe(
                qid=f"q{day:02d}", topic=target.topic,
                question=f"What option was chosen for {target.topic} on day {day}?",
                answer=target.answer, fact_id=target.fact_id, day_asked=day))

    # A few long-range probes: ask about the very first facts at the very end.
    # These are the ones a recency-only store cannot answer.
    first_decisions = [e for e in tr.events if e.kind == "decision"][:2]
    for i, ev in enumerate(first_decisions):
        tr.probes.append(Probe(
            qid=f"q_long{i + 1}", topic=ev.topic,
            question=f"(recap) What option was chosen for {ev.topic} on day {ev.day}?",
            answer=ev.answer, fact_id=ev.fact_id, day_asked=days))

    return tr


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--agents", type=int, default=3)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    tr = generate(args.days, args.agents, args.seed)
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

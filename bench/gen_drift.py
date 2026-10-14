#!/usr/bin/env python3
"""
Drift trace generator: events laid out on an HOUR grid so a summary tower with
an `1h` level can actually be built.

Why a separate generator from `gen_trace.py`: the comparison harness asks "does
architecture A answer better than B"; this one asks "how much does a *chained
summary* lose as it is re-summarized up the tower". Different question, different
input shape:

- events carry an explicit `hour`, so a 1h window is non-empty;
- every fact has a **verifiable answer**, and each fact is tagged with the level
  at which it was introduced, so we can ask "can the day summary still answer a
  question whose answer was only in the 1h detail?";
- some facts are deliberately **minor** (a passing remark): a chain is expected
  to drop these first, and the drift study needs to see that.

The trace is deterministic (`--seed`).

Usage:
    python3 gen_drift.py --hours 72 --seed 11 --out .work/drift.json
"""

from __future__ import annotations

import argparse
import json
import random
from dataclasses import dataclass, field, asdict

# Topic codes are deliberately opaque tokens, not English words. An earlier
# version used words like "scheduler"/"cache", and the summarizer translated them
# ("调度器"/"缓存") and varied the phrasing ("小时 1" vs "第三小时") — which makes
# locating a fact in the summary unreliable and would corrupt the drift score.
# A code such as K42 survives translation.
TOPICS = ["K11", "K22", "K33", "K44", "K55", "K66"]
CHOICES = ["A", "B", "C", "D"]


@dataclass
class Event:
    hour: int            # absolute hour index from the start of the trace
    seq: int
    kind: str            # decision | note | chatter
    text: str
    fact_id: str | None = None
    answer: str | None = None
    topic: str | None = None
    # `major` facts are restated in several events (a summary should keep them);
    # `minor` facts appear exactly once (a chained summary is expected to drop
    # them — that is the drift we want to measure).
    salience: str = "major"


@dataclass
class Probe:
    qid: str
    question: str
    answer: str
    fact_id: str
    ask_at_hour: int     # the summary being tested covers up to this hour
    topic: str
    salience: str
    introduced_hour: int


@dataclass
class Trace:
    hours: int
    seed: int
    events: list = field(default_factory=list)
    probes: list = field(default_factory=list)


def generate(hours: int, seed: int, facts_per_hour: int = 1,
             chatter_per_hour: int = 3, minor_ratio: float = 0.4) -> Trace:
    rng = random.Random(seed)
    tr = Trace(hours=hours, seed=seed)
    seq = 0
    fact_n = 0
    choice_n = 0

    for hour in range(1, hours + 1):
        for _ in range(facts_per_hour):
            fact_n += 1
            fid = f"f{fact_n:04d}"
            topic = rng.choice(TOPICS)
            answer = CHOICES[choice_n % len(CHOICES)]
            choice_n += 1
            minor = rng.random() < minor_ratio
            salience = "minor" if minor else "major"

            # The decision event always carries the fact.
            tr.events.append(Event(
                hour=hour, seq=seq, kind="decision", fact_id=fid, answer=answer,
                topic=topic, salience=salience,
                text=f"Decision: for {topic} we chose option {answer} "
                     f"(hour {hour})."))
            seq += 1

            # Major facts get restated — a summary built from several mentions
            # should survive chaining. Minor facts appear once and are the ones
            # a chain is expected to lose.
            if not minor:
                tr.events.append(Event(
                    hour=hour, seq=seq, kind="note", fact_id=fid, answer=answer,
                    topic=topic, salience=salience,
                    text=f"Confirmed the {topic} decision: option {answer} "
                         f"is what we are going with (hour {hour})."))
                seq += 1

        for _ in range(chatter_per_hour):
            topic = rng.choice(TOPICS)
            tr.events.append(Event(
                hour=hour, seq=seq, kind="chatter", topic=topic,
                text=f"Routine {topic} check; no change (hour {hour})."))
            seq += 1

    # --- probes --------------------------------------------------------------
    # Each fact gets probes at three horizons, so drift can be read as a curve
    # rather than a single number:
    #   near  — the hour it was created (tests the finest layer)
    #   mid   — about a day later (tests the day layer)
    #   far   — at the end of the run (tests the week layer, i.e. the longest
    #           chain)
    facts = [e for e in tr.events if e.kind == "decision"]
    for ev in facts:
        for tag, ask in (("near", ev.hour),
                         ("mid", min(hours, ev.hour + 24)),
                         ("far", hours)):
            if ask < ev.hour:
                continue
            tr.probes.append(Probe(
                qid=f"{ev.fact_id}-{tag}", topic=ev.topic,
                question=f"What option was chosen for {ev.topic} at hour {ev.hour}?",
                answer=ev.answer, fact_id=ev.fact_id, ask_at_hour=ask,
                salience=ev.salience, introduced_hour=ev.hour))

    # Deduplicate: near/mid/far collapse onto the same hour when the trace is
    # short, and identical (fact, hour) probes would double-count.
    seen = set()
    uniq = []
    for p in tr.probes:
        k = (p.fact_id, p.ask_at_hour)
        if k in seen:
            continue
        seen.add(k)
        uniq.append(p)
    tr.probes = uniq

    return tr


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--hours", type=int, default=72, help="length in hours")
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    tr = generate(args.hours, args.seed)
    maj = sum(1 for p in tr.probes if p.salience == "major")
    payload = {
        "meta": {"hours": tr.hours, "seed": tr.seed,
                 "events": len(tr.events), "probes": len(tr.probes),
                 "major_probes": maj,
                 "minor_probes": len(tr.probes) - maj},
        "events": [asdict(e) for e in tr.events],
        "probes": [asdict(p) for p in tr.probes],
    }
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)
    print(f"wrote {args.out}: {len(tr.events)} events, {len(tr.probes)} probes "
          f"({maj} major / {len(tr.probes) - maj} minor), {tr.hours}h, seed {tr.seed}")


if __name__ == "__main__":
    main()

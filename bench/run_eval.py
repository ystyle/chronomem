#!/usr/bin/env python3
"""
Runner and scorer: drive one trace through every backend and report
accuracy vs. token cost.

Why a separate scorer rather than inlining: the score must be computed the same
way for every backend, and the *baselines* must be reported alongside it. A
majority-class baseline and a "return everything" baseline are cheap to compute
and immediately show whether a difference is real — without them, "Chronomem
scores 0.7" says nothing.

Scoring is exact-match on a single-token answer (CHOICES are A/B/C). The reader
is a deterministic extractor: given the text a backend returns, it must name the
option for the asked-about topic+day. This deliberately models a *bounded*
reader — one that cannot re-read an unbounded history — which is the regime the
paper is about.

Usage:
    python3 run_eval.py --trace .work/trace.json --backend flat
    python3 run_eval.py --trace .work/trace.json --backend all
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field

from backends import (Backend, ChronomemBackend, FlatBackend,
                      CompactionBackend, DAY_MS, est_tokens)

# Which option did the backend leave visible for (topic, day)?
DECISION_RE = re.compile(
    r"\[(?P<topic>[a-z]+)\].*?decided to go with option (?P<choice>[ABC]).*?day (?P<day>\d+)",
    re.IGNORECASE)
EDIT_RE = re.compile(
    r"Applied option (?P<choice>[ABC]) in the (?P<topic>[a-z]+) module .*?day (?P<day>\d+)",
    re.IGNORECASE)


@dataclass
class ProbeResult:
    qid: str
    expected: str
    got: str | None
    correct: bool
    client_tokens: int


@dataclass
class BackendResult:
    name: str
    correct: int = 0
    total: int = 0
    client_tokens: int = 0
    server_tokens: int = 0
    stored_chars: int = 0
    events_seen: int = 0
    per_probe: list = field(default_factory=list)

    @property
    def accuracy(self) -> float:
        return self.correct / self.total if self.total else 0.0

    # Cumulative tokens grow with the number of probes, so a single "cost"
    # number is ambiguous: a backend asked 50 questions looks 5x more expensive
    # than the same backend asked 10. Both views are reported — per-question is
    # the architecture-comparable figure, cumulative is the deployment figure.
    @property
    def client_tokens_per_probe(self) -> float:
        return self.client_tokens / self.total if self.total else 0.0

    @property
    def server_tokens_per_probe(self) -> float:
        return self.server_tokens / self.total if self.total else 0.0

    @property
    def total_tokens(self) -> int:
        return self.client_tokens + self.server_tokens


def extract_answer(text: str, question: str) -> str | None:
    """Deterministic reader: pull the option for the topic+day the question asks about.

    The reader sees only `text`. If the answer is not present verbatim it must
    fail — that is the point: a compressed store that dropped the detail cannot
    be rescued by a clever reader.
    """
    m = re.search(r"for ([a-z]+) on day (\d+)", question, re.IGNORECASE)
    if not m:
        m = re.search(r"for ([a-z]+) on day (\d+)", question, re.IGNORECASE)
    if not m:
        return None
    want_topic, want_day = m.group(1).lower(), int(m.group(2))

    found: str | None = None
    for rx in (DECISION_RE, EDIT_RE):
        for mm in rx.finditer(text):
            if mm.group("topic").lower() == want_topic and int(mm.group("day")) == want_day:
                found = mm.group("choice").upper()   # first match wins
                break
        if found:
            break
    return found


def run_backend(backend: Backend, trace: dict, purge_first: bool = False) -> BackendResult:
    if purge_first and isinstance(backend, ChronomemBackend):
        backend.purge()
        backend.setup()

    res = BackendResult(name=backend.name)

    # Replay day by day: events first, then that day's probes. Probes asked on
    # day N must not see day N+1 events, or a recency baseline would be judged
    # on information it could not have had.
    events_by_day: dict[int, list] = {}
    for e in trace["events"]:
        events_by_day.setdefault(e["day"], []).append(e)
    probes_by_day: dict[int, list] = {}
    for p in trace["probes"]:
        probes_by_day.setdefault(p["day_asked"], []).append(p)

    days = sorted(set(events_by_day) | set(probes_by_day))
    for day in days:
        for e in sorted(events_by_day.get(day, []), key=lambda x: x["seq"]):
            backend.write(day, e["seq"], e["text"],
                          {"topic": e["topic"]} if e.get("topic") else None)
        for p in probes_by_day.get(day, []):
            ans = backend.answer(p["question"], day)
            got = extract_answer(ans.text, p["question"])
            ok = got == p["answer"]
            res.total += 1
            res.correct += int(ok)
            res.client_tokens += ans.client_tokens
            res.server_tokens += ans.server_tokens
            res.per_probe.append(ProbeResult(p["qid"], p["answer"], got, ok,
                                             ans.client_tokens))

    res.stored_chars = backend.stored_chars
    res.events_seen = backend.events_seen
    # Server-side spend accumulated on the backend itself (e.g. compaction
    # passes) must be added: it happens during `write`, not while answering, so
    # summing only the per-answer counts would report a compactor as free — the
    # exact mistake the two-sided accounting exists to prevent.
    res.server_tokens += backend.server_tokens
    backend.close()
    return res


# --- baselines --------------------------------------------------------------

def majority_baseline(trace: dict) -> tuple[str, float]:
    """Always answer the most common option. If a real backend cannot beat this
    by a clear margin, the trace does not discriminate."""
    counts: dict[str, int] = {}
    for p in trace["probes"]:
        counts[p["answer"]] = counts.get(p["answer"], 0) + 1
    top = max(counts, key=counts.get)
    return top, counts[top] / len(trace["probes"])


def oracle_baseline(trace: dict) -> float:
    return 1.0


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--trace", required=True)
    ap.add_argument("--backend", default="all",
                    choices=["all", "flat", "compaction", "chronomem-exact",
                             "chronomem-summary"])
    ap.add_argument("--purge", action="store_true",
                    help="truncate the Chronomem eval type before the run")
    ap.add_argument("--json-out")
    args = ap.parse_args()

    with open(args.trace, encoding="utf-8") as fh:
        trace = json.load(fh)

    todo: list[Backend] = []
    if args.backend in ("all", "flat"):
        todo.append(FlatBackend())
    if args.backend in ("all", "compaction"):
        todo.append(CompactionBackend())
    if args.backend in ("all", "chronomem-exact"):
        todo.append(ChronomemBackend(mode="exact"))
    if args.backend in ("all", "chronomem-summary"):
        todo.append(ChronomemBackend(mode="summary"))

    top, base = majority_baseline(trace)
    print(f"trace: {trace['meta']}")
    print(f"majority-class baseline: always '{top}' → {base:.0%}")
    print()

    results = []
    for b in todo:
        try:
            if isinstance(b, ChronomemBackend):
                if args.purge:
                    b.purge()
                b.setup()
            r = run_backend(b, trace)
        except Exception as exc:                      # noqa: BLE001
            print(f"[{b.name}] FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
            continue
        results.append(r)
        print(f"[{r.name}]")
        print(f"  accuracy              {r.correct}/{r.total} = {r.accuracy:.1%}")
        print(f"  client tokens/question {r.client_tokens_per_probe:8.0f}")
        print(f"  server tokens/question {r.server_tokens_per_probe:8.0f}")
        print(f"  total  tokens/question {r.client_tokens_per_probe + r.server_tokens_per_probe:8.0f}")
        print(f"  cumulative client      {r.client_tokens:8d}  ({r.total} probes)")
        print(f"  cumulative server      {r.server_tokens:8d}")
        print(f"  stored chars           {r.stored_chars:8d}")
        print()

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            json.dump({
                "meta": trace["meta"],
                "majority_baseline": {"choice": top, "accuracy": base},
                "results": [{
                    "name": r.name, "accuracy": r.accuracy,
                    "correct": r.correct, "total": r.total,
                    "client_tokens_per_probe": r.client_tokens_per_probe,
                    "server_tokens_per_probe": r.server_tokens_per_probe,
                    "client_tokens_total": r.client_tokens,
                    "server_tokens_total": r.server_tokens,
                    "stored_chars": r.stored_chars,
                    "per_probe": [vars(p) for p in r.per_probe],
                } for r in results],
            }, fh, ensure_ascii=False, indent=1)
        print(f"wrote {args.json_out}")


if __name__ == "__main__":
    main()

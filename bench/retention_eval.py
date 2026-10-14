#!/usr/bin/env python3
"""
Retention-decay study: how long can each architecture still answer?

The question the paper actually needs answered is not "does a day summary keep
detail X" but **"how far back can the system still recall at all"**. That is the
axis on which a layered store should beat a bounded recency window, and it is
measurable without adjudicating the quality of any single summary.

Design:

* One trace, one probe set, three backends — the same comparison discipline as
  `run_eval.py`, so a difference cannot come from differing inputs.
* Probes are grouped by **lag** (how many days between the fact and the moment
  it is asked about). Accuracy is reported *per lag bucket*, so what comes out
  is a curve rather than a single number: the expected shape is a flat line for
  the layered store and a cliff for the recency window once the probe falls out
  of its window.
* Every backend is read by the **same extractor** (`run_eval.extract_answer`,
  which locates the option by topic+day). A weaker extractor would depress all
  three equally and leave the comparison intact.

This deliberately does not score summary *quality* per level — that requires
adjudicating prose, and a regex over prose measures the regex. Recall-at-lag is
the claim under test.

Usage:
    python3 retention_eval.py --trace .work/t30.json --json-out .work/ret30.json
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict

from backends import ChronomemBackend, CompactionBackend, FlatBackend
from run_eval import extract_answer, run_backend

# Lag buckets in days. Chosen to straddle the recency window: with top_k=20 and
# ~10 events/day, a flat store holds about two days, so the cliff should appear
# between the 2d and 3d buckets.
LAG_BUCKETS = [0, 1, 2, 3, 5, 7, 14, 30, 60]


def bucket_of(lag: int) -> int:
    """Largest bucket boundary <= lag (so lag 0-1 -> 1, 4 -> 3, 10 -> 7...)."""
    b = 0
    for edge in LAG_BUCKETS:
        if lag >= edge:
            b = edge
    return b


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--trace", required=True)
    ap.add_argument("--json-out")
    ap.add_argument("--purge", action="store_true")
    ap.add_argument("--backends", default="flat,compaction,chronomem-exact",
                    help="comma-separated subset")
    args = ap.parse_args()

    with open(args.trace, encoding="utf-8") as fh:
        trace = json.load(fh)

    picked = set(args.backends.split(","))
    todo = []
    if "flat" in picked:
        todo.append(FlatBackend())
    if "compaction" in picked:
        todo.append(CompactionBackend())
    if "chronomem-exact" in picked:
        todo.append(ChronomemBackend(mode="exact"))
    if "chronomem-summary" in picked:
        todo.append(ChronomemBackend(mode="summary"))

    # Attach the lag to each probe before running, so the runner can report it.
    for p in trace["probes"]:
        p["lag_days"] = p["day_asked"] - int(
            __import__("re").search(r"on day (\d+)", p["question"]).group(1))

    print(f"trace: {trace['meta']}")
    lags = [p["lag_days"] for p in trace["probes"]]
    print(f"lag range: {min(lags)}–{max(lags)} days")
    print()

    out = {"meta": trace["meta"], "by_backend": {}}
    for backend in todo:
        name = backend.name
        try:
            if isinstance(backend, ChronomemBackend):
                # Always start from an empty series. Materialization/write is
                # append-only and rejects out-of-order timestamps, so a re-run
                # over a trace that starts earlier than the previous run's data
                # fails with `out-of-order append` — the second run then reports
                # nothing while looking like a legitimate zero.
                backend.purge()
                backend.setup()
            res = run_backend(backend, trace)
        except Exception as exc:                       # noqa: BLE001
            print(f"[{name}] FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
            continue

        # --- bucket the same per-probe results by lag -------------------------
        # Match on `qid`, not position: `run_backend` emits results in
        # day-then-probe order, which is NOT trace order. Zipping by index would
        # silently pair each result with the wrong lag.
        lag_of = {p["qid"]: p["lag_days"] for p in trace["probes"]}
        buckets = defaultdict(lambda: {"n": 0, "correct": 0})
        for pr in res.per_probe:
            b = bucket_of(lag_of[pr.qid])
            buckets[b]["n"] += 1
            buckets[b]["correct"] += int(pr.correct)

        print(f"[{name}]  overall {res.correct}/{res.total} = {res.accuracy:.1%}")
        print(f"  {'lag(d)':>7} {'n':>4} {'accuracy':>9}")
        curve = {}
        for b in sorted(buckets):
            d = buckets[b]
            acc = d["correct"] / d["n"] if d["n"] else 0.0
            curve[b] = {"n": d["n"], "accuracy": acc}
            bar = "#" * int(acc * 30)
            print(f"  {b:>7} {d['n']:>4} {acc:>8.1%}  {bar}")
        print()

        out["by_backend"][name] = {
            "overall_accuracy": res.accuracy,
            "client_tokens_per_probe": res.client_tokens_per_probe,
            "server_tokens_per_probe": res.server_tokens_per_probe,
            "curve": curve,
            # Kept so a surprising bucket can be traced to specific probes
            # instead of being argued about at the aggregate level.
            "per_probe": [
                {**vars(pr), "lag_days": lag_of[pr.qid]}
                for pr in res.per_probe
            ],
        }

    # --- the comparison ------------------------------------------------------
    print("=== accuracy vs how long ago the fact was (lag buckets) ===")
    names = list(out["by_backend"].keys())
    print(f"{'lag(d)':>7} " + " ".join(f"{n[:18]:>19}" for n in names))
    all_b = sorted({b for v in out["by_backend"].values() for b in v["curve"]})
    for b in all_b:
        row = []
        for n in names:
            c = out["by_backend"][n]["curve"].get(b)
            row.append(f"{c['accuracy']:>18.1%}" if c else f"{'-':>19}")
        print(f"{b:>7} " + " ".join(row))

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            json.dump(out, fh, ensure_ascii=False, indent=1)
        print(f"\nwrote {args.json_out}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)

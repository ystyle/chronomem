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
import os
import sys
from collections import defaultdict

from backends import (ChronomemBackend, CompactionBackend,
                      ConservativeCompactionBackend, FlatBackend)
from run_eval import extract_answer, run_backend

# Lag buckets, as *lower* edges. A probe falls in the largest edge <= its lag,
# so the bucket labelled 7 holds lags 7–13 and the one labelled 14 holds 14–29.
#
# The label is therefore a lower bound, not the lag itself. Reporting it as
# "lag 14" misreads the data: on a 30-day trace the top bucket actually contains
# 29-day probes, and a capacity argument about a 20-day window then looks
# violated when it is not. `bucket_range()` gives the true span so tables can say
# `14–29` instead of `14`.
LAG_BUCKETS = [0, 1, 2, 3, 5, 7, 14, 30, 60]


def bucket_of(lag: int) -> int:
    """Lower edge of the bucket containing `lag` (0–1 -> 1, 4 -> 3, 10 -> 7...)."""
    b = 0
    for edge in LAG_BUCKETS:
        if lag >= edge:
            b = edge
    return b


def bucket_upper(bucket: int) -> int | None:
    """Upper edge (exclusive) of a bucket; None for the last bucket."""
    for i, edge in enumerate(LAG_BUCKETS):
        if edge == bucket:
            return LAG_BUCKETS[i + 1] if i + 1 < len(LAG_BUCKETS) else None
    return None


def bucket_label(bucket: int, lags: list[int] | None = None) -> str:
    """Human label for a bucket, never pretending it is a single day.

    Prefers the observed span when the lags are known (`14-29`), else the nominal
    edges from the table.
    """
    if lags:
        lo, hi = min(lags), max(lags)
        return f"{lo}" if lo == hi else f"{lo}-{hi}"
    up = bucket_upper(bucket)
    if up is None:
        return f"{bucket}+"
    return f"{bucket}" if up - bucket == 1 else f"{bucket}-{up - 1}"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--trace", required=True)
    ap.add_argument("--json-out")
    ap.add_argument("--purge", action="store_true")
    ap.add_argument("--backends", default="flat,compaction,chronomem-exact",
                    help="comma-separated subset")
    ap.add_argument("--url", default="http://127.0.0.1:18900/mcp",
                    help="Chronomem endpoint; must be the isolated bench instance")
    args = ap.parse_args()

    # Single-writer guard. Two runs sharing a type destroy each other: each
    # `purge()` empties the series the other is filling, so both report whatever
    # survived the race. Observed once — a second run was started while the first
    # was still finishing, and the arms came back with summaries missing that had
    # demonstrably been generated.
    lock = os.path.join(os.path.dirname(os.path.abspath(args.trace)),
                        ".retention_eval.lock")
    if os.path.exists(lock):
        try:
            with open(lock, encoding="utf-8") as fh:
                other = int(fh.read().strip() or 0)
            os.kill(other, 0)                     # signal 0 = existence probe
            print(f"another retention_eval is running (pid {other}); refusing to "
                  f"start a second writer against the same instance.\n"
                  f"Remove {lock} if that process is gone.", file=sys.stderr)
            return 2
        except (ValueError, ProcessLookupError, PermissionError):
            pass                                   # stale lock, take it over
    with open(lock, "w", encoding="utf-8") as fh:
        fh.write(str(os.getpid()))

    try:
        return _run(args)
    finally:
        try:
            os.unlink(lock)
        except OSError:
            pass


def _run(args) -> int:
    with open(args.trace, encoding="utf-8") as fh:
        trace = json.load(fh)

    picked = set(args.backends.split(","))
    todo = []
    if "flat" in picked:
        todo.append(FlatBackend())
    if "compaction" in picked:
        todo.append(CompactionBackend())
    # The reviewer's strongest objection: the destructive baseline's zero scores
    # could come from how we wrote it. This arm compacts on the same schedule but
    # keeps every token-to-value pair, so the two together separate "compaction is
    # destructive" from "our compactor was".
    if "conservative" in picked:
        todo.append(ConservativeCompactionBackend())
    if "chronomem-exact" in picked:
        todo.append(ChronomemBackend(url=args.url, mode="exact"))
    if "chronomem-summary" in picked:
        todo.append(ChronomemBackend(url=args.url, mode="summary"))
    # The coarse arm. Without it the "layered" comparison only ever exercises the
    # day level, so the layering claim is never actually tested.
    if "chronomem-week" in picked:
        todo.append(ChronomemBackend(url=args.url, mode="summary-week"))

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
            res = run_backend(backend, trace, prepare=backend.prepare)
        except Exception as exc:                       # noqa: BLE001
            print(f"[{name}] FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
            continue

        # --- bucket the same per-probe results by lag -------------------------
        # Match on `qid`, not position: `run_backend` emits results in
        # day-then-probe order, which is NOT trace order. Zipping by index would
        # silently pair each result with the wrong lag.
        lag_of = {p["qid"]: p["lag_days"] for p in trace["probes"]}
        buckets = defaultdict(lambda: {"n": 0, "correct": 0, "lags": []})
        for pr in res.per_probe:
            b = bucket_of(lag_of[pr.qid])
            buckets[b]["n"] += 1
            buckets[b]["correct"] += int(pr.correct)
            buckets[b]["lags"].append(lag_of[pr.qid])

        print(f"[{name}]  overall {res.correct}/{res.total} = {res.accuracy:.1%}")
        # The bucket column shows the true lag span (e.g. 14-29), not the lower
        # edge: calling a 14–29 bucket "14" invites conclusions about "14 days"
        # that the data does not support.
        print(f"  {'lag(d)':>8} {'n':>4} {'accuracy':>9}")
        curve = {}
        for b in sorted(buckets):
            d = buckets[b]
            acc = d["correct"] / d["n"] if d["n"] else 0.0
            label = bucket_label(b, d["lags"])
            curve[b] = {"n": d["n"], "accuracy": acc,
                        "lag_min": min(d["lags"]), "lag_max": max(d["lags"]),
                        "label": label}
            bar = "#" * int(acc * 30)
            print(f"  {label:>8} {d['n']:>4} {acc:>8.1%}  {bar}")
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
    print("=== accuracy vs how long ago the fact was ===")
    names = list(out["by_backend"].keys())
    print(f"{'lag(d)':>8} " + " ".join(f"{n[:18]:>19}" for n in names))
    all_b = sorted({b for v in out["by_backend"].values() for b in v["curve"]})
    for b in all_b:
        row = []
        label = str(b)
        for n in names:
            c = out["by_backend"][n]["curve"].get(b)
            if c:
                label = c.get("label", str(b))
                row.append(f"{c['accuracy']:>18.1%}")
            else:
                row.append(f"{'-':>19}")
        print(f"{label:>8} " + " ".join(row))

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            json.dump(out, fh, ensure_ascii=False, indent=1)
        print(f"\nwrote {args.json_out}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)

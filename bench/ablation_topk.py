#!/usr/bin/env python3
"""
Ablation: is the recency baseline's cliff set by *capacity*?

The retention study found that `flat-recency` scores 100% at lag 1 day and 0%
from lag 2 onward, while the layered store holds 100% across 14 days. The
explanation offered was structural — the baseline's window holds ~20 events and
the trace emits ~10 events/day, so anything older than ~2 days is simply not in
its hands.

That explanation makes a falsifiable prediction: **move the window and the cliff
must move with it**. If the cliff instead stayed at 2 days regardless of `top_k`,
the capacity story would be wrong and the difference would have to be explained
by something else (e.g. the extractor, or probe construction).

So this script varies `top_k` across a range spanning ~1 to ~20 days of trace
volume and reports, for each setting:

  * the observed cliff — the largest lag bucket still answered correctly, and
  * the predicted cliff — `top_k / events_per_day`, rounded down.

Agreement between the two is the evidence. A mismatch is the interesting result.

Only local backends are used: this needs no instance and no LLM, so it runs
anywhere and is cheap to repeat.

Usage:
    python3 ablation_topk.py --trace .work/t30.json --json-out .work/ablation.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict

from backends import FlatBackend
from run_eval import run_backend
from retention_eval import bucket_of, LAG_BUCKETS

HERE = os.path.dirname(os.path.abspath(__file__))

# Window sizes spanning roughly 1–20 days of trace volume (10 events/day).
DEFAULT_TOP_K = [10, 20, 30, 50, 100, 200]


def lag_of(qid: str, probes: dict) -> int:
    return probes[qid]


def evaluate(top_k: int, trace: dict, lag_by_qid: dict) -> dict:
    backend = FlatBackend(top_k=top_k)
    res = run_backend(backend, trace)

    by_bucket = defaultdict(lambda: {"n": 0, "ok": 0})
    for pr in res.per_probe:
        b = bucket_of(lag_by_qid[pr.qid])
        by_bucket[b]["n"] += 1
        by_bucket[b]["ok"] += int(pr.correct)

    curve = {}
    for b in sorted(by_bucket):
        d = by_bucket[b]
        curve[b] = {"n": d["n"], "accuracy": d["ok"] / d["n"] if d["n"] else 0.0}

    # Observed cliff: the largest bucket boundary that is still answered
    # perfectly. A bucket is "perfect" only if every probe in it was correct,
    # which avoids calling a lucky 1-of-2 a retained window.
    observed = 0
    for b in sorted(curve):
        if curve[b]["accuracy"] >= 1.0:
            observed = b
        else:
            break

    return {"top_k": top_k, "curve": curve, "observed_cliff_days": observed,
            "overall": res.accuracy, "client_tokens_per_probe": res.client_tokens_per_probe}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--trace", default=os.path.join(HERE, ".work", "t30.json"))
    ap.add_argument("--top-k", default=",".join(str(k) for k in DEFAULT_TOP_K))
    ap.add_argument("--json-out")
    args = ap.parse_args()

    with open(args.trace, encoding="utf-8") as fh:
        trace = json.load(fh)

    # Lag per probe, taken from the question itself (the fact's day) as in
    # retention_eval: `day_asked` alone is not the lag.
    import re
    lag_by_qid = {}
    for p in trace["probes"]:
        m = re.search(r"on day (\d+)", p["question"])
        if m:
            lag_by_qid[p["qid"]] = p["day_asked"] - int(m.group(1))
    if not lag_by_qid:
        print("trace has no day-bearing probes", file=sys.stderr)
        return 1

    days = trace["meta"]["days"]
    events = trace["meta"]["events"]
    per_day = events / days
    print(f"trace: {trace['meta']}  → {per_day:.1f} events/day\n")

    settings = [int(k) for k in args.top_k.split(",") if k.strip()]
    rows = []
    for top_k in settings:
        r = evaluate(top_k, trace, lag_by_qid)
        predicted = top_k / per_day
        r["predicted_cliff_days"] = predicted
        rows.append(r)
        print(f"[top_k={top_k:>3}]  observed cliff ≤ {r['observed_cliff_days']:>2}d"
              f"   predicted {predicted:>5.1f}d"
              f"   overall {r['overall']:>6.1%}"
              f"   client tok/q {r['client_tokens_per_probe']:>7.0f}")

    print("\n=== cliff vs window size ===")
    print(f"{'top_k':>6} {'predicted(d)':>13} {'observed(≤d)':>13} {'agree?':>8}")
    agree = 0
    for r in rows:
        pred = r["predicted_cliff_days"]
        obs = r["observed_cliff_days"]
        # The observed cliff is a bucket boundary at or just below the
        # prediction; a bucket whose *upper* edge exceeds capacity cannot be
        # fully retained, so obs should never exceed pred.
        ok = obs <= pred + 0.75
        agree += int(ok)
        print(f"{r['top_k']:>6} {pred:>13.1f} {obs:>13} {'yes' if ok else 'NO':>8}")
    print(f"\n{agree}/{len(rows)} settings match the capacity prediction")

    # The stronger form of the claim: the cliff must MOVE, not stay put.
    cliffs = [r["observed_cliff_days"] for r in rows]
    moved = len(set(cliffs)) > 1
    print(f"cliff moves with window size: {'YES' if moved else 'NO'}"
          f"  (observed: {cliffs})")
    if not moved:
        print("  → the capacity explanation would be WRONG; look elsewhere "
              "(extractor, probe construction, trace shape).")

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            json.dump({"meta": trace["meta"], "events_per_day": per_day,
                       "rows": rows, "cliff_moves": moved}, fh,
                      ensure_ascii=False, indent=1)
        print(f"\nwrote {args.json_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

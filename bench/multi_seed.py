#!/usr/bin/env python3
"""
Multi-seed runner for the retention-decay study.

A single seed cannot support a claim. The summary buckets hold only a handful of
probes each (2–14 at 30 days), so one run's bucket accuracy is dominated by
sampling noise; without repeats there is no way to tell a real effect from a
lucky draw. This script runs the same experiment across several seeds and
reports mean ± std per (backend, lag bucket).

Seeds are fixed in `DEFAULT_SEEDS` so a reported table can be reproduced exactly.

Usage:
    python3 multi_seed.py --days 30 --seeds 7,11,23 --json-out .work/multi.json
    python3 multi_seed.py --summarize-only .work/multi.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SEEDS = [7, 11, 23, 31, 43]


def run_one(seed: int, days: int, agents: int, workdir: str,
            backends: str, url: str) -> dict | None:
    """Generate a trace for `seed` and run the full comparison on it."""
    trace = os.path.join(workdir, f"trace-s{seed}.json")
    out = os.path.join(workdir, f"result-s{seed}.json")

    subprocess.run([sys.executable, os.path.join(HERE, "gen_trace.py"),
                    "--days", str(days), "--agents", str(agents),
                    "--seed", str(seed), "--out", trace],
                   check=True, capture_output=True)

    proc = subprocess.run(
        [sys.executable, os.path.join(HERE, "retention_eval.py"),
         "--trace", trace, "--url", url, "--backends", backends,
         "--json-out", out],
        capture_output=True, text=True)
    if proc.returncode != 0:
        print(f"  seed {seed}: FAILED\n{proc.stdout[-800:]}\n{proc.stderr[-800:]}",
              file=sys.stderr)
        return None
    # A backend that fails is skipped by `retention_eval` with `continue`, so the
    # exit code stays 0 and the failure is visible only in stderr. Checking the
    # result set — not just the return code — is what keeps a run from being
    # reported as complete while a whole arm is missing.
    with open(out, encoding="utf-8") as fh:
        result = json.load(fh)
    want = {b.strip() for b in backends.split(",") if b.strip()}
    got = set(result["by_backend"].keys())
    # Names in the result are backend labels, not the CLI keys; map the ones that
    # depend on mode so the check works for either spelling.
    expected_labels = set()
    for b in want:
        expected_labels.add({"flat": "flat-recency",
                             "compaction": "one-shot-compaction",
                             "chronomem-exact": "chronomem-exact",
                             "chronomem-summary": "chronomem-summary"}.get(b, b))
    missing = expected_labels - got
    if missing:
        print(f"  seed {seed}: INCOMPLETE — missing {sorted(missing)}", file=sys.stderr)
        print(f"    stderr tail: {proc.stderr[-600:]}", file=sys.stderr)
        return None
    return result


def aggregate(results: list[dict]) -> dict:
    """Mean/std of accuracy per (backend, lag bucket) across seeds."""
    agg: dict = {}
    for r in results:
        for backend, data in r["by_backend"].items():
            agg.setdefault(backend, {})
            for bucket, cell in data["curve"].items():
                agg[backend].setdefault(int(bucket), []).append(cell["accuracy"])
    out: dict = {}
    for backend, buckets in agg.items():
        out[backend] = {}
        for b, accs in sorted(buckets.items()):
            out[backend][b] = {
                "n_seeds": len(accs),
                "mean": statistics.fmean(accs),
                "std": statistics.stdev(accs) if len(accs) > 1 else 0.0,
                "values": accs,
            }
    return out


def print_table(agg: dict, n_seeds: int) -> None:
    backends = list(agg.keys())
    buckets = sorted({b for v in agg.values() for b in v})
    print(f"\n=== accuracy by lag, mean ± std over {n_seeds} seeds ===\n")
    header = f"{'lag(d)':>7} " + " ".join(f"{b[:20]:>22}" for b in backends)
    print(header)
    print("-" * len(header))
    for b in buckets:
        row = []
        for name in backends:
            cell = agg[name].get(b)
            row.append(f"{cell['mean']:>13.1%} ±{cell['std']:>5.1%}"
                       if cell else f"{'-':>22}")
        print(f"{b:>7} " + " ".join(row))

    print("\n=== overall (mean of per-seed overall accuracy) ===")
    for name in backends:
        vals = [c["mean"] for c in agg[name].values()]
        print(f"  {name:22} {statistics.fmean(vals):>7.1%}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--agents", type=int, default=3)
    ap.add_argument("--seeds", default=",".join(str(s) for s in DEFAULT_SEEDS))
    ap.add_argument("--backends", default="flat,compaction,chronomem-exact,chronomem-summary")
    ap.add_argument("--url", default="http://127.0.0.1:18900/mcp")
    ap.add_argument("--workdir", default=os.path.join(HERE, ".work"))
    ap.add_argument("--json-out", default=os.path.join(HERE, ".work", "multi.json"))
    ap.add_argument("--summarize-only", help="aggregate an existing multi.json")
    args = ap.parse_args()

    os.makedirs(args.workdir, exist_ok=True)

    if args.summarize_only:
        with open(args.summarize_only, encoding="utf-8") as fh:
            payload = json.load(fh)
        print_table(payload["aggregate"], payload["n_seeds"])
        return 0

    seeds = [int(s) for s in args.seeds.split(",") if s.strip()]
    results = []
    for i, seed in enumerate(seeds, 1):
        print(f"[{i}/{len(seeds)}] seed {seed} ...", flush=True)
        r = run_one(seed, args.days, args.agents, args.workdir,
                    args.backends, args.url)
        if r:
            results.append(r)
            # Report the backend that is the point of the run, but do not print a
            # bogus number when it was not part of this invocation.
            if "chronomem-summary" in r["by_backend"]:
                acc = r["by_backend"]["chronomem-summary"]["overall_accuracy"]
                print(f"  ok (summary overall {acc:.1%})", flush=True)
            else:
                print("  ok", flush=True)

    if not results:
        print("no successful runs", file=sys.stderr)
        return 1

    agg = aggregate(results)
    payload = {
        "n_seeds": len(results),
        "seeds": seeds[:len(results)],
        "days": args.days,
        "backends": args.backends,
        "aggregate": agg,
        "per_seed": [{"seed": s, "by_backend": r["by_backend"]}
                     for s, r in zip(seeds, results)],
    }
    with open(args.json_out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)
    print(f"\nwrote {args.json_out}")
    print_table(agg, len(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())

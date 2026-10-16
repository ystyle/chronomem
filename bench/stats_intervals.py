#!/usr/bin/env python3
"""
Confidence intervals for the retention buckets, and what they do to the claims.

The reviewer's point is that bucket-level accuracy rests on 2–14 probes and is
reported as a bare percentage, so a reader cannot tell a robust effect from a
noisy one. This computes a Wilson score interval per bucket — the right interval
for a binomial proportion when n is small, unlike the normal approximation,
which can produce bounds outside [0,1] at these sizes.

It also answers the question the intervals raise: **which claims survive the
uncertainty?** For each pair of arms it reports whether their intervals at a
given lag are disjoint, which is the conservative reading, and how many
additional probes would be needed to detect the observed gap at 80% power.

Reads the archived results; writes an annotated table for the paper.

Usage:
    python3 stats_intervals.py --out results/retention/intervals.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results")


def wilson(k: int, n: int, z: float = 1.96) -> tuple[float, float]:
    """Wilson score interval for k successes in n trials (95% by default)."""
    if n == 0:
        return (0.0, 1.0)
    p = k / n
    d = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / d
    half = (z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))) / d
    return (max(0.0, centre - half), min(1.0, centre + half))


def n_for_power(p1: float, p2: float, power: float = 0.8, alpha: float = 0.05) -> int | None:
    """Probes per arm needed to detect a gap p1-p2 at the given power.

    Normal approximation, two-sided; returns None when the gap is zero.
    """
    if abs(p1 - p2) < 1e-9:
        return None
    z_a = 1.959964 if abs(alpha - 0.05) < 1e-6 else 1.644854
    z_b = 0.841621 if abs(power - 0.8) < 1e-6 else 1.281552
    pbar = (p1 + p2) / 2
    n = ((z_a * math.sqrt(2 * pbar * (1 - pbar)) + z_b * math.sqrt(p1 * (1 - p1) + p2 * (1 - p2))) ** 2) / ((p1 - p2) ** 2)
    return int(math.ceil(n))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    with open(os.path.join(RESULTS, "retention", "five-arm-seed7.json"),
              encoding="utf-8") as fh:
        five = json.load(fh)
    with open(os.path.join(RESULTS, "retention", "multi3.json"),
              encoding="utf-8") as fh:
        multi = json.load(fh)

    # Reconstruct k per bucket from accuracy*n, using the per-seed aggregate for
    # the multi-seed arms and the single-run file for the rest.
    out = {"buckets": {}, "pairwise": [], "power": []}

    print("=== per-bucket 95% Wilson intervals (seed 7, single run) ===")
    print(f"{'arm':26} {'lag':>5} {'k/n':>7} {'acc':>7} {'95% CI':>16}")
    for arm, data in five["by_backend"].items():
        out["buckets"][arm] = {}
        for lag, cell in sorted(data["curve"].items(), key=lambda x: int(x[0])):
            n = cell["n"]
            k = round(cell["accuracy"] * n)
            lo, hi = wilson(k, n)
            out["buckets"][arm][lag] = {"k": k, "n": n, "acc": cell["accuracy"],
                                        "ci_low": lo, "ci_high": hi,
                                        "label": cell.get("label", lag)}
            print(f"{arm:26} {cell.get('label', lag):>5} {k:>3}/{n:<3} "
                  f"{cell['accuracy']:>6.1%} [{lo:>5.1%}, {hi:>5.1%}]")

    # Which comparisons survive the intervals?
    print()
    print("=== do the key gaps survive their intervals? ===")
    pairs = [
        ("chronomem-exact", "flat-recency", "exact vs recency"),
        ("chronomem-exact", "one-shot-compaction", "exact vs compaction"),
        ("chronomem-summary", "chronomem-summary-week", "day vs week summary"),
    ]
    for a1, a2, name in pairs:
        for lag in sorted(out["buckets"][a1], key=lambda x: int(x)):
            c1 = out["buckets"][a1][lag]
            c2 = out["buckets"][a2].get(lag)
            if not c2:
                continue
            disjoint = c1["ci_high"] < c2["ci_low"] or c2["ci_high"] < c1["ci_low"]
            out["pairwise"].append({
                "comparison": name, "lag": lag,
                "a": {k: c1[k] for k in ("acc", "n", "ci_low", "ci_high")},
                "b": {k: c2[k] for k in ("acc", "n", "ci_low", "ci_high")},
                "intervals_disjoint": disjoint,
            })
            if lag in ("1", "7", "14"):
                print(f"  {name:22} lag {c1['label']:>5}: "
                      f"{c1['acc']:>6.1%} [{c1['ci_low']:.0%},{c1['ci_high']:.0%}] vs "
                      f"{c2['acc']:>6.1%} [{c2['ci_low']:.0%},{c2['ci_high']:.0%}]  "
                      f"{'disjoint' if disjoint else 'OVERLAP'}")

    # How many probes would be needed for the day/week gap?
    print()
    print("=== probes per arm needed to resolve the day/week gap at 80% power ===")
    for lag in sorted(out["buckets"]["chronomem-summary"], key=lambda x: int(x)):
        d = out["buckets"]["chronomem-summary"][lag]
        w = out["buckets"]["chronomem-summary-week"].get(lag)
        if not w:
            continue
        need = n_for_power(d["acc"], w["acc"])
        out["power"].append({"lag": lag, "label": d["label"],
                             "day_acc": d["acc"], "week_acc": w["acc"],
                             "probes_needed_per_arm": need})
        print(f"  lag {d['label']:>5}: day {d['acc']:>6.1%} vs week {w['acc']:>6.1%}"
              f"  -> {need if need else 'n/a'} probes/arm (current n={d['n']})")

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)
    print(f"\nwrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

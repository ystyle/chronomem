#!/usr/bin/env python3
"""
A second, independent lexical measure, to test whether token survival biases the result.

The reviewer asked (question 3) whether we had considered n-gram overlap, ROUGE or
edit distance as an alternative to the token metric, after the embedding-based
semantic measure proved unusable on this deployment.

An honest framing first, because it decides what this can conclude: **ROUGE-L and
edit distance are still lexical measures.** They compare surface sequences, so they
do not close the gap the reviewer identified — a fact restated in different words
scores low on both, just as it scores low on token survival. What they *can* do is
different and useful: they test whether the specific choices inside the token metric
(which token classes count, how membership is tested) bias the ordering. If a
sequence-overlap measure that shares none of those choices reproduces the same
day-vs-week ordering, the ordering is not an artefact of the token design.

Measured per project-week pair, on the same 52 pairs as `week_step.py`:

  rouge_l_f       ROUGE-L F1 between the day text and the week section
  edit_ratio      difflib ratio (2*M/(len_a+len_b)), a normalized edit similarity
  tok_*           the token-survival rates, for comparison

The quantity that matters is not the absolute value of any of them — a week summary
covering six days is *supposed* to differ from one day's text — but whether they
agree with token survival about which regime a pair is in.

Read-only against production.
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import statistics
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from sample_real import rpc                                  # noqa: E402
from token_survival import (group_text, numeric_tokens, symbol_tokens,   # noqa: E402
                            causal_tokens, DAY_MS, CST, TYPE)

WEEK_MS = 7 * DAY_MS


def rouge_l_f(a: str, b: str) -> float:
    """ROUGE-L F1 on character n-grams (length 2), the standard LCS-free variant.

    Character bigrams rather than whitespace tokens: the corpus is Chinese, which
    has no word delimiters, so whitespace tokenisation would make ROUGE meaningless
    for most of it.
    """
    if not a or not b:
        return 0.0
    ga = Counter(a[i:i + 2] for i in range(len(a) - 1))
    gb = Counter(b[i:i + 2] for i in range(len(b) - 1))
    if not ga or not gb:
        return 0.0
    overlap = sum((ga & gb).values())
    prec = overlap / sum(gb.values())
    rec = overlap / sum(ga.values())
    return 2 * prec * rec / (prec + rec) if prec + rec else 0.0


def token_rates(day_text: str, week_text: str) -> dict[str, float | None]:
    out = {}
    for kind, fn in (("numeric", numeric_tokens), ("symbol", symbol_tokens),
                     ("causal", causal_tokens)):
        toks = fn(day_text)
        kept = {t for t in toks if t in week_text}
        out[kind] = len(kept) / len(toks) if toks else None
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default="http://127.0.0.1:8900/mcp")
    ap.add_argument("--weeks", type=int, default=4)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    import re as _re
    from datetime import datetime
    wins = [(int(x), int(y)) for x, y in
            _re.findall(r"窗口 (\d+)~(\d+)",
                        rpc(a.url, "mem/summaries", {"type": TYPE, "limit": 500}))]
    # A week window is 7 days wide; taking every "window" listed would also pick
    # up day windows and measure nonsense (53 candidate windows collapse to 47
    # real weeks here). Same filter as week_step.py, so the two scripts measure
    # the same pairs.
    now = datetime.now(CST)
    weeks = sorted({f for f, t in wins if 6 <= (t - f) / DAY_MS < 8})
    weeks = [w for w in weeks
             if datetime.fromtimestamp((w + WEEK_MS) / 1000, CST) <= now][-a.weeks:]

    rows = []
    for w in weeks:
        week_groups = group_text(rpc(a.url, "mem/recall", {
            "type": TYPE, "granularity": "week", "mode": "summary",
            "windowStartMs": w}))
        per_proj: dict[str, list[str]] = {}
        for k in range(7):
            txt = rpc(a.url, "mem/recall", {
                "type": TYPE, "granularity": "day", "mode": "summary",
                "windowStartMs": w + k * DAY_MS})
            if "尚无语义摘要" in txt:
                continue
            for proj, body in group_text(txt).items():
                per_proj.setdefault(proj, []).append(body)

        for proj, day_bodies in per_proj.items():
            if proj not in week_groups:
                continue
            day_text = "\n".join(day_bodies)
            week_text = week_groups[proj]
            rates = token_rates(day_text, week_text)
            rows.append({
                "week": datetime.fromtimestamp(w / 1000, CST).strftime("%Y-%m-%d"),
                "proj": proj,
                "days_in_week": len(day_bodies),
                "day_chars": len(day_text), "week_chars": len(week_text),
                "length_ratio": len(week_text) / len(day_text) if day_text else 0.0,
                "rouge_l_f": rouge_l_f(day_text, week_text),
                "edit_ratio": difflib.SequenceMatcher(None, day_text, week_text).ratio(),
                **{f"tok_{k}": v for k, v in rates.items()},
            })

    def agg(sel, key):
        vals = [r[key] for r in rows if sel(r) and r.get(key) is not None]
        return statistics.fmean(vals) if vals else float("nan")

    single = lambda r: r["days_in_week"] == 1
    multi = lambda r: r["days_in_week"] > 1

    print(f"=== {len(rows)} project-week pairs ===")
    print(f"{'measure':14} {'1 day':>10} {'>=2 days':>10} {'gap':>8}")
    out = {"n_pairs": len(rows), "n_single": sum(1 for r in rows if single(r)),
           "n_multi": sum(1 for r in rows if multi(r)), "measures": {}}
    for key in ("length_ratio", "rouge_l_f", "edit_ratio",
                "tok_numeric", "tok_symbol", "tok_causal"):
        s, m = agg(single, key), agg(multi, key)
        out["measures"][key] = {"single": s, "multi": m, "gap": s - m}
        print(f"{key:14} {s:>10.3f} {m:>10.3f} {s - m:>+8.3f}")

    # Do the measures agree about which regime a pair is in? Rank-based check:
    # a measure "agrees" if a single-input pair scores higher than a multi-input one.
    print()
    print("=== agreement: which regime does each measure rank higher? ===")
    for key in ("rouge_l_f", "edit_ratio", "tok_numeric", "tok_symbol", "tok_causal"):
        sv = [r[key] for r in rows if single(r) and r.get(key) is not None]
        mv = [r[key] for r in rows if multi(r) and r.get(key) is not None]
        if not sv or not mv:
            continue
        # Probability a random single pair outscores a random multi pair
        # (AUC-style). Ties count as half: both survival and edit measures are
        # heavily tied at 1.0, and scoring a tie as a loss makes a measure with
        # many perfect scores look uninformative — measured as 0.57 before this
        # was fixed, purely because ties were counted against it.
        wins = sum(1 for x in sv for y in mv if x > y)
        ties = sum(1 for x in sv for y in mv if x == y)
        auc = (wins + 0.5 * ties) / (len(sv) * len(mv))
        out.setdefault("auc_single_over_multi", {})[key] = auc
        print(f"  {key:14} P(single > multi) = {auc:.3f}")

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)
    print(f"\nwrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

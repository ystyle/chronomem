#!/usr/bin/env python3
"""
Per-project token survival along the summary chain.

Correcting two mistakes made in earlier attempts at this measurement:

1. **The chain is recursive per project, not per day.** The summarizer's
   default is bottom-up: a week record for project P is built from the *day*
   records of P (see `summarizeWindowCore` — it collects sub-summaries into
   `byGroup[rec.groupKey]`). So the honest comparison is
   `raw(P, day) → day summary(P) → week summary(P)`, not "the whole day's
   summaries" against "the whole week's summaries".

2. **Comparing ungrouped day vs week summaries is a length artefact.** A week
   bundle covers 5–7 days and is ~3.4x longer than a day bundle, so it contains
   more numbers simply by being bigger — which made week look *better* at
   retaining quantities (42% vs 29%) for no real reason. Restricting both sides
   to the same project removes that.

Measured per token class: what fraction of the raw entries' quantities,
identifiers and causal markers still appear at the day level, and then at the
week level (relative to the day level, which is what the recursion actually
transforms).

Read-only. Uses `mem/recall` (grouped summaries) and `mem/query` (raw by tag).

Usage:
    python3 token_survival.py --days 2026-10-10,2026-10-06 --out results/real-corpus/token-survival.json
    python3 token_survival.py --auto --out results/real-corpus/token-survival.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from sample_real import rpc, _assert_read_only          # noqa: E402

CST = timezone(timedelta(hours=8))
DAY_MS = 86_400_000
HOUR_MS = 3_600_000
TYPE = "worklog"

NUMERIC_RE = re.compile(
    r"(?<![\w.])(?:\d+/\d+|\d+(?:\.\d+)?)(?![\w])")
SYMBOL_RE = re.compile(
    r"`([^`\n]{2,40})`"
    r"|(--[a-z][a-z0-9-]{2,})"
    r"|\b([a-z][a-z0-9]*(?:[A-Z][a-z0-9]+)+)\b"
    r"|\b([a-z][a-z0-9]{2,}_[a-z0-9_]+)\b")
CAUSAL_MARKERS = ["因为", "由于", "根因", "导致", "因此", "所以", "退化成",
                  "原因是", "为了", "避免", "否则"]


def group_text(blob: str) -> dict[str, str]:
    """Split `【group】...` blocks out of a `mem/recall` reply."""
    parts = re.split(r"【([^】]+)】", blob)
    return {parts[i].strip(): parts[i + 1]
            for i in range(1, len(parts) - 1, 2)}


def numeric_tokens(text: str) -> set[str]:
    out = set()
    for m in NUMERIC_RE.finditer(text):
        t = m.group(0)
        digits = re.sub(r"\D", "", t)
        if len(digits) < 2:
            continue
        if re.fullmatch(r"20\d\d", digits):        # a year is a label
            continue
        out.add(t)
    return out


def symbol_tokens(text: str) -> set[str]:
    out = set()
    for m in SYMBOL_RE.finditer(text):
        tok = next((g for g in m.groups() if g), None)
        if tok and len(tok) >= 3 and not tok.isdigit():
            out.add(tok.strip())
    return out


def causal_tokens(text: str) -> set[str]:
    return {c for c in CAUSAL_MARKERS if c in text}


EXTRACTORS = {"numeric": numeric_tokens, "symbol": symbol_tokens,
              "causal": causal_tokens}


def day_start(day: str) -> int:
    return int(datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=CST).timestamp() * 1000)


def week_key(ms: int) -> int:
    shifted = ms + 8 * HOUR_MS
    ds = shifted - (shifted % DAY_MS)
    return (ds - (((ds // DAY_MS) + 3) % 7) * DAY_MS) - 8 * HOUR_MS


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default="http://127.0.0.1:8900/mcp")
    ap.add_argument("--days", help="comma-separated YYYY-MM-DD list")
    ap.add_argument("--auto", action="store_true",
                    help="pick days that have both a day and a week summary")
    ap.add_argument("--limit", type=int, default=12, help="max days with --auto")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if args.auto:
        s = rpc(args.url, "mem/summaries", {"type": TYPE, "limit": 500})
        wins = [(int(a), int(b)) for a, b in re.findall(r"窗口 (\d+)~(\d+)", s)]
        days_ms = sorted({a for a, b in wins if 0.5 <= (b - a) / DAY_MS < 1.5},
                         reverse=True)
        weeks = {a for a, b in wins if 6 <= (b - a) / DAY_MS < 8}
        picked = [d for d in days_ms if week_key(d) in weeks][:args.limit]
        if not picked:
            print("no day has both summaries", file=sys.stderr)
            return 1
    else:
        picked = [day_start(d.strip()) for d in args.days.split(",") if d.strip()]

    rows = []
    for dms in picked:
        label = datetime.fromtimestamp(dms / 1000, CST).strftime("%Y-%m-%d")
        # Raw entries are not grouped by the service; per-project raw material is
        # obtained by asking each group separately.
        day_groups = group_text(rpc(args.url, "mem/recall", {
            "type": TYPE, "granularity": "day", "mode": "summary",
            "windowStartMs": dms}))
        week_groups = group_text(rpc(args.url, "mem/recall", {
            "type": TYPE, "granularity": "week", "mode": "summary",
            "windowStartMs": dms}))

        common = sorted(set(day_groups) & set(week_groups))
        for proj in common:
            raw = rpc(args.url, "mem/query", {
                "type": TYPE, "from": dms, "to": dms + DAY_MS - 1,
                "tag": f"proj={proj}", "limit": 200})
            row = {"day": label, "proj": proj,
                   "raw_chars": len(raw),
                   "day_chars": len(day_groups[proj]),
                   "week_chars": len(week_groups[proj])}
            for kind, fn in EXTRACTORS.items():
                toks = fn(raw)
                kept_day = {t for t in toks if t in day_groups[proj]}
                kept_week = {t for t in kept_day if t in week_groups[proj]}
                row[kind] = {
                    "raw_n": len(toks),
                    "day_keep": len(kept_day) / len(toks) if toks else None,
                    # Relative to the day level: the recursion consumes day
                    # summaries, so this is the loss the chain itself adds.
                    "day_to_week_keep": (len(kept_week) / len(kept_day)
                                         if kept_day else None),
                }
            rows.append(row)

    print(f"{'day':11} {'proj':18} {'raw':>7} {'day':>6} {'week':>6} "
          f"{'num d/w':>10} {'sym d/w':>10}")
    print("-" * 76)
    for r in rows[:30]:
        nd = r["numeric"]["day_keep"]
        nw = r["numeric"]["day_to_week_keep"]
        sd = r["symbol"]["day_keep"]
        sw = r["symbol"]["day_to_week_keep"]
        f = lambda v: f"{v:.0%}" if v is not None else "-"
        print(f"{r['day']:11} {r['proj'][:18]:18} {r['raw_chars']:>7} "
              f"{r['day_chars']:>6} {r['week_chars']:>6} "
              f"{f(nd)+'/'+f(nw):>10} {f(sd)+'/'+f(sw):>10}")
    if len(rows) > 30:
        print(f"... ({len(rows)} rows total)")

    agg = {}
    for kind in EXTRACTORS:
        d1 = [r[kind]["day_keep"] for r in rows if r[kind]["day_keep"] is not None]
        d2 = [r[kind]["day_to_week_keep"] for r in rows
              if r[kind]["day_to_week_keep"] is not None]
        agg[kind] = {
            "pairs": len(d1),
            "raw_to_day_mean": statistics.fmean(d1) if d1 else None,
            "day_to_week_mean": statistics.fmean(d2) if d2 else None,
            "raw_to_day_std": statistics.stdev(d1) if len(d1) > 1 else 0.0,
            "day_to_week_std": statistics.stdev(d2) if len(d2) > 1 else 0.0,
        }

    print(f"\n=== per-project survival ({len(rows)} project-day pairs) ===")
    print(f"{'kind':10} {'raw→day':>10} {'day→week':>10}")
    for kind, a in agg.items():
        f = lambda v: f"{v:.1%}" if v is not None else "-"
        print(f"{kind:10} {f(a['raw_to_day_mean']):>10} {f(a['day_to_week_mean']):>10}")
    print("\n(raw→day: share of the raw entries' tokens still at the day level;")
    print(" day→week: share of those still at the week level, i.e. what the")
    print(" recursive step itself drops)")

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump({"pairs": len(rows), "aggregate": agg, "rows": rows},
                  fh, ensure_ascii=False, indent=1)
    print(f"\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

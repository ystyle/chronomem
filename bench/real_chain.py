#!/usr/bin/env python3
"""
Does a fact survive up the summary chain, on the **real** deployment corpus?

This is the reviewer's §6(ii) question ("drift along the summary chain") applied
to the live records rather than a synthetic trace. Unlike the retention study it
cannot produce an accuracy figure — the real corpus has no ground truth — so it
measures **survival**: for facts we know from independent reading of the work
log, is the fact still recoverable from (a) the raw entries, (b) the day summary,
(c) the week summary?

Three outcomes are distinguished, and keeping them apart is the whole point:

  * `absent`   — the layer was queried and the fact is not in it
  * `missing`  — the layer has NO summary for that window at all
  * `intact`   — the fact's key terms are present

Conflating `missing` with `absent` reports non-existent summaries as information
loss. That mistake was made twice while building this harness (once here, once in
the drift study), so the code makes the distinction explicit.

Read-only throughout; `sample_real`'s read-only guard is reused for the calls.

Usage:
    python3 real_chain.py --json-out .work/real/chain.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from sample_real import rpc, _assert_read_only          # noqa: E402

CST = timezone(timedelta(hours=8))
WORKLOG = "worklog"

# Facts verified independently by reading the work log, with the *distinctive*
# terms that must appear for the fact to count as recovered. `core` is the
# minimal set a compressed summary would still be expected to carry.
FACTS = [
    {
        "id": "OOM3",
        "day": "2026-09-15",
        "desc": "第三次写路径 OOM：根因（幂等物化 + 堆无余量）与两项修复",
        "raw_terms": ["幂等", "1GB", "256MB", "存活量", "217-240MB"],
        "core_terms": ["幂等", "1GB"],
    },
    {
        "id": "IDXWAIT",
        "day": "2026-09-15",
        "desc": "cjreg 索引等待阶梯与默认不超时",
        "raw_terms": ["5s", "3m", "不超时"],
        "core_terms": ["不超时"],
    },
    {
        "id": "RENAME",
        "day": "2026-09-14",
        "desc": "前端产品名改「星痕的炼金工房」，localStorage 键有意不改",
        "raw_terms": ["星痕", "localStorage", "LiveboardWs"],
        "core_terms": ["星痕"],
    },
    {
        "id": "RELATION",
        "day": "2026-09-14",
        "desc": "忆时塔是「模式」的试验场，不是直接调服务",
        "raw_terms": ["试验场", "模式"],
        "core_terms": ["试验场"],
    },
    {
        "id": "SUMGAP",
        "day": "2026-09-16",
        "desc": "dsh/activity 总结缺失：compact 全量进 prompt 超 32768",
        "raw_terms": ["compact", "32768", "400", "无限重试"],
        "core_terms": ["32768", "compact"],
    },
    {
        "id": "MODELAB",
        "day": "2026-09-16",
        "desc": "4b vs 9b-mtp A/B 与 prefill 速度",
        "raw_terms": ["317", "267", "9b-mtp"],
        "core_terms": ["9b-mtp"],
    },
]


def day_ms(day: str) -> int:
    return int(datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=CST).timestamp() * 1000)


def day_window(ms: int) -> int:
    shifted = ms + 8 * 3_600_000
    return shifted - (shifted % 86_400_000) - 8 * 3_600_000


def week_window(ms: int) -> int:
    shifted = ms + 8 * 3_600_000
    ds = shifted - (shifted % 86_400_000)
    return (ds - (((ds // 86_400_000) + 3) % 7) * 86_400_000) - 8 * 3_600_000


NO_SUMMARY = ("尚无语义摘要", "no summary")


def layer(url: str, granularity: str, ms: int, terms: list[str]) -> dict:
    """Recall one layer and classify the outcome."""
    _assert_read_only("mem/recall")
    text = rpc(url, "mem/recall", {
        "type": WORKLOG, "granularity": granularity,
        "mode": "summary" if granularity != "raw" else "exact",
        "windowStartMs": ms,
    })
    if any(m in text for m in NO_SUMMARY):
        return {"state": "missing", "hits": [], "chars": len(text)}
    hits = [t for t in terms if t in text]
    return {"state": "intact" if hits else "absent", "hits": hits,
            "chars": len(text),
            "matched": f"{len(hits)}/{len(terms)}"}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default="http://127.0.0.1:8900/mcp")
    ap.add_argument("--json-out", required=True)
    args = ap.parse_args()

    rows = []
    for f in FACTS:
        ms = day_ms(f["day"])
        dw, ww = day_window(ms), week_window(ms)
        raw = rpc(args.url, "mem/recall", {
            "type": WORKLOG, "granularity": "day", "mode": "exact",
            "windowStartMs": ms})
        raw_hits = [t for t in f["raw_terms"] if t in raw]
        day = layer(args.url, "day", ms, f["core_terms"])
        week = layer(args.url, "week", ms, f["core_terms"])
        rows.append({
            "id": f["id"], "date": f["day"], "desc": f["desc"],
            "raw": {"state": "intact" if raw_hits else "absent",
                    "hits": raw_hits, "chars": len(raw),
                    "matched": f"{len(raw_hits)}/{len(f['raw_terms'])}"},
            "day": day, "week": week,
            "day_window": dw, "week_window": ww,
        })

    print(f"{'fact':10} {'day':12} {'raw':>14} {'day-sum':>12} {'week-sum':>10}")
    print("-" * 64)
    for r in rows:
        print(f"{r['id']:10} {r['date']:12} "
              f"{r['raw']['matched']:>14} "
              f"{(r['day']['matched'] if r['day']['state'] != 'missing' else 'MISSING'):>12} "
              f"{(r['week']['matched'] if r['week']['state'] != 'missing' else 'MISSING'):>10}")

    n = len(rows)
    print()
    print(f"raw recoverable      : {sum(1 for r in rows if r['raw']['state']=='intact')}/{n}")
    print(f"day summary recoverable: {sum(1 for r in rows if r['day']['state']=='intact')}/{n}"
          f"   (missing: {sum(1 for r in rows if r['day']['state']=='missing')})")
    print(f"week summary recoverable: {sum(1 for r in rows if r['week']['state']=='intact')}/{n}"
          f"   (missing: {sum(1 for r in rows if r['week']['state']=='missing')})")

    with open(args.json_out, "w", encoding="utf-8") as fh:
        json.dump({"rows": rows}, fh, ensure_ascii=False, indent=1)
    print(f"\nwrote {args.json_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

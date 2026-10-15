#!/usr/bin/env python3
"""
Sample the **real** deployment corpus for a qualitative coverage check.

Why this exists separately from the synthetic study: the retention experiments
prove mechanism-level differences, but they run on a generated trace. This draws
from the actual `worklog` / `dsh/activity` records of a deployment that has been
running for ~2 months, which is the material the paper points at for its
realism claim — and it is also the reviewer's §6(ii) "drift along the summary
chain" question.

Real records have no ground truth, so nothing here computes accuracy. What it
produces is a judgement task: for a given window, take the raw entries, the day
summary and the week summary, and ask whether a fact present in the raw entries
still survives at each coarser level. Coverage at day vs week is the drift curve.

Read-only against the service: only `mem/query`, `mem/recall` and `mem/summaries`
are called. No type is created, nothing is written.

Note the deliberate asymmetry with `backends.py`: `ChronomemBackend` **refuses**
port 8900 because the retention experiments write. This script defaults to the
*production* endpoint, because the whole point is to read the real deployment's
own records — an isolated instance has none. That is safe only as long as it
stays read-only, so `_assert_read_only()` below fails loudly if a write tool ever
appears in the call set.

Usage:
    python3 sample_real.py --type worklog --days 8 --out .work/real/sample.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DAY_MS = 86_400_000
HOUR_MS = 3_600_000
TZ_SHIFT_MS = 8 * HOUR_MS          # the deployment runs Asia/Shanghai


READ_ONLY_TOOLS = {"mem/query", "mem/recall", "mem/summaries",
                   "mem/list_types", "mem/type_info", "mem/buckets"}


def _assert_read_only(tool: str) -> None:
    """Refuse to call anything that could modify the deployment.

    This script points at production by default, so the read-only property is
    enforced rather than promised: a future edit that adds, say, `mem/append`
    (or that reaches for `mem/summarize`, which costs LLM tokens and writes a
    record) fails immediately instead of mutating live data.
    """
    if tool not in READ_ONLY_TOOLS:
        raise RuntimeError(
            f"sample_real must stay read-only; refusing to call {tool!r}. "
            f"Allowed: {sorted(READ_ONLY_TOOLS)}")


def rpc(url: str, tool: str, args: dict) -> str:
    _assert_read_only(tool)
    body = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": tool, "arguments": args},
    }).encode()
    req = urllib.request.Request(url, data=body, headers={
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=90) as resp:
        payload = json.loads(resp.read().decode())
    if "error" in payload:
        raise RuntimeError(f"{tool}: {payload['error']}")
    return "\n".join(c.get("text", "") for c in payload["result"].get("content", []))


def day_window(ms: int) -> int:
    shifted = ms + TZ_SHIFT_MS
    return shifted - (shifted % DAY_MS) - TZ_SHIFT_MS


def week_window(ms: int) -> int:
    shifted = ms + TZ_SHIFT_MS
    day_start = shifted - (shifted % DAY_MS)
    dow_from_monday = ((day_start // DAY_MS) + 3) % 7
    return (day_start - dow_from_monday * DAY_MS) - TZ_SHIFT_MS


def parse_summary_windows(text: str) -> list[tuple[int, int, str]]:
    """Split `mem/summaries` output into (from, to, body) triples."""
    parts = re.split(r"\[[^\]]*?窗口 (\d+)~(\d+)[^\]]*\]", text)
    out = []
    for i in range(1, len(parts) - 2, 3):
        out.append((int(parts[i]), int(parts[i + 1]), parts[i + 2]))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default="http://127.0.0.1:8900/mcp")
    ap.add_argument("--type", default="worklog")
    ap.add_argument("--days", type=int, default=8,
                    help="how many distinct day windows to sample")
    ap.add_argument("--window-limit", type=int, default=40,
                    help="max entries per raw window")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    print(f"reading {args.type} summaries from the deployment ...")
    summaries = parse_summary_windows(rpc(args.url, "mem/summaries",
                                          {"type": args.type, "limit": 200}))
    if not summaries:
        print("no summaries found", file=sys.stderr)
        return 1

    day_ones = [(f, t, b) for f, t, b in summaries if 0.5 <= (t - f) / DAY_MS < 1.5]
    week_ones = [(f, t, b) for f, t, b in summaries if 6 <= (t - f) / DAY_MS < 8]
    print(f"  day summaries: {len(day_ones)}, week summaries: {len(week_ones)}")

    # `worklog` summarizes per `proj`, so one calendar day yields several day
    # summaries. Group by window so a sample is one *day*, not one project.
    by_day: dict[int, list[tuple[int, int, str]]] = {}
    for f, t, b in day_ones:
        by_day.setdefault(f, []).append((f, t, b))

    # Only days covered by a *closed* week window are usable: the current week is
    # intentionally not summarized yet, so the newest days have no week summary
    # to compare against. Sampling them would report "week: missing" and make the
    # chain look broken when it is merely unfinished.
    week_starts = sorted({f for f, _t, _b in week_ones})
    usable = []
    for wf in sorted(by_day, reverse=True):
        covering = [w for w in week_starts if w <= wf < w + 7 * DAY_MS]
        if covering:
            usable.append(wf)
    if not usable:
        print("no day window is covered by a closed week summary", file=sys.stderr)
        return 1
    print(f"  days covered by a closed week: {len(usable)}")

    picked = [(wf, by_day[wf]) for wf in usable[:args.days]]

    samples = []
    for wf, group in picked:
        wt = group[0][1]
        raw = rpc(args.url, "mem/query", {
            "type": args.type, "from": wf, "to": wt,
            "limit": args.window_limit,
        })
        wk = [w for w in week_starts if w <= wf < w + 7 * DAY_MS]
        # The week summary is produced **per `proj`**, so one week holds many
        # records (measured: 13–14 groups for a busy week). Taking the first
        # matching record therefore captures one project and silently discards
        # the rest — which made the week layer look like it "only covers a
        # single project" and produced a bogus near-total loss figure in an
        # earlier judging run. `mem/recall` returns the whole window, all groups
        # concatenated, which is what a reader actually gets.
        week_text = rpc(args.url, "mem/recall", {
            "type": args.type, "granularity": "week", "mode": "summary",
            "windowStartMs": wf,
        }) if wk else ""
        if "尚无语义摘要" in week_text:
            week_text = ""
        week_groups = re.findall(r"【([^】]+)】", week_text)
        samples.append({
            "day_window": [wf, wt],
            "week_window": [wk[0], wk[0] + 7 * DAY_MS - 1] if wk else None,
            "raw_entries": raw,
            # Several projects may summarize the same day; keep them all so the
            # judgement can be per-project rather than a merge that hides one.
            "day_summaries": [{"chars": len(b), "text": b.strip()} for _f, _t, b in group],
            "week_summary": week_text.strip() or None,
            "week_groups": week_groups,
        })

    payload = {"type": args.type,
               "n_day_summaries_total": len(day_ones),
               "n_week_summaries_total": len(week_ones),
               "samples": samples}
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)

    print(f"\nwrote {args.out}: {len(samples)} windows")
    for s in samples:
        wf, wt = s["day_window"]
        print(f"  day {wf}~{wt}: raw={len(s['raw_entries'])} chars, "
              f"day_sums={[d['chars'] for d in s['day_summaries']]}, "
              f"week_sum={'yes' if s['week_summary'] else 'NO'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

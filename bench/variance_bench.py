#!/usr/bin/env python3
"""
Summarization variance, measured by re-summarizing a *real* window in the bench
instance.

Two earlier attempts failed for opposite reasons, and both are worth recording:

  * the bench trace's windows are tiny (3 near-identical entries) and the model
    returned byte-identical text three times — no measurable spread;
  * the production corpus has no naturally repeated (window, group) pair at all:
    across 244 summary records the same window+group was never summarized twice,
    so it cannot supply the samples either.

The fix is to take the *content* of a real production window (read-only) into the
bench instance, where `recompute` is free, and summarize it R times. That has both
properties the measurement needs: realistic input size and repeatable runs.

Read-only against production; writes only to the bench instance.
"""
from __future__ import annotations
import argparse, difflib, json, os, re, statistics, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sample_real                      # read-only guarded, points at production
from drift_eval import rpc              # unguarded, for the bench instance
from backends import day_ms, day_window_start, JOB_ID_RE

PROD = "http://127.0.0.1:8900/mcp"
BENCH = "http://127.0.0.1:18900/mcp"
BTYPE = "bench/var"


def wait(url, jid, timeout=300):
    end = time.time() + timeout
    while time.time() < end:
        if "done" in rpc(url, "mem/summarize_status", {"job_id": jid}) or \
           "failed" in rpc(url, "mem/summarize_status", {"job_id": jid}):
            return
        time.sleep(2)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--days", default="2026-09-12,2026-09-15",
                    help="production day windows to use as input")
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    xa = re.compile(r"\[(\d\d-\d\d \d\d:\d\d:\d\d)\]")
    rows = []
    for day in [d.strip() for d in a.days.split(",") if d.strip()]:
        from datetime import datetime, timezone, timedelta
        CST = timezone(timedelta(hours=8))
        t0 = int(datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=CST).timestamp() * 1000)
        # 1) read the real window's raw entries from production (read-only)
        raw = sample_real.rpc(PROD, "mem/query", {
            "type": "worklog", "from": t0, "to": t0 + 86_400_000 - 1, "limit": 200})
        # The listing is one entry per line, each with its own timestamp prefix;
        # re-timestamp them into the bench trace's base so the window lines up.
        lines = [l for l in raw.splitlines() if xa.match(l)]
        if not lines:
            print(f"{day}: no raw entries, skipped")
            continue

        # 2) import into the bench instance under its own day base
        rpc(BENCH, "mem/truncate", {"type": BTYPE})
        try:
            rpc(BENCH, "mem/type_create",
                {"name": BTYPE, "levels": ["day"], "auto_summarize": False})
        except Exception:
            pass
        base = day_window_start(1)
        for i, l in enumerate(lines):
            body = xa.sub("", l, count=1).strip()
            rpc(BENCH, "mem/append", {
                "type": BTYPE, "payload": {"text": body}, "ts": base + i * 1000})

        # 3) summarize the same window R times
        texts = []
        for _ in range(a.reps):
            m = JOB_ID_RE.search(rpc(BENCH, "mem/summarize", {
                "type": BTYPE, "granularity": "day",
                "windowStartMs": base, "recompute": True}))
            if m:
                wait(BENCH, int(m.group(1)))
            txt = rpc(BENCH, "mem/recall", {
                "type": BTYPE, "granularity": "day", "mode": "summary",
                "windowStartMs": base})
            # `recall` returns every stored version, **newest first** (verified
            # against the generation timestamps in `mem/summaries`). Taking the
            # last block therefore reads the *oldest* version, and an earlier run
            # of this script compared the same oldest version to itself three
            # times and concluded the model was deterministic — the opposite of
            # the truth. Read the first block.
            blocks = [b for b in re.split(r"(?=【)", txt.strip()) if b.strip()]
            texts.append(blocks[0] if blocks else txt)

        lens = [len(t) for t in texts]
        sims = [difflib.SequenceMatcher(None, texts[i], texts[j]).ratio()
                for i in range(len(texts)) for j in range(i + 1, len(texts))]
        row = {
            "source_day": day, "n_entries": len(lines), "reps": a.reps,
            "input_chars": sum(len(l) for l in lines),
            "chars": lens, "chars_mean": statistics.fmean(lens),
            "chars_stdev": statistics.stdev(lens) if len(lens) > 1 else 0.0,
            "similarity_mean": statistics.fmean(sims) if sims else 1.0,
            "similarity_min": min(sims) if sims else 1.0,
        }
        rows.append(row)
        print(f"{day}: {len(lines)} entries, {row['input_chars']} input chars -> "
              f"lengths {lens} (mean {row['chars_mean']:.0f}, sd {row['chars_stdev']:.0f}), "
              f"similarity {row['similarity_mean']:.3f} (min {row['similarity_min']:.3f})")

    if rows:
        print()
        print(f"  windows: {len(rows)}, reps each: {a.reps}")
        print(f"  mean within-window length sd : {statistics.fmean([r['chars_stdev'] for r in rows]):.0f} chars")
        print(f"  mean pairwise similarity     : {statistics.fmean([r['similarity_mean'] for r in rows]):.3f}")
        print(f"  worst pairwise similarity    : {min(r['similarity_min'] for r in rows):.3f}")

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump({"reps": a.reps, "rows": rows}, fh, ensure_ascii=False, indent=1)
    print(f"\nwrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

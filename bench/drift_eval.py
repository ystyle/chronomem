#!/usr/bin/env python3
"""
Semantic-drift study: build a summary tower from a trace, then ask the same
questions at every level and measure how much accuracy each level loses.

The question this answers is the paper's §6(ii): *recursive summarization of
summaries is cheap but drifts*. Two things are compared:

  chained   — the coarse level is summarized FROM the finer summaries
              (`mem/summarize` default: bottom-up, aggregates children)
  recompute — the coarse level is rebuilt directly from the raw entries
              (`recompute: true`), which is faithful but costs more tokens

If chained and recompute score the same, the premise behind `recompute` is
wrong. If chained degrades with depth while recompute does not, the paper's
trade-off claim is supported by measurement.

Probes are split by **salience** because that is where drift should show up
first: a fact restated several times should survive chaining; a fact mentioned
once should be the first casualty.

Runs against the ISOLATED bench instance (port 18900), never production.

Usage:
    python3 drift_eval.py --trace .work/drift.json --url http://127.0.0.1:18900/mcp
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.request

DAY_MS = 86_400_000
HOUR_MS = 3_600_000
MTYPE = "bench/drift"
# The trace's hour 1 maps here. It must sit exactly on an hour boundary **in the
# service's timezone** (Asia/Shanghai, UTC+8), because windows are calendar-
# aligned there. An earlier value (1_700_000_000_000 = 22:13:20 UTC) was not on
# a boundary, so the windows this script computed and the windows the service
# materialized were offset from each other and every lookup missed.
TZ_SHIFT_MS = 8 * HOUR_MS
# 2024-01-01 00:00:00 +08:00, an exact hour/day/week boundary.
BASE_MS = 1_704_067_200_000 - TZ_SHIFT_MS


def rpc(url: str, tool: str, args: dict, rid: int = 1) -> str:
    """Call one MCP tool and return its text payload."""
    body = json.dumps({
        "jsonrpc": "2.0", "id": rid, "method": "tools/call",
        "params": {"name": tool, "arguments": args},
    }).encode()
    req = urllib.request.Request(url, data=body, headers={
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=120) as resp:
        payload = json.loads(resp.read().decode())
    if "error" in payload:
        raise RuntimeError(f"{tool}: {payload['error']}")
    return "\n".join(c.get("text", "") for c in payload["result"].get("content", []))


def hour_to_ms(hour: int) -> int:
    return BASE_MS + (hour - 1) * HOUR_MS


def window_start_ms(hour: int, granularity: str) -> int:
    """Start of the calendar window containing `hour`, in the service's timezone.

    Must reproduce the service's `windowRangeOf` exactly, because summary lookup
    is an **equality** match on (windowFrom, windowTo): a window computed even one
    day off does not miss by "close enough", it returns "no summary" and the
    experiment silently scores the level as empty.

    Two bugs were found here the hard way:
      * the base timestamp was not on an hour boundary, so every lookup missed;
      * the week start was computed as `dayStart - 3 days`, which is only correct
        when the day itself is a Thursday. The service anchors weeks to Monday
        00:00 local (ISO), so the shift has to be derived from the epoch weekday,
        not a constant. Measured error: 96 hours — a Friday instead of Monday.
    Days since the epoch: 1970-01-01 was a Thursday, so weekday index 0 = Monday
    needs a shift of 3 days from a Thursday epoch.
    """
    ms = hour_to_ms(hour)
    shifted = ms + TZ_SHIFT_MS
    if granularity == "1h":
        start = shifted - (shifted % HOUR_MS)
    elif granularity == "day":
        start = shifted - (shifted % DAY_MS)
    elif granularity == "week":
        day_start = shifted - (shifted % DAY_MS)
        days_since_epoch = day_start // DAY_MS
        # 1970-01-01 = Thursday. Monday is 4 days after Thursday mod 7.
        dow_from_monday = (days_since_epoch + 3) % 7
        start = day_start - dow_from_monday * DAY_MS
    else:
        raise ValueError(granularity)
    return start - TZ_SHIFT_MS


ANSWER_RE = re.compile(r"option\s+([A-D])", re.IGNORECASE)
ANSWER_RE_ZH = re.compile(r"(?:选项|方案|选择了?)\s*([A-D])")


def _pct(v) -> str:
    """Format an optional accuracy; None (no probes of that class) shows as `-`."""
    return "-" if v is None else f"{v:.0%}"


def extract(text: str, topic: str | None = None) -> str | None:
    """Read the option the summary states **for the asked-about topic**.

    Matching the first option anywhere in the text is wrong: a summary covers a
    whole window and mentions several topics, so "the first option" is usually
    some other topic's. That mistake made every same-window probe read the same
    letter (all "D") and looked exactly like severe drift.

    Strategy: split the summary into lines, prefer a line that mentions the
    topic, and only fall back to the whole text when no line names it (which is
    itself the drift signal — the summary dropped the topic).
    """
    if not text:
        return None
    lines = [ln for ln in text.splitlines() if ln.strip()]
    candidates = [ln for ln in lines if topic and topic in ln] if topic else []
    for scope in (candidates, lines):
        for ln in scope:
            for rx in (ANSWER_RE, ANSWER_RE_ZH):
                hits = rx.findall(ln)
                if hits:
                    return hits[0].upper()
    return None


def answer_from_summary(url: str, granularity: str, hour: int) -> str:
    return rpc(url, "mem/recall", {
        "type": MTYPE, "granularity": granularity, "mode": "summary",
        "windowStartMs": window_start_ms(hour, granularity),
    })


def summarize(url: str, granularity: str, hour: int, recompute: bool) -> str:
    """Submit one window's summarization and return the raw service reply.

    The reply carries the *job id*, which differs per submission. Keeping it is
    what makes `wait_until_done` able to track the job it just created — an
    earlier version polled a hard-coded `job_id: 1`, so it reported success
    while most windows were still queued, and the scoring pass then read a tower
    that was 5/39 built and concluded (wrongly) that every level scored 0.
    """
    return rpc(url, "mem/summarize", {
        "type": MTYPE, "granularity": granularity,
        "windowStartMs": window_start_ms(hour, granularity),
        "recompute": recompute,
    })


JOB_RE = re.compile(r"#\s*(\d+)")


def wait_until_done(url: str, job_ids: list[int], timeout_s: int = 900) -> None:
    """Block until every submitted job leaves pending/running."""
    pending = set(job_ids)
    deadline = time.time() + timeout_s
    while pending and time.time() < deadline:
        for jid in sorted(pending):
            txt = rpc(url, "mem/summarize_status", {"job_id": jid})
            if "done" in txt or "failed" in txt:
                pending.discard(jid)
        if pending:
            time.sleep(4)
    if pending:
        print(f"    WARNING: {len(pending)} jobs still pending after {timeout_s}s")


def summarize_and_wait(url: str, granularity: str, hour: int, recompute: bool) -> bool:
    """Submit and wait for one window. Returns False when submission failed."""
    reply = summarize(url, granularity, hour, recompute)
    m = JOB_RE.search(reply)
    if not m:
        # A window that is empty or already summarized returns prose, not a job.
        return False
    wait_until_done(url, [int(m.group(1))], timeout_s=600)
    return True


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--trace", required=True)
    ap.add_argument("--url", default="http://127.0.0.1:18900/mcp")
    ap.add_argument("--json-out")
    ap.add_argument("--skip-ingest", action="store_true",
                    help="reuse entries already in the instance")
    args = ap.parse_args()

    with open(args.trace, encoding="utf-8") as fh:
        trace = json.load(fh)

    # --- ingest --------------------------------------------------------------
    # The type must exist before anything can be written to it. An earlier
    # version relied on the type having been created by hand, so after a cleanup
    # every call failed and the run reported a uniform 0% at every level — which
    # reads as "total drift" but was simply "nothing was ever built".
    try:
        rpc(args.url, "mem/type_create", {
            "name": MTYPE,
            "description": "semantic drift study (synthetic)",
            "levels": ["1h", "day", "week"],
            "auto_summarize": False,
        })
        print(f"created type {MTYPE}")
    except RuntimeError as exc:
        if "已存在" not in str(exc):
            raise
        print(f"type {MTYPE} already exists")

    if not args.skip_ingest:
        print(f"ingesting {len(trace['events'])} events ...")
        rpc(args.url, "mem/truncate", {"type": MTYPE})
        for i, e in enumerate(trace["events"]):
            rpc(args.url, "mem/append", {
                "type": MTYPE,
                "payload": {"text": e["text"], "hour": e["hour"],
                            "salience": e["salience"], "topic": e["topic"]},
                "tags": {"topic": e["topic"] or "", "salience": e["salience"]},
                "ts": hour_to_ms(e["hour"]) + e["seq"],
            }, rid=i + 2)
            if (i + 1) % 100 == 0:
                print(f"  {i + 1}/{len(trace['events'])}")
        print("  ingested")

    hours = trace["meta"]["hours"]

    # --- build the tower, chained then recomputed ----------------------------
    results = {"chained": {}, "recompute": {}}
    for mode, recompute in (("chained", False), ("recompute", True)):
        print(f"\nbuilding {mode} tower ...")
        # Finest level first, then coarser ones — a chained coarse summary needs
        # its children to exist.
        for gran, step in (("1h", 1), ("day", 24), ("week", 168)):
            built = 0
            for h in range(1, hours + 1, step):
                try:
                    if summarize_and_wait(args.url, gran, h, recompute):
                        built += 1
                except RuntimeError as exc:
                    print(f"    {gran} h{h}: {exc}")
                    continue
            print(f"  {gran}: {built} windows summarized")
            # Verify the tower actually exists before scoring against it;
            # "submitted" is not "built" (see wait_until_done).
            have = len(re.findall(r"窗口", rpc(args.url, "mem/summaries",
                                              {"type": MTYPE})))
            print(f"  {gran}: {have} summaries now stored")

        # --- score every level -------------------------------------------------
        # A probe asks about a fact introduced at `introduced_hour`. To test a
        # given level, we read the window of THAT level which *contains the
        # fact* — the fact must be inside the window being judged. Reading the
        # window at `ask_at_hour` instead was the bug: the answer was never in
        # that window, so every level looked like total loss.
        #
        # Drift then shows up as signal dilution: a 1h window holds ~1 fact and
        # states it plainly; the day window holds ~24 facts, so any single one is
        # one line among many; the week window holds ~168 and the model must drop
        # most of them. The probe is the same question at every level; what
        # changes is how much the level had to compress.
        print(f"  scoring {mode} ...")
        for gran in ("1h", "day", "week"):
            per_probe = []
            missing_n = 0
            for p in trace["probes"]:
                txt = answer_from_summary(args.url, gran, p["introduced_hour"])
                # "No summary for this window" is not drift: it means the window
                # never closed (a 36h trace has no closed *week* window). Scoring
                # those as wrong reported a fabricated 0% at the coarsest level,
                # which reads as catastrophic drift when in fact no data exists.
                # They are counted separately and excluded from accuracy.
                if "尚无语义摘要" in txt or "no summary" in txt.lower():
                    missing_n += 1
                    continue
                got = extract(txt, p.get("topic"))
                per_probe.append({
                    "qid": p["qid"], "salience": p["salience"],
                    "expected": p["answer"], "got": got,
                    "correct": got == p["answer"],
                    "summary_chars": len(txt),
                })
            n = len(per_probe)
            acc = sum(x["correct"] for x in per_probe) / n if n else 0.0
            maj = [x for x in per_probe if x["salience"] == "major"]
            mino = [x for x in per_probe if x["salience"] == "minor"]
            avg_chars = sum(x["summary_chars"] for x in per_probe) / n if n else 0
            results[mode][gran] = {
                "accuracy": acc, "n": n, "missing": missing_n,
                "avg_summary_chars": avg_chars,
                "major_accuracy": (sum(x["correct"] for x in maj) / len(maj)) if maj else None,
                "minor_accuracy": (sum(x["correct"] for x in mino) / len(mino)) if mino else None,
                "per_probe": per_probe,
            }
            print(f"    {gran:5} acc={acc:.1%}  "
                  f"major={results[mode][gran]['major_accuracy']} "
                  f"minor={results[mode][gran]['minor_accuracy']}")

    # --- report --------------------------------------------------------------
    print("\n=== drift vs depth (same probes at every level) ===")
    print(f"{'level':6} {'chained':>9} {'recompute':>10} "
          f"{'maj(ch)':>8} {'min(ch)':>8} {'avg chars':>10} {'missing':>8}")
    for gran in ("1h", "day", "week"):
        c = results["chained"][gran]
        r = results["recompute"][gran]
        # With no scorable probes the level has no measurement, which must read
        # as "no data" rather than "0% accuracy".
        ca = f"{c['accuracy']:.1%}" if c["n"] else "-"
        ra = f"{r['accuracy']:.1%}" if r["n"] else "-"
        print(f"{gran:6} {ca:>8} {ra:>9} "
              f"{_pct(c['major_accuracy']):>8} {_pct(c['minor_accuracy']):>8} "
              f"{c['avg_summary_chars']:>10.0f} {c['missing']:>8}")
    print("\n(major = fact restated in several events; minor = mentioned once;")
    print(" missing = no summary existed for that window, excluded from accuracy)")

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            json.dump({"meta": trace["meta"], "results": results},
                      fh, ensure_ascii=False, indent=1)
        print(f"\nwrote {args.json_out}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)

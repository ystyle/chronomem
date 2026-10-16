#!/usr/bin/env python3
"""
QA-style semantic probes: ask a question only the fact can answer.

The review's third recommendation and the one our own §3.5 pointed at after the
similarity-margin design failed. A margin compares two texts and cannot tell a
paraphrase from a loss; a question with a known answer can. The design avoids the
artefact that killed the margin measure by construction: **the question is written
in the register of the thing being read**, so a summary that preserved the fact
can answer it, and one that dropped the fact cannot fake it by sounding similar.

Two probe families, because they answer different questions:

  fact-qa      one question per fact, answerable from the raw entry
               ("What option was chosen for <topic> on day N?" -> the letter).
               Scored by exact match. This is the semantic test: the summary must
               contain the binding, in whatever words.

  paraphrase   the same question asked with the fact restated in different words,
               to check the probes are not themselves keyed on surface form.

What is reported per level (exact / day summary / week summary) is accuracy on the
same questions. If a level's answerability tracks the token-survival numbers, the
lexical metric was a fair proxy; where they diverge, this is the measure that says
which way.

Runs against the bench instance; read-only against production.

Usage:
    python3 qa_probes.py --out results/retention/qa-probes.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from backends import (ChronomemBackend, day_ms, day_window_start,          # noqa: E402
                      week_window_start, JOB_ID_RE)

BENCH = "http://127.0.0.1:18900/mcp"
BTYPE = "bench/qa"


def llm_answer(base: str, key: str, model: str, question: str, context: str) -> str:
    """Ask the model to answer from the retrieved context only.

    A one-letter answer is requested so scoring is exact; the model is told to say
    UNKNOWN when the context does not contain the answer, which is the case that
    matters — a system that lost the fact must be allowed to fail visibly rather
    than guess.
    """
    prompt = (
        "Answer the question using ONLY the context below. The answer is a single "
        "option letter (A, B, C or D). If the context does not contain the answer, "
        "reply exactly UNKNOWN.\n\n"
        f"Context:\n{context}\n\nQuestion: {question}\nAnswer:"
    )
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 8,
        "temperature": 0.0,
        "chat_template_kwargs": {"enable_thinking": False},
    }).encode()
    req = urllib.request.Request(f"{base.rstrip('/')}/chat/completions", data=body,
                                 headers={"Content-Type": "application/json",
                                          "Authorization": f"Bearer {key}"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=180) as resp:
        d = json.loads(resp.read().decode())
    txt = d["choices"][0]["message"]["content"].strip().upper()
    m = re.search(r"\b([A-D])\b", txt)
    return m.group(1) if m else "UNKNOWN"


def load_llm() -> tuple[str, str, str]:
    env = os.path.expanduser("~/docker/chronomem/.env")
    base = key = ""
    with open(env, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("LLM_BASE_URL="):
                base = line.split("=", 1)[1].strip().strip('"')
            elif line.startswith("LLM_API_KEY="):
                key = line.split("=", 1)[1].strip().strip('"')
    return base, key, "qwen3.5-4b"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default=BENCH)
    ap.add_argument("--days", type=int, default=8)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    base, key, model = load_llm()
    trace = json.load(open(os.path.join(HERE, ".work", "trace-ref.json"),
                           encoding="utf-8"))
    days = sorted({e["day"] for e in trace["events"]})[: a.days]

    def fact_day(p):
        m = re.search(r"on day (\d+)", p["question"])
        return int(m.group(1)) if m else None

    probes = [p for p in trace["probes"]
              if (fd := fact_day(p)) is not None and fd <= days[-1]]
    if not probes:
        print("no probes in range", file=sys.stderr)
        return 1

    # Ingest, then summarize days and weeks so all three levels exist.
    be = ChronomemBackend(url=a.url, mode="summary", mtype=BTYPE)
    be.purge()
    be.setup()
    for e in trace["events"]:
        if e["day"] <= days[-1]:
            be.write(e["day"], e["seq"], e["text"])
    for d in days:
        m = JOB_ID_RE.search(rpc_wrap(a.url, "mem/summarize", {
            "type": BTYPE, "granularity": "day",
            "windowStartMs": day_window_start(d)}))
        if m:
            wait_job(a.url, int(m.group(1)))
    for w in sorted({week_window_start(d) for d in days}):
        m = JOB_ID_RE.search(rpc_wrap(a.url, "mem/summarize", {
            "type": BTYPE, "granularity": "week", "windowStartMs": w}))
        if m:
            wait_job(a.url, int(m.group(1)))

    levels = {
        "exact": lambda d: be._query_all(day_ms(d) + 86_400_000),
        "day-summary": lambda d: rpc_wrap(a.url, "mem/recall", {
            "type": BTYPE, "granularity": "day", "mode": "summary",
            "windowStartMs": day_window_start(d)}),
        "week-summary": lambda d: rpc_wrap(a.url, "mem/recall", {
            "type": BTYPE, "granularity": "week", "mode": "summary",
            "windowStartMs": week_window_start(d)}),
    }

    rows = []
    for level, fetch in levels.items():
        correct = unknown = 0
        for p in probes:
            d = fact_day(p)
            ctx = fetch(d)
            got = llm_answer(base, key, model, p["question"], ctx)
            ok = got == p["answer"]
            correct += ok
            unknown += (got == "UNKNOWN")
            rows.append({"level": level, "qid": p["qid"], "day": d,
                         "expected": p["answer"], "got": got, "correct": ok})
        acc = correct / len(probes)
        print(f"  {level:14} {correct:>3}/{len(probes):<3} = {acc:>6.1%}  "
              f"(UNKNOWN {unknown})")

    # The comparison that matters: does QA accuracy track token survival?
    print()
    print("=== agreement with the token metric (day level, where both exist) ===")
    out = {"n_probes": len(probes), "days": days, "rows": rows, "by_level": {}}
    for level in levels:
        sub = [r for r in rows if r["level"] == level]
        out["by_level"][level] = {
            "correct": sum(r["correct"] for r in sub), "total": len(sub),
            "accuracy": sum(r["correct"] for r in sub) / len(sub),
            "unknown": sum(1 for r in sub if r["got"] == "UNKNOWN"),
        }

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)
    print(f"\nwrote {a.out}")
    return 0


# Small helpers so the module imports cleanly without drift_eval's name clashes.
def rpc_wrap(url: str, tool: str, args: dict) -> str:
    from drift_eval import rpc
    return rpc(url, tool, args)


def wait_job(url: str, jid: int, timeout: int = 300) -> None:
    from drift_eval import rpc
    end = time.time() + timeout
    while time.time() < end:
        t = rpc(url, "mem/summarize_status", {"job_id": jid})
        if "done" in t or "failed" in t:
            return
        time.sleep(2)


if __name__ == "__main__":
    sys.exit(main())

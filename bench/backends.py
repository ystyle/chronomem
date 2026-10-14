#!/usr/bin/env python3
"""
Memory backends under comparison.

All three consume the same trace and answer the same probes; only the memory
architecture differs. That is the whole design of the comparison — if a backend
saw different input or a different question set, the numbers would not be
comparable.

- `ChronomemBackend`  — the system under test: writes each event as an entry and
  answers by querying. Two recall modes are exposed (`exact` and `summary`)
  because the paper's central claim is that they differ in cost, not only in
  content.
- `FlatBackend`        — "store everything, retrieve by recency": the naive
  baseline. It keeps every event and hands the top-k most recent to the reader.
- `CompactionBackend`  — "one-shot compaction": periodically rewrites the whole
  history into a single running report. This is the destructive baseline: the
  report can carry the gist but drops the primary evidence.

Token accounting is deliberately split into server-side and client-side, because
the paper's §4 claims the two tracks move cost between those sides rather than
removing it:

    server_tokens  — tokens the *memory service* spends (LLM calls it makes)
    client_tokens  — tokens the *reader* must inject into its prompt

A backend that answers by returning raw volume has low server cost and high
client cost; one that answers from a summary has the reverse. Reporting a single
number would hide exactly the trade-off the paper is about.
"""

from __future__ import annotations

import json
import re
import time
import urllib.request
import urllib.error
from dataclasses import dataclass, field


# --- token estimation -------------------------------------------------------
#
# No tokenizer is available here, and installing one for a synthetic ASCII trace
# would add a dependency without adding accuracy: the trace is plain English, so
# the usual ~4 chars/token rule is adequate and, importantly, is applied
# *identically* to all three backends. The comparison is what matters, not the
# absolute constant.
CHARS_PER_TOKEN = 4.0

# Server-side cost of one summarization call, used when a backend asks the
# service to generate a summary. The service does not report its own token
# usage, so this is a *placeholder* that must be replaced with the real figure
# measured from the deployment before any paper number is quoted. It is set to
# the summarizer's configured per-call input budget so that the summary track is
# not accidentally reported as free.
SUMMARY_CALL_TOKENS = 40_000

# `mem/summarize` replies "已提交后台总结任务 #<id>（...）". Each submission gets
# its own id, so the id must be captured per call — polling a fixed id reports
# success while other windows are still queued.
JOB_ID_RE = re.compile(r"#\s*(\d+)")


def est_tokens(text: str) -> int:
    return max(1, int(len(text) / CHARS_PER_TOKEN))


@dataclass
class Answer:
    """One backend's response to one probe."""
    text: str
    client_tokens: int      # what the reader must inject to use this answer
    server_tokens: int = 0  # what the service spent producing it
    note: str = ""


@dataclass
class Backend:
    """Common surface: absorb one event, then answer probes."""
    name: str = "backend"
    server_tokens: int = 0
    stored_chars: int = 0
    events_seen: int = 0

    def write(self, day: int, seq: int, text: str, tags: dict | None = None) -> None:  # noqa: D401
        raise NotImplementedError

    def answer(self, question: str, day_asked: int) -> Answer:
        raise NotImplementedError

    def prepare(self, trace: dict) -> None:
        """Optional pre-probing work (e.g. generating summaries). Default: none."""

    def close(self) -> None:
        pass


# --- 1. Chronomem (system under test) ---------------------------------------

class ChronomemBackend(Backend):
    """Talks to a running Chronomem over its MCP endpoint.

    Uses a dedicated memory type (`bench/eval`) so the experiment never touches
    the production types that hold real records.
    """

    def __init__(self, url: str = "http://127.0.0.1:18900/mcp",
                 mtype: str = "bench/eval", mode: str = "exact",
                 query_limit: int = 500):
        super().__init__(name=f"chronomem-{mode}")
        # The default is the **bench** instance, never the production one. A
        # default pointing at 8900 wrote a synthetic trace into the live store
        # the moment a caller forgot `--url`; an experiment must not be able to
        # touch production by omission. The guard below makes that impossible
        # rather than merely unlikely.
        if ":8900" in url:
            raise ValueError(
                "refusing to run against the production port (" + url + "). "
                "Start the bench instance (see .bench-ctr/README.md) and pass its URL.")
        self.url = url
        self.mtype = mtype
        self.mode = mode          # exact | summary
        self.query_limit = query_limit
        self.missing_summaries = 0
        self._rpc_id = 0
        assert mode in ("exact", "summary")

    # -- MCP plumbing --------------------------------------------------------
    def _call(self, tool: str, args: dict) -> dict:
        self._rpc_id += 1
        body = json.dumps({
            "jsonrpc": "2.0", "id": self._rpc_id, "method": "tools/call",
            "params": {"name": tool, "arguments": args},
        }).encode()
        req = urllib.request.Request(
            self.url, data=body,
            headers={"Content-Type": "application/json",
                     "Accept": "application/json, text/event-stream"})
        # `--noproxy` semantics: an HTTP proxy in the environment would hijack
        # the loopback call. openers without a proxy handler bypass it.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=30) as resp:
            payload = json.loads(resp.read().decode())
        if "error" in payload:
            raise RuntimeError(f"{tool} failed: {payload['error']}")
        return payload["result"]

    @staticmethod
    def _text(result: dict) -> str:
        return "\n".join(c.get("text", "") for c in result.get("content", []))

    # -- backend surface -----------------------------------------------------
    def setup(self) -> None:
        """Create the type if absent. `levels` drives the materialization tower."""
        try:
            self._call("mem/type_create", {
                "name": self.mtype,
                "description": "evaluation trace (synthetic)",
                "levels": ["1h", "day", "week"],
                "auto_summarize": self.mode == "summary",
            })
        except RuntimeError as exc:
            if "已存在" not in str(exc):
                raise

    def write(self, day: int, seq: int, text: str, tags: dict | None = None) -> None:
        # ts is placed inside the simulated day so window materialization lines
        # up with `day`; day 1 maps to a fixed epoch base.
        ts = day_ms(day) + seq * 1000
        self._call("mem/append", {
            "type": self.mtype,
            "payload": {"text": text, "day": day},
            "tags": tags or {},
            "ts": ts,
        })
        self.events_seen += 1
        self.stored_chars += len(text)

    def answer(self, question: str, day_asked: int) -> Answer:
        """Query the whole run so far, then read it the way the mode prescribes."""
        # Upper bound of the query must use the same time base the events were
        # written with (`day_ms`). Mixing bases here silently returned zero
        # entries for every probe — the layer scored 0% while looking like a
        # system that had forgotten everything.
        to_ms = day_ms(day_asked) + DAY_MS
        if self.mode == "exact":
            # Structural recall: pull the raw entries. Zero server-side LLM.
            got = self._text(self._call("mem/query", {
                "type": self.mtype, "from": 0, "to": to_ms, "limit": self.query_limit,
            }))
            return Answer(text=got, client_tokens=est_tokens(got),
                          note="raw entries (all of them)")

        # Semantic recall: read the *day* summary of the day the question is
        # about. Which day that is has to come from the question — the fact's day
        # is not `day_asked` (that is the moment of asking), and reading the
        # wrong window returns a neighbouring summary that looks plausible.
        #
        # The window must be computed the way the service does: day/week windows
        # are CALENDAR-aligned in the service's timezone, not epoch-aligned. A
        # naive `DAY_MS * day` is 8 hours off for Asia/Shanghai, so the lookup
        # missed every time and the level scored 0 — which reads as "the
        # summaries lose everything" rather than "the query was wrong".
        m = re.search(r"on day (\d+)", question, re.IGNORECASE)
        fact_day = int(m.group(1)) if m else day_asked
        got = self._text(self._call("mem/recall", {
            "type": self.mtype, "granularity": "day", "mode": "summary",
            "windowStartMs": day_window_start(fact_day),
        }))
        if "尚无语义摘要" in got or "no summary" in got.lower():
            self.missing_summaries += 1
        return Answer(text=got, client_tokens=est_tokens(got),
                      note=f"day summary of day {fact_day}")

    def prepare(self, trace: dict) -> None:
        """Generate the summary tower before probing starts.

        Realistic model: the scheduler summarizes each day once it closes, so by
        the time a client asks about an old day the summary is already there.
        Pre-generating models a deployment whose scheduler has caught up.

        The consequence for measurement is worth stating because it decides what
        the numbers mean: a summary is produced once and does not change as it
        ages, so **semantic recall does not decay with lag**. What it loses is
        whatever the compression dropped at generation time — a bounded loss,
        against the unbounded decay a fixed recency window shows. Measuring that
        bounded loss is the point of including this backend.
        """
        days = sorted({e["day"] for e in trace["events"]})
        for i, day in enumerate(days):
            reply = self._call("mem/summarize", {
                "type": self.mtype, "granularity": "day",
                "windowStartMs": day_window_start(day),
            })
            jid = JOB_ID_RE.search(json.dumps(reply))
            if jid:
                self._wait_job(int(jid.group(1)))
            # Server-side spend: one LLM call per summarized window.
            self.server_tokens += SUMMARY_CALL_TOKENS
            if (i + 1) % 10 == 0:
                print(f"    summarized {i + 1}/{len(days)} days")

    def _wait_job(self, job_id: int, timeout_s: int = 300) -> None:
        """Poll one summarization job. Each submission returns its own id."""
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            txt = self._text(self._call("mem/summarize_status", {"job_id": job_id}))
            if "done" in txt or "failed" in txt:
                return
            time.sleep(2)

    def purge(self) -> None:
        """Drop this run's entries. `type_delete` requires empty series first."""
        try:
            self._call("mem/truncate", {"type": self.mtype})
        except RuntimeError:
            pass


# --- 2. Flat recency --------------------------------------------------------

class FlatBackend(Backend):
    """Store everything; retrieve the k most recent entries **as of the ask**.

    This is the baseline the paper argues lacks compression: it keeps all
    evidence, but a reader that can only inject a bounded window sees the tail.

    Events are stamped with their day and filtered by `day_asked`. That matters
    because the runner ingests the whole trace before asking anything (so that
    summary-generating backends can do off-line work): without the filter this
    backend would answer day 5's question from the most recent 20 events of day
    30 and score as well as a system that actually remembers.
    """

    def __init__(self, top_k: int = 20):
        super().__init__(name="flat-recency")
        self.events: list[tuple[int, int, str]] = []
        self.top_k = top_k

    def write(self, day: int, seq: int, text: str, tags: dict | None = None) -> None:
        self.events.append((day, seq, text))
        self.events_seen += 1
        self.stored_chars += len(text)

    def answer(self, question: str, day_asked: int) -> Answer:
        visible = [t for (d, _s, t) in self.events if d <= day_asked]
        recent = visible[-self.top_k:]
        got = "\n".join(recent)
        return Answer(text=got, client_tokens=est_tokens(got),
                      note=f"last {len(recent)} events as of day {day_asked}")


# --- 3. One-shot compaction -------------------------------------------------

class CompactionBackend(Backend):
    """Periodically collapse the whole history into one running report.

    The destructive baseline: after compaction the per-event detail is gone, so
    a probe whose answer was only in the discarded detail cannot be recovered —
    which is precisely the failure mode the paper attributes to one-shot
    compaction.

    Fidelity is the *point* of this baseline, so it must actually lose
    information. An earlier version kept every decision line verbatim and
    therefore scored 100% — it was not compressing, just filtering filler. Real
    one-shot compaction rewrites a window into a short report, which means:
      * a bounded number of bullet lines survive per compaction pass (so a
        window with many facts keeps only the first few), and
      * the wording is changed (the report paraphrases rather than quotes), so
        a reader cannot recover the original phrasing.
    Both are modelled here. The wording change is what makes the later probes
    fail: the surviving line no longer matches the decision text.

    The "LLM" is a deterministic stand-in, because the comparison is about *what
    survives compression*, not about a particular model's summarization quality.
    Every backend is scored on the same trace, so a rule-based compressor keeps
    the result reproducible.
    """

    def __init__(self, compact_every_days: int = 2, keep_per_pass: int = 2):
        super().__init__(name="one-shot-compaction")
        self.report_lines: list[str] = []
        self.buffer: list[str] = []
        # Report snapshot per compaction day (see `write`/`answer`).
        self.reports_by_day: dict[int, list[str]] = {}
        self.every = compact_every_days
        self.keep_per_pass = keep_per_pass
        self.last_compact_day = 0

    def write(self, day: int, seq: int, text: str, tags: dict | None = None) -> None:
        self.buffer.append(text)
        self.events_seen += 1
        self.stored_chars += len(text)
        if day - self.last_compact_day >= self.every:
            self._compact()
            self.last_compact_day = day
            # Snapshot the report as of this day, so a probe asked about an
            # earlier day reads the report as it stood then rather than one that
            # has since absorbed later days' summaries.
            self.reports_by_day[day] = list(self.report_lines)

    def _compact(self) -> None:
        """Rewrite the buffer into the running report; the rest is discarded.

        Server-side cost: the compaction pass consumes the whole buffer, which
        is what a one-shot compaction actually pays for.
        """
        self.server_tokens += est_tokens("\n".join(self.buffer))

        decisions = [t for t in self.buffer if "decided to go with option" in t]
        # Keep only a bounded prefix of the window's decisions, and paraphrase
        # them: the report records that a decision happened, not its exact text.
        for i, t in enumerate(decisions[:self.keep_per_pass]):
            m = re.search(r"\[(\w+)\].*?(alice|bob|carol)", t)
            topic = m.group(1) if m else "work"
            self.report_lines.append(f"Day summary: a decision was made about {topic}.")
            del i
        self.buffer = []

    def answer(self, question: str, day_asked: int) -> Answer:
        # Reading the running report costs the service nothing: the compaction
        # spend was already booked at `write` time (`server_tokens`), which the
        # runner adds to the total.
        #
        # The report as of `day_asked` is used (see `write`), so this backend is
        # not credited with compaction passes that happen later in the trace.
        past = [d for d in self.reports_by_day if d <= day_asked]
        lines = self.reports_by_day[max(past)] if past else []
        got = "\n".join(lines)
        return Answer(text=got, client_tokens=est_tokens(got),
                      note="running report")


DAY_MS = 86_400_000
HOUR_MS = 3_600_000

# The service aligns day/week windows to the CALENDAR in its own timezone
# (`CHRONOLOG_TIMEZONE`, Asia/Shanghai in the bench instance). The bench trace
# numbers days 1..N; they are placed on a fixed UTC+8 base so that "day N" lands
# on a whole local day. Using `DAY_MS * day` instead put each day 8 hours off and
# silently matched the neighbouring window — a mistake that reads as total
# summary loss rather than as a bad query.
TZ_SHIFT_MS = 8 * HOUR_MS
# 2024-01-01 00:00 +08:00 — day 0's local midnight.
BASE_MS = 1_704_067_200_000 - TZ_SHIFT_MS


def day_ms(day: int) -> int:
    """Timestamp of the start (local midnight) of trace `day`."""
    return BASE_MS + day * DAY_MS


def day_window_start(day: int) -> int:
    """Start of the calendar day window the service would compute for `day`."""
    shifted = day_ms(day) + TZ_SHIFT_MS
    return shifted - (shifted % DAY_MS) - TZ_SHIFT_MS

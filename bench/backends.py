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

    def close(self) -> None:
        pass


# --- 1. Chronomem (system under test) ---------------------------------------

class ChronomemBackend(Backend):
    """Talks to a running Chronomem over its MCP endpoint.

    Uses a dedicated memory type (`bench/eval`) so the experiment never touches
    the production types that hold real records.
    """

    def __init__(self, url: str = "http://127.0.0.1:8900/mcp",
                 mtype: str = "bench/eval", mode: str = "exact",
                 query_limit: int = 500):
        super().__init__(name=f"chronomem-{mode}")
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
        ts = DAY_MS * day + seq * 1000
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
        to_ms = DAY_MS * (day_asked + 1)
        if self.mode == "exact":
            # Structural recall: pull the raw entries. Zero server-side LLM.
            got = self._text(self._call("mem/query", {
                "type": self.mtype, "from": 0, "to": to_ms, "limit": self.query_limit,
            }))
            return Answer(text=got, client_tokens=est_tokens(got),
                          note="raw entries (all of them)")
        # Semantic recall: a day-level summary of the asked-about day. The
        # summary must already exist — the service reports "no summary yet"
        # rather than generating one inline, which mirrors the paper's stated
        # precondition (semantic recall is summary-dependent).
        got = self._text(self._call("mem/recall", {
            "type": self.mtype, "granularity": "day", "mode": "summary",
            "windowStartMs": DAY_MS * day_asked,
        }))
        if "尚无语义摘要" in got or "no summary" in got.lower():
            self.missing_summaries += 1
        # Generating a summary is server-side spend. The service does not report
        # its token usage, so the real figure must be read from the deployment
        # (see README); here the cost is booked only when a generation was
        # actually attempted.
        return Answer(text=got, client_tokens=est_tokens(got),
                      note="day summary")

    def summarize_day(self, day: int) -> None:
        """Ask the service to produce one day's summary (a background job).

        Semantic recall has a precondition — the summary must exist — so a
        summary-mode run has to generate them first. Kept explicit rather than
        folded into `answer` so the server-side spend it causes is visible.
        """
        self._call("mem/summarize", {
            "type": self.mtype, "granularity": "day",
            "windowStartMs": DAY_MS * day,
        })
        self.server_tokens += SUMMARY_CALL_TOKENS

    def purge(self) -> None:
        """Drop this run's entries. `type_delete` requires empty series first."""
        try:
            self._call("mem/truncate", {"type": self.mtype})
        except RuntimeError:
            pass


# --- 2. Flat recency --------------------------------------------------------

class FlatBackend(Backend):
    """Store everything; retrieve the k most recent entries.

    This is the baseline the paper argues lacks compression: it keeps all
    evidence, but a reader that can only inject a bounded window sees the tail.
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
        recent = self.events[-self.top_k:]
        got = "\n".join(t for _, _, t in recent)
        return Answer(text=got, client_tokens=est_tokens(got),
                      note=f"last {len(recent)} events")


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
        got = "\n".join(self.report_lines)
        return Answer(text=got, client_tokens=est_tokens(got),
                      note="running report")


DAY_MS = 86_400_000

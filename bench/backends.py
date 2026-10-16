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
        self.mode = mode          # exact | summary | summary-week
        # Which summary level this backend reads. `summary` keeps its original
        # meaning (day level) so existing results stay comparable; `summary-week`
        # is what the layered claim actually needs: the coarse arm, answering the
        # same question from a compressed week rather than from the day it came
        # from. Without it the "layered" comparison only ever exercised one layer.
        self.level = "week" if mode == "summary-week" else "day"
        self.query_limit = query_limit
        self.missing_summaries = 0
        self._rpc_id = 0
        assert mode in ("exact", "summary", "summary-week")

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
                # `day` must be the finest level. With `1h` listed first, a
                # `granularity="day"` summarization comes back with a ONE-HOUR
                # window (measured: 1704124800000~1704128399999), because the
                # bottom-up path takes its window from the finest level. The
                # record lands, `mem/summaries` lists it, and every
                # `recall(granularity="day")` misses — so the summary arm scored
                # 0% while looking like a system that had forgotten everything.
                # The production `worklog` type is also [day, week].
                "levels": ["day", "week"],
                # Auto-summarization is off for every arm: the harness generates
                # exactly the levels it needs in `prepare`, so a background
                # scheduler would add LLM calls that differ per run and make the
                # comparison irreproducible.
                "auto_summarize": False,
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

    def _query_all(self, to_ms: int, page_size: int = 200) -> str:
        """Page through `mem/query` until every entry up to `to_ms` is read.

        The service pages by number and says so in the reply header; a single
        call returns at most `limit` entries and says nothing about what it left
        out, so reading only the first page is a silent truncation. On a
        300-event trace that never bites; on a longer one it removes exactly the
        oldest entries, i.e. the evidence behind the largest-lag probes — the
        ones the study exists to measure.
        """
        chunks: list[str] = []
        page = 1
        while True:
            txt = self._text(self._call("mem/query", {
                "type": self.mtype, "from": 0, "to": to_ms,
                "limit": page_size, "page": page,
            }))
            # The first line of every page is the header ("共 N 条 · 第 p/q 页
            # …"); keep it once, drop it from later pages so the result reads as
            # one continuous listing.
            if page == 1:
                chunks.append(txt)
            elif "\n" in txt:
                chunks.append(txt.split("\n", 1)[1])
            if "下一页请带" not in txt:
                break
            page += 1
            if page > 500:                      # defensive; ~100k entries
                raise RuntimeError("pagination did not terminate")
        return "\n".join(chunks)

    def answer(self, question: str, day_asked: int) -> Answer:
        """Query the whole run so far, then read it the way the mode prescribes."""
        # Upper bound of the query must use the same time base the events were
        # written with (`day_ms`). Mixing bases here silently returned zero
        # entries for every probe — the layer scored 0% while looking like a
        # system that had forgotten everything.
        to_ms = day_ms(day_asked) + DAY_MS
        if self.mode == "exact":
            # Structural recall: pull the raw entries. Zero server-side LLM.
            #
            # Paged, because a single query is capped and the cap is silent. A
            # one-shot `limit=500` looks fine on a 300-event trace and becomes a
            # truncation on a longer one — and the probes that lose their
            # evidence are the ones with the largest lag, i.e. exactly the ones
            # the study exists to measure. The symptom is a `None` extraction
            # recorded as "the system forgot", when the reader simply never read
            # the line.
            got = self._query_all(to_ms)
            return Answer(text=got, client_tokens=est_tokens(got),
                          note="raw entries (all of them)")

        # Semantic recall: read the summary of the *level* this backend models,
        # for the window containing the day the question is about. Which day that
        # is has to come from the question — the fact's day is not `day_asked`
        # (that is the moment of asking), and reading the wrong window returns a
        # neighbouring summary that looks plausible.
        #
        # The window must be computed the way the service does: day/week windows
        # are CALENDAR-aligned in the service's timezone, not epoch-aligned. A
        # naive `DAY_MS * day` is 8 hours off for Asia/Shanghai, so the lookup
        # missed every time and the level scored 0 — which reads as "the
        # summaries lose everything" rather than "the query was wrong".
        m = re.search(r"on day (\d+)", question, re.IGNORECASE)
        fact_day = int(m.group(1)) if m else day_asked
        if self.level == "week":
            anchor = week_window_start(fact_day)
            note = f"week summary containing day {fact_day}"
        else:
            anchor = day_window_start(fact_day)
            note = f"day summary of day {fact_day}"
        got = self._text(self._call("mem/recall", {
            "type": self.mtype, "granularity": self.level, "mode": "summary",
            "windowStartMs": anchor,
        }))
        if "尚无语义摘要" in got or "no summary" in got.lower():
            self.missing_summaries += 1
        return Answer(text=got, client_tokens=est_tokens(got), note=note)

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

        Level order matters. The service builds a coarse summary from its finer
        children by default, so the day level must exist before the week level is
        requested; asking for a week first would make the service summarize the
        week's days on demand, which is the same work in a different order but
        makes the timing much harder to reason about.
        """
        days = sorted({e["day"] for e in trace["events"]})

        def summarize(granularity: str, anchor: int) -> None:
            reply = self._call("mem/summarize", {
                "type": self.mtype, "granularity": granularity,
                "windowStartMs": anchor,
            })
            jid = JOB_ID_RE.search(json.dumps(reply))
            if jid:
                self._wait_job(int(jid.group(1)))
            # Server-side spend: one LLM call per summarized window.
            self.server_tokens += SUMMARY_CALL_TOKENS

        levels = ["day"] if self.level == "day" else ["day", "week"]
        for level in levels:
            if level == "day":
                for i, day in enumerate(days):
                    summarize("day", day_window_start(day))
                    if (i + 1) % 10 == 0:
                        print(f"    summarized {i + 1}/{len(days)} days")
            else:
                # One call per distinct week, not per day: repeating the same
                # week anchor would hit the service's idempotence and cost a
                # round trip each time.
                anchors = sorted({week_window_start(d) for d in days})
                for i, a in enumerate(anchors):
                    summarize("week", a)
                print(f"    summarized {len(anchors)} weeks")

        # Verify the tower is actually readable before anyone scores against it.
        # A level whose records land under a different window scores 0% and reads
        # as total loss; this turns that into a loud failure in seconds. Measured
        # cause once: a type whose `levels` started at 1h stored day summaries
        # under ONE-HOUR windows, so every day-level lookup missed.
        self._assert_readable(days)

    def _assert_readable(self, days: list[int]) -> None:
        sample = [days[0], days[len(days) // 2], days[-1]]
        ok = 0
        for d in sample:
            anchor = (week_window_start(d) if self.level == "week"
                      else day_window_start(d))
            txt = self._text(self._call("mem/recall", {
                "type": self.mtype, "granularity": self.level,
                "mode": "summary", "windowStartMs": anchor,
            }))
            if "尚无语义摘要" not in txt:
                ok += 1
        if ok == 0:
            raise RuntimeError(
                f"{self.name}: no {self.level}-level summary readable for days "
                f"{sample}. Refusing to score this arm as 0% — check the type's "
                f"`levels` (the finest level sets the window a summary is stored "
                f"under) and that prepare() produced records.")

    def _wait_job(self, job_id: int, timeout_s: int = 300) -> None:
        """Poll one summarization job. Each submission returns its own id."""
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            txt = self._text(self._call("mem/summarize_status", {"job_id": job_id}))
            if "done" in txt or "failed" in txt:
                return
            time.sleep(2)

    def purge(self) -> None:
        """Empty this run's series before ingesting.

        Only "the type does not exist yet" is tolerated — that is a legitimate
        first run. Everything else propagates. Swallowing every error here is
        how a broken clean-up turns into a silent zero: the old series survives,
        the new trace's timestamps are earlier than the leftovers, appends are
        rejected as out-of-order, and the run reports 0% while looking like a
        system that forgot everything. A wrong argument name produces exactly
        that shape (the tool errors, nothing is truncated, and the caller never
        hears about it).
        """
        try:
            self._call("mem/truncate", {"type": self.mtype})
        except RuntimeError as exc:
            if "不存在" not in str(exc) and "not exist" not in str(exc).lower():
                raise


# --- 1b. Chronomem with conservative (lossless-key) compaction --------------

class ConservativeCompactionBackend(Backend):
    """One-shot compaction that *keeps* the item-to-value pairing.

    Added to answer the strongest objection to the destructive baseline: its zero
    scores might be an artefact of our implementing it to paraphrase decision
    lines away, in which case they say nothing about compaction in general.

    So this variant compacts on the same schedule but preserves, for every fact,
    both its reference token and its option letter — i.e. it drops context,
    timestamps and prose while keeping exactly the pair a probe asks about. It is
    the most compaction-friendly baseline the evaluation can construct: if a
    system that keeps every question's answer still fails, the failure cannot be
    blamed on an unkind compressor.

    The comparison it enables is therefore:
      destructive compaction (paraphrases values away)  → 0%
      conservative compaction (keeps value pairs)       → ?
    and the gap between them is precisely how much of the destructive baseline's
    failure is attributable to the compressor's choices rather than to
    compaction as a strategy.
    """

    def __init__(self, compact_every_days: int = 2):
        super().__init__(name="conservative-compaction")
        self.pairs: list[str] = []          # "ref ZQ01 -> A" style lines
        self.buffer: list[str] = []
        self.every = compact_every_days
        self.last_compact_day = 0
        self.reports_by_day: dict[int, list[str]] = {}

    def write(self, day: int, seq: int, text: str, tags: dict | None = None) -> None:
        self.buffer.append(text)
        self.events_seen += 1
        self.stored_chars += len(text)
        if day - self.last_compact_day >= self.every:
            self._compact()
            self.last_compact_day = day
            self.reports_by_day[day] = list(self.pairs)

    # A fact-bearing line looks like "[vun] (ref ZR01) bob decided to go with
    # option A ..." or "(ref ZR01) Applied option A in the vun module (...)".
    REF_RE = re.compile(r"ref\s+(Z[A-Z]\d{2})", re.IGNORECASE)
    OPT_RE = re.compile(r"option\s+([A-D])", re.IGNORECASE)
    # When the input carries no reference token the pair has to be keyed by
    # (topic, value) instead, which is the same preservation policy expressed in
    # the vocabulary the text actually offers. Without this the backend stores
    # nothing at all and returns empty answers — a 0% that says "this arm cannot
    # read token-free text", not "conservative compaction fails without tokens".
    # Measured: exactly that, 100% -> 0%, before the fallback was added.
    TOPIC_RE = re.compile(r"\[([a-z]+)\]")
    DAY_RE = re.compile(r"day\s+(\d+)")

    def _compact(self) -> None:
        """Rewrite the buffer keeping only (token, value) pairs."""
        self.server_tokens += est_tokens("\n".join(self.buffer))
        for t in self.buffer:
            mref = self.REF_RE.search(t)
            mtop = self.TOPIC_RE.search(t)
            mopt = self.OPT_RE.search(t)
            if not mref and mtop and mopt:
                # Key on (topic, day), not topic alone. A topic recurs on several
                # days with different answers, so a topic-only key collides: with
                # 5 topics over 30 days the store held 15 pairs and answered the
                # wrong day's option. That is a defect in this transcription, not
                # a property of token-free text — the same policy has to keep the
                # same discriminator the reader will use.
                mday = self.DAY_RE.search(t)
                if mday:
                    line = (f"{mtop.group(1)} on day {mday.group(1)} chose "
                            f"option {mopt.group(1).upper()}")
                    if line not in self.pairs:
                        self.pairs.append(line)
                continue
            if mref and mopt:
                # Natural-language phrasing, matching the other arms, so the same
                # extractor reads every backend. An earlier version wrote these as
                # "ZR01=A", which the reader cannot parse — the arm then scored 0%
                # and looked like a compaction failure when it was a format the
                # measurement could not read.
                line = (f"ref {mref.group(1).upper()} chose "
                        f"option {mopt.group(1).upper()}")
                if line not in self.pairs:
                    self.pairs.append(line)
        self.buffer = []

    def answer(self, question: str, day_asked: int) -> Answer:
        past = [d for d in self.reports_by_day if d <= day_asked]
        lines = self.reports_by_day[max(past)] if past else []
        got = "\n".join(lines)
        return Answer(text=got, client_tokens=est_tokens(got),
                      note="conservative running report")


# --- 1c. Structured key-value memory -----------------------------------------

class KeyValueBackend(Backend):
    """Extract (key, value) pairs into head memory; never compress text.

    The review's first recommendation, and the cheapest way to answer its first
    objection: our comparison omitted any system whose structural bet is explicit
    relation preservation (MAGMA, LiCoMemory). This is the minimal form of that
    bet — parse each fact line into (topic, day) -> value and answer lookups from
    the index — with no summarisation and no lossy step at all.

    It differs from `ConservativeCompactionBackend` in what it is *for*. That arm
    compacts on a schedule and keeps the pairing as a policy choice, so it tests
    "what if a compactor preserves relations". This one never discards anything
    and holds an explicit index, so it tests the ceiling: **if a system that
    literally stores every item-to-value pair cannot answer, the probes are
    measuring something other than relation preservation.**

    It is also the baseline against which a mitigation (§ mitigation experiment)
    can be judged: a structured micro-summary that appends a KEY:VALUE block is,
    in effect, an attempt to recover this arm's behaviour inside a summary.
    """

    TOPIC_RE = re.compile(r"\[([a-z]+)\]")
    DAY_RE = re.compile(r"day\s+(\d+)")
    OPT_RE = re.compile(r"option\s+([A-D])", re.IGNORECASE)
    REF_RE = re.compile(r"ref\s+(Z[A-Z]\d{2})", re.IGNORECASE)

    def __init__(self):
        super().__init__(name="key-value-memory")
        # Two views of the same fact, exactly as the review described the
        # structure-preserving designs: (topic, day) -> value (the entity view)
        # and ref-token -> value (the anchor view). A trace carries either the
        # token or the topic, never both, so indexing one only would make this
        # arm unable to answer half our probes and look like a failure of
        # relation preservation when it is a failure to index.
        self.by_topic: dict[tuple[str, int], str] = {}
        self.by_ref: dict[str, str] = {}
        self.indexed_lines = 0

    def write(self, day: int, seq: int, text: str, tags: dict | None = None) -> None:
        self.events_seen += 1
        self.stored_chars += len(text)
        mopt = self.OPT_RE.search(text)
        if not mopt:
            return
        val = mopt.group(1).upper()
        mday = self.DAY_RE.search(text)
        mtop = self.TOPIC_RE.search(text)
        mref = self.REF_RE.search(text)
        if mtop and mday:
            self.by_topic[(mtop.group(1).lower(), int(mday.group(1)))] = val
        if mref:
            self.by_ref[mref.group(1).upper()] = val
        self.indexed_lines += 1

    def answer(self, question: str, day_asked: int) -> Answer:
        """Parse the probe into (topic, day) and look it up."""
        m_plain = re.search(r"for ([a-z]+) on day (\d+)", question, re.IGNORECASE)
        m_ref = re.search(r"for ref (Z[A-Z]\d{2}) on day (\d+)", question, re.IGNORECASE)
        if m_plain:
            key = (m_plain.group(1).lower(), int(m_plain.group(2)))
            val = self.by_topic.get(key)
            got = (f"{key[0]} on day {key[1]} chose option {val}"
                   if val else f"{key[0]} on day {key[1]}: not indexed")
        elif m_ref:
            key_ref = m_ref.group(1).upper()
            day = int(m_ref.group(2))
            val = self.by_ref.get(key_ref)
            got = (f"ref {key_ref} on day {day} chose option {val}"
                   if val else f"ref {key_ref}: not indexed")
        else:
            got = "(unparseable probe)"
        return Answer(text=got, client_tokens=est_tokens(got),
                      note="kv lookup")


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


def week_window_start(day: int) -> int:
    """Start of the Monday-anchored week window containing trace `day`.

    Mirrors the service's ISO week alignment (Monday 00:00 local). The weekday
    has to be derived from the epoch rather than shifted by a constant: adding a
    fixed offset is only correct when the day happens to be a Thursday, and the
    error is silent — summary lookup is an equality match on the window pair, so
    being a few days off does not return a near match, it returns nothing.
    """
    shifted = day_ms(day) + TZ_SHIFT_MS
    day_start = shifted - (shifted % DAY_MS)
    days_since_epoch = day_start // DAY_MS
    dow_from_monday = (days_since_epoch + 3) % 7      # 1970-01-01 was a Thursday
    return (day_start - dow_from_monday * DAY_MS) - TZ_SHIFT_MS

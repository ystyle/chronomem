#!/usr/bin/env python3
"""
Runner and scorer: drive one trace through every backend and report
accuracy vs. token cost.

Why a separate scorer rather than inlining: the score must be computed the same
way for every backend, and the *baselines* must be reported alongside it. A
majority-class baseline and a "return everything" baseline are cheap to compute
and immediately show whether a difference is real — without them, "Chronomem
scores 0.7" says nothing.

Scoring is exact-match on a single-token answer (CHOICES are A/B/C). The reader
is a deterministic extractor: given the text a backend returns, it must name the
option for the asked-about topic+day. This deliberately models a *bounded*
reader — one that cannot re-read an unbounded history — which is the regime the
paper is about.

Usage:
    python3 run_eval.py --trace .work/trace.json --backend flat
    python3 run_eval.py --trace .work/trace.json --backend all
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field

from backends import (Backend, ChronomemBackend, FlatBackend,
                      CompactionBackend, DAY_MS, est_tokens)

# Which option did the backend leave visible for (topic, day)?
#
# Two surfaces have to be read here, and they do not look alike:
#   * raw entries (exact mode, and the flat/compaction baselines) — English,
#     `[vun] alice decided to go with option B ... day 3` / `Applied option B in
#     the vun module (...) day 3`;
#   * a generated summary — the summarizer answers in Chinese, e.g.
#     `vun 模块：选择方案 B` or `在 vun 模块中应用选项 C`.
# Matching only the English form scored every summary-backed run at 0, which
# looks exactly like "the summary lost the information" but was the reader
# failing to parse a language it was never taught.
DECISION_RE = re.compile(
    r"\[(?P<topic>[a-z]+)\].*?option (?P<choice>[A-D]).*?day\s*(?P<day>\d+)",
    re.IGNORECASE)
EDIT_RE = re.compile(
    r"option (?P<choice>[A-D]) in the (?P<topic>[a-z]+) module.*?day\s*(?P<day>\d+)",
    re.IGNORECASE)
# Chinese renderings of the option.
ZH_OPTION_RE = re.compile(r"(?:选项|方案|选择了?|采用)\s*([A-D])")
DAY_RE = re.compile(r"(?:day\s*(\d+)|第\s*(\d+)\s*[天日])", re.IGNORECASE)

# Topic vocabulary, used only to judge how many topics a sentence mentions.
# Imported lazily (inside the function) to avoid a circular import: gen_trace
# imports nothing from here, but keeping the reader decoupled means the trace
# layout can change without touching the scorer. The assertion guards against
# the two drifting apart.
ALL_TOPICS: list[str] = []


def _load_topics() -> list[str]:
    global ALL_TOPICS
    if not ALL_TOPICS:
        from gen_trace import TOPICS
        ALL_TOPICS = list(TOPICS)
    return ALL_TOPICS


def _option_in(segment: str) -> str | None:
    """The option letter stated in one segment, or None.

    Both languages are accepted: raw entries are English, a generated summary
    answers in Chinese ("选择方案 B"). Teaching the reader only one of them made
    every summary-backed run score 0, which looks like total information loss
    but was the reader failing on a language it did not know.
    """
    for rx in (DECISION_RE, EDIT_RE):
        mm = rx.search(segment)
        if mm:
            return mm.group("choice").upper()
    mm = ZH_OPTION_RE.search(segment)
    if mm:
        return mm.group(1).upper()
    return None


def _day_in(segment: str) -> int | None:
    m = DAY_RE.search(segment)
    if not m:
        return None
    return int(m.group(1) or m.group(2))


def extract_answer(text: str, question: str) -> str | None:
    """Deterministic reader: recover the option for the fact the question is about.

    The reader sees only `text`, and must fail when the fact is absent — that is
    the point: a store that dropped the detail cannot be rescued by a clever
    reader. `None` is the drift signal and must never be softened into a guess,
    since returning some other fact's option would credit a backend for
    information it no longer carries.

    Primary key is the **reference token** (`ref ZR01`) that the trace embeds in
    every fact-bearing event. It is the only reliable key, because a summary is
    prose: it routinely names several topics and several options in one sentence
    ("keb and vun were applied options A and C"), so any reader keyed on
    (topic, day) picks the wrong letter in exactly that sentence — which is what
    produced most of the summary-backed misses in earlier runs.

    Falls back to (topic, day) only for material that has no reference token
    (a trace generated before the token existed, or a backend that paraphrased it
    away); then topic-only matching is allowed only when the text cannot span
    several days, since a topic recurs across days with different options.
    """
    # --- primary: reference token -------------------------------------------
    mref = re.search(r"ref\s+(Z[A-Z]\d{2})", question, re.IGNORECASE)
    want_ref = mref.group(1).upper() if mref else None
    if want_ref:
        segments = [s for s in re.split(r"[\n\r;；]|(?<=[。！？])", text) if s.strip()]
        # A summary may restate the fact on several lines; take the first line
        # that carries both the token and an option.
        for seg in segments:
            if re.search(r"(?<![A-Z0-9])" + re.escape(want_ref) + r"(?![A-Z0-9])",
                         seg, re.IGNORECASE):
                opt = _option_in(seg)
                if opt:
                    return opt
        # Token present but no option on its line (e.g. it appears only in a
        # keyword list) — fall through to the topic-based path.
        if not re.search(r"(?<![A-Z0-9])" + re.escape(want_ref) + r"(?![A-Z0-9])",
                         text, re.IGNORECASE):
            return None

    # --- fallback: (topic, day), then topic alone ----------------------------
    m = re.search(r"for ([a-z]+) on day (\d+)", question, re.IGNORECASE)
    if not m:
        m = re.search(r"for ref \S+ on day (\d+)", question, re.IGNORECASE)
        if not m:
            return None
        want_topic, want_day = None, int(m.group(1))
    else:
        want_topic, want_day = m.group(1).lower(), int(m.group(2))

    segments = [s for s in re.split(r"[\n\r;；]|(?<=[。！？])", text) if s.strip()]
    days_mentioned = {int(a or b) for a, b in DAY_RE.findall(text)}
    strict = len(days_mentioned) > 1

    def names_topic(seg: str) -> bool:
        if want_topic is None:
            return True
        return re.search(r"(?<![a-z])" + re.escape(want_topic) + r"(?![a-z])",
                         seg, re.IGNORECASE) is not None

    def topic_count(seg: str) -> int:
        return sum(1 for t in _load_topics()
                   if re.search(r"(?<![a-z])" + re.escape(t) + r"(?![a-z])",
                                seg, re.IGNORECASE))

    def candidates(require_day: bool):
        out = []
        for idx, seg in enumerate(segments):
            if not names_topic(seg):
                continue
            d = _day_in(seg)
            if require_day and d != want_day:
                continue
            if not require_day and d is not None and d != want_day:
                continue
            out.append((topic_count(seg), idx, seg))
        out.sort(key=lambda x: (x[0], x[1]))       # fewest topics, then earliest
        return [s for _c, _i, s in out]

    for seg in candidates(require_day=True):
        opt = _option_in(seg)
        if opt:
            return opt
    if not strict:
        for seg in candidates(require_day=False):
            opt = _option_in(seg)
            if opt:
                return opt
    return None

@dataclass
class ProbeResult:
    qid: str
    expected: str
    got: str | None
    correct: bool
    client_tokens: int


@dataclass
class BackendResult:
    name: str
    correct: int = 0
    total: int = 0
    client_tokens: int = 0
    server_tokens: int = 0
    stored_chars: int = 0
    events_seen: int = 0
    per_probe: list = field(default_factory=list)

    @property
    def accuracy(self) -> float:
        return self.correct / self.total if self.total else 0.0

    # Cumulative tokens grow with the number of probes, so a single "cost"
    # number is ambiguous: a backend asked 50 questions looks 5x more expensive
    # than the same backend asked 10. Both views are reported — per-question is
    # the architecture-comparable figure, cumulative is the deployment figure.
    @property
    def client_tokens_per_probe(self) -> float:
        return self.client_tokens / self.total if self.total else 0.0

    @property
    def server_tokens_per_probe(self) -> float:
        return self.server_tokens / self.total if self.total else 0.0

    @property
    def total_tokens(self) -> int:
        return self.client_tokens + self.server_tokens


def run_backend(backend: Backend, trace: dict, purge_first: bool = False,
                prepare=None) -> BackendResult:
    if purge_first and isinstance(backend, ChronomemBackend):
        backend.purge()
        backend.setup()

    res = BackendResult(name=backend.name)

    events_by_day: dict[int, list] = {}
    for e in trace["events"]:
        events_by_day.setdefault(e["day"], []).append(e)
    probes_by_day: dict[int, list] = {}
    for p in trace["probes"]:
        probes_by_day.setdefault(p["day_asked"], []).append(p)

    days = sorted(set(events_by_day) | set(probes_by_day))

    # Phase 1 — ingest the whole trace.
    #
    # All events are written before any probe is asked, which is what lets a
    # backend do off-line preparation (summarizing closed days) the way a live
    # deployment's scheduler does. Backends that answer from a bounded window
    # must therefore filter by the day being asked about themselves — otherwise
    # they would answer day 5's question using day 30's events and look
    # artificially good. `FlatBackend`/`CompactionBackend` do that filtering.
    for day in days:
        for e in sorted(events_by_day.get(day, []), key=lambda x: x["seq"]):
            backend.write(day, e["seq"], e["text"],
                          {"topic": e["topic"]} if e.get("topic") else None)

    if prepare is not None:
        prepare(trace)

    # Phase 2 — ask each probe at its own point on the timeline.
    for day in days:
        for p in probes_by_day.get(day, []):
            ans = backend.answer(p["question"], day)
            got = extract_answer(ans.text, p["question"])
            ok = got == p["answer"]
            res.total += 1
            res.correct += int(ok)
            res.client_tokens += ans.client_tokens
            res.server_tokens += ans.server_tokens
            res.per_probe.append(ProbeResult(p["qid"], p["answer"], got, ok,
                                             ans.client_tokens))

    res.stored_chars = backend.stored_chars
    res.events_seen = backend.events_seen
    # Server-side spend accumulated on the backend itself (e.g. compaction
    # passes) must be added: it happens during `write`, not while answering, so
    # summing only the per-answer counts would report a compactor as free — the
    # exact mistake the two-sided accounting exists to prevent.
    res.server_tokens += backend.server_tokens
    backend.close()
    return res


# --- baselines --------------------------------------------------------------

def majority_baseline(trace: dict) -> tuple[str, float]:
    """Always answer the most common option. If a real backend cannot beat this
    by a clear margin, the trace does not discriminate."""
    counts: dict[str, int] = {}
    for p in trace["probes"]:
        counts[p["answer"]] = counts.get(p["answer"], 0) + 1
    top = max(counts, key=counts.get)
    return top, counts[top] / len(trace["probes"])


def oracle_baseline(trace: dict) -> float:
    return 1.0


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--trace", required=True)
    ap.add_argument("--backend", default="all",
                    choices=["all", "flat", "compaction", "chronomem-exact",
                             "chronomem-summary"])
    ap.add_argument("--purge", action="store_true",
                    help="truncate the Chronomem eval type before the run")
    ap.add_argument("--json-out")
    args = ap.parse_args()

    with open(args.trace, encoding="utf-8") as fh:
        trace = json.load(fh)

    todo: list[Backend] = []
    if args.backend in ("all", "flat"):
        todo.append(FlatBackend())
    if args.backend in ("all", "compaction"):
        todo.append(CompactionBackend())
    if args.backend in ("all", "chronomem-exact"):
        todo.append(ChronomemBackend(mode="exact"))
    if args.backend in ("all", "chronomem-summary"):
        todo.append(ChronomemBackend(mode="summary"))

    top, base = majority_baseline(trace)
    print(f"trace: {trace['meta']}")
    print(f"majority-class baseline: always '{top}' → {base:.0%}")
    print()

    results = []
    for b in todo:
        try:
            if isinstance(b, ChronomemBackend):
                if args.purge:
                    b.purge()
                b.setup()
            r = run_backend(b, trace)
        except Exception as exc:                      # noqa: BLE001
            print(f"[{b.name}] FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
            continue
        results.append(r)
        print(f"[{r.name}]")
        print(f"  accuracy              {r.correct}/{r.total} = {r.accuracy:.1%}")
        print(f"  client tokens/question {r.client_tokens_per_probe:8.0f}")
        print(f"  server tokens/question {r.server_tokens_per_probe:8.0f}")
        print(f"  total  tokens/question {r.client_tokens_per_probe + r.server_tokens_per_probe:8.0f}")
        print(f"  cumulative client      {r.client_tokens:8d}  ({r.total} probes)")
        print(f"  cumulative server      {r.server_tokens:8d}")
        print(f"  stored chars           {r.stored_chars:8d}")
        print()

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            json.dump({
                "meta": trace["meta"],
                "majority_baseline": {"choice": top, "accuracy": base},
                "results": [{
                    "name": r.name, "accuracy": r.accuracy,
                    "correct": r.correct, "total": r.total,
                    "client_tokens_per_probe": r.client_tokens_per_probe,
                    "server_tokens_per_probe": r.server_tokens_per_probe,
                    "client_tokens_total": r.client_tokens,
                    "server_tokens_total": r.server_tokens,
                    "stored_chars": r.stored_chars,
                    "per_probe": [vars(p) for p in r.per_probe],
                } for r in results],
            }, fh, ensure_ascii=False, indent=1)
        print(f"wrote {args.json_out}")


if __name__ == "__main__":
    main()

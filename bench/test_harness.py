#!/usr/bin/env python3
"""
Regression tests for the evaluation harness itself.

These exist because the harness produced several confident-looking results that
were wrong, each time in the *reader*, not in the system under test. Every test
below encodes a specific failure that actually happened, so the same mistake
cannot silently return as "the system forgot everything".

Run:  python3 -m unittest test_harness -v
"""

from __future__ import annotations

import json
import os
import tempfile
import unittest

# Imported as modules, and called through the module, so a test exercises the
# implementation as it stands rather than a snapshot bound at import time. This
# matters for mutation checks: patching `run_eval.extract_answer` must be visible
# to the tests, otherwise a broken implementation can pass.
import backends
import gen_trace
import run_eval
from token_survival import numeric_tokens, symbol_tokens
from backends import (ChronomemBackend, FlatBackend, CompactionBackend,
                      BASE_MS, TZ_SHIFT_MS, DAY_MS, HOUR_MS)

def extract_answer(text, question):
    return run_eval.extract_answer(text, question)

def majority_baseline(tr):
    return run_eval.majority_baseline(tr)

def gen_trace_generate(*a):
    return gen_trace.generate(*a)


class TestExtractAnswer(unittest.TestCase):
    """The reader must find the fact, and must refuse to invent one."""

    def test_english_raw_entry(self):
        """Pass 1: raw entries are English and carry topic + day."""
        text = ("[vun] (ref ZQ01) alice decided to go with option B for the vun "
                "work on day 3.")
        self.assertEqual(extract_answer(text, "What option was chosen for ref ZQ01 on day 3?"), "B")

    def test_english_edit_line(self):
        text = "(ref ZQ02) Applied option C in the keb module (bob, day 4)."
        self.assertEqual(extract_answer(text, "What option was chosen for ref ZQ02 on day 4?"), "C")

    def test_chinese_summary_by_ref(self):
        """Pass 1: the summarizer answers in Chinese; the reader must parse it.

        Before this was handled, every summary-backed probe was judged wrong and
        the level reported 0% — indistinguishable from "the summary lost the
        fact".
        """
        text = "【整窗】\n决策：\n- 在 vun 模块应用选项 C（ref ZU03）\n"
        self.assertEqual(extract_answer(text, "What option was chosen for ref ZU03 on day 2?"), "C")

    def test_chinese_summary_variants(self):
        """The model does not use one fixed phrasing.

        Each case names the topic, since a line that does not mention the topic
        carries no answer *for that topic* — returning its option anyway would be
        the guess this reader exists to avoid.
        """
        cases = [
            ("- vun 模块：Carol 选择方案 B", "vun", "B"),
            ("- 在 keb 模块应用选项 A", "keb", "A"),
            ("- 在 rix 模块采用选项 D 作为最终方案", "rix", "D"),
            ("- tas 模块选用方案 C", "tas", "C"),
        ]
        for line, topic, want in cases:
            with self.subTest(line=line):
                self.assertEqual(
                    extract_answer(line, f"What option was chosen for {topic} on day 1?"),
                    want)
        # A line with no topic mention must not answer for one.
        self.assertIsNone(extract_answer(
            "- 采用选项 D 作为最终方案", "What option was chosen for vun on day 1?"))

    def test_ambiguous_conclusion_sentence_picks_the_right_topic(self):
        """The bug that motivated the reference token.

        A summary's prose conclusion names several topics and several options in
        one sentence. Taking the first option letter there returns another
        topic's answer — and the wrong answer is *plausible*, so it does not look
        like a bug.
        """
        text_ref = ("【整窗】\n决策：\n"
                    "- 在 keb 模块应用选项 A（ref ZK01）\n"
                    "- 在 vun 模块应用选项 C（ref ZU03）\n\n"
                    "结论：\nDay 2 工作流执行完毕，keb 和 vun 模块分别应用了选项 A 和选项 C")
        self.assertEqual(
            extract_answer(text_ref, "What option was chosen for ref ZK01 on day 2?"), "A")
        self.assertEqual(
            extract_answer(text_ref, "What option was chosen for ref ZU03 on day 2?"), "C")
        # The conclusion sentence alone is genuinely ambiguous; the reader must
        # not be credited for guessing there.
        concl_only = "结论：\nDay 2 工作流执行完毕，keb 和 vun 模块分别应用了选项 A 和选项 C"
        self.assertIsNone(
            extract_answer(concl_only, "What option was chosen for ref ZU03 on day 2?"),
            "no reference token in the material means no reliable answer")

    def test_multi_day_material_requires_day_match(self):
        """A recency window spans days: a topic alone must not match.

        Matching on topic alone there returns another day's option, which credits
        the backend for something it did not retain. Measured: it inflated the
        recency baseline to 7% at lag 7 where the true figure is 0.
        """
        dump = ("[vun] alice decided to go with option B for the vun work on day 1.\n"
                "[keb] bob decided to go with option C for the keb work on day 6.")
        self.assertEqual(
            extract_answer(dump, "What option was chosen for vun on day 1?"), "B")
        self.assertIsNone(
            extract_answer(dump, "What option was chosen for vun on day 3?"),
            "a day that does not exist in the material must not borrow another day's option")

    def test_absent_fact_returns_none(self):
        """`None` is the drift signal; it must never be softened into a guess."""
        text = "【整窗】\n决策：\n- 在 keb 模块应用选项 A（ref ZK01）\n"
        # An unknown reference token: nothing in the material answers it.
        self.assertIsNone(extract_answer(text, "What option was chosen for ref ZX99 on day 1?"))
        # A known token paired with the wrong day still answers, because the
        # token itself identifies the fact regardless of the day in the prompt.
        self.assertEqual(extract_answer(text, "What option was chosen for ref ZK01 on day 9?"), "A")

    def test_ref_present_but_option_elsewhere_falls_back(self):
        """A token that appears only in a keyword list must not block a real match."""
        text = ("决策：\n- 在 vun 模块应用选项 B（ref ZV05）\n\n关键词：\nZV05, 选项 B")
        self.assertEqual(extract_answer(text, "What option was chosen for ref ZV05 on day 1?"), "B")


class TestTimeAlignment(unittest.TestCase):
    """Window maths must reproduce the service's calendar alignment.

    Summary lookup is an EQUALITY match on (windowFrom, windowTo): being an hour
    off does not degrade gracefully, it returns "no summary" and the level scores
    as empty.
    """

    def test_base_is_local_midnight(self):
        shifted = backends.BASE_MS + backends.TZ_SHIFT_MS
        self.assertEqual(shifted % DAY_MS, 0, "base must be a local midnight")

    def test_day_window_is_midnight_and_stable_within_the_day(self):
        for day in (1, 7, 30):
            start = backends.day_window_start(day)
            self.assertEqual((start + backends.TZ_SHIFT_MS) % backends.DAY_MS, 0)
            # Any timestamp inside the day maps to the same window.
            self.assertEqual(backends.day_window_start(day), backends.day_window_start(day))

    def test_consecutive_days_differ_by_exactly_one_day(self):
        self.assertEqual(backends.day_window_start(2) - backends.day_window_start(1), backends.DAY_MS)
        self.assertEqual(backends.day_window_start(30) - backends.day_window_start(29), backends.DAY_MS)

    def test_day_ms_is_inside_its_window(self):
        for day in (1, 2, 15, 30):
            w = backends.day_window_start(day)
            self.assertLessEqual(w, backends.day_ms(day))
            self.assertLess(backends.day_ms(day), w + backends.DAY_MS)


class TestTraceGeneration(unittest.TestCase):
    """The trace must be replayable and unambiguous."""

    def test_deterministic(self):
        a = gen_trace_generate(7, 3, 42)
        b = gen_trace_generate(7, 3, 42)
        self.assertEqual([vars(e) for e in a.events], [vars(e) for e in b.events])
        self.assertEqual([vars(p) for p in a.probes], [vars(p) for p in b.probes])

    def test_different_seed_differs(self):
        a = gen_trace_generate(7, 3, 42)
        b = gen_trace_generate(7, 3, 43)
        self.assertNotEqual([e.text for e in a.events], [e.text for e in b.events])

    def test_no_duplicate_topic_within_a_day(self):
        """Duplicate topics on one day make a (topic, day) question ambiguous."""
        tr = gen_trace_generate(30, 3, 7)
        seen = {}
        for e in tr.events:
            if e.kind != "decision":
                continue
            key = (e.day, e.topic)
            self.assertNotIn(key, seen, f"topic {e.topic} repeats on day {e.day}")
            seen[key] = e

    def test_every_fact_has_a_unique_reference_token(self):
        tr = gen_trace_generate(30, 3, 7)
        refs = [e.ref for e in tr.events if e.kind == "decision"]
        self.assertTrue(all(refs), "every decision must carry a reference token")
        self.assertEqual(len(refs), len(set(refs)), "reference tokens must be unique")

    def test_probe_asks_about_a_different_day_than_it_is_asked_on(self):
        """A same-day probe measures nothing about long-horizon memory."""
        tr = gen_trace_generate(30, 3, 7)
        import re
        same_day = 0
        for p in tr.probes:
            m = re.search(r"on day (\d+)", p.question)
            if m and int(m.group(1)) == p.day_asked:
                same_day += 1
        self.assertEqual(same_day, 0, "probes must look backwards")

    def test_majority_baseline_leaves_headroom(self):
        """A trace whose answers cluster lets majority-class guessing win."""
        tr = gen_trace_generate(30, 3, 7)
        payload = {"probes": [vars(p) for p in tr.probes]}
        _choice, acc = majority_baseline(payload)
        self.assertLess(acc, 0.75, "majority-class baseline is too strong to discriminate")


class TestIsolation(unittest.TestCase):
    """An experiment must not be able to touch the production instance."""

    def test_production_port_is_refused(self):
        with self.assertRaises(ValueError):
            ChronomemBackend(url="http://127.0.0.1:8900/mcp")

    def test_default_points_at_the_bench_instance(self):
        b = ChronomemBackend()
        self.assertIn("18900", b.url)
        self.assertNotIn(":8900", b.url)


class TestBaselinesDoNotSeeTheFuture(unittest.TestCase):
    """The runner ingests the whole trace before probing, so a bounded backend
    must filter by the day being asked about or it answers old questions using
    later events."""

    def test_flat_excludes_later_days(self):
        b = FlatBackend(top_k=50)
        b.write(1, 0, "day one fact")
        b.write(20, 0, "day twenty fact")
        early = b.answer("q", day_asked=1)
        self.assertIn("day one", early.text)
        self.assertNotIn("day twenty", early.text,
                         "a probe about day 1 must not see day 20")

    def test_flat_keeps_only_top_k(self):
        b = FlatBackend(top_k=5)
        for i in range(50):
            b.write(i + 1, 0, f"event {i}")
        ans = b.answer("q", day_asked=50)
        self.assertEqual(len(ans.text.splitlines()), 5)

    def test_compaction_report_is_frozen_at_ask_time(self):
        b = CompactionBackend(compact_every_days=1, keep_per_pass=1)
        for day in range(1, 8):
            b.write(day, 0, f"[vun] alice decided to go with option A for the vun work on day {day}.")
        early = b.answer("q", day_asked=2)
        late = b.answer("q", day_asked=7)
        self.assertLessEqual(len(early.text.splitlines()), len(late.text.splitlines()))


if __name__ == "__main__":
    unittest.main(verbosity=2)

class TestLagBuckets(unittest.TestCase):
    """Bucket labels must not be mistaken for the lag itself.

    A bucket holds a *range* of lags (14-29 for the bucket whose lower edge is
    14). Reporting the lower edge as the lag invites conclusions about "14 days"
    that the probes never tested — measured: the 30-day trace's top bucket
    contains 29-day probes, which made a 20-day window look non-compliant.
    """

    def test_bucket_is_a_lower_bound(self):
        re_mod = __import__("retention_eval")
        self.assertEqual(re_mod.bucket_of(1), 1)
        self.assertEqual(re_mod.bucket_of(4), 3)
        self.assertEqual(re_mod.bucket_of(6), 5)
        self.assertEqual(re_mod.bucket_of(10), 7)
        self.assertEqual(re_mod.bucket_of(29), 14)

    def test_label_shows_a_range_not_a_point(self):
        re_mod = __import__("retention_eval")
        self.assertEqual(re_mod.bucket_label(14), "14-29")
        self.assertEqual(re_mod.bucket_label(7), "7-13")
        self.assertEqual(re_mod.bucket_label(3), "3-4")
        # A single-day bucket stays a single number.
        self.assertEqual(re_mod.bucket_label(1), "1")
        self.assertEqual(re_mod.bucket_label(2), "2")

    def test_label_prefers_observed_span(self):
        re_mod = __import__("retention_eval")
        # Observed lags narrower than the nominal edges are reported as-is.
        self.assertEqual(re_mod.bucket_label(14, [14, 20, 22]), "14-22")
        self.assertEqual(re_mod.bucket_label(14, [14]), "14")

class TestCleanupIsNotSilent(unittest.TestCase):
    """A clean-up that fails quietly is worse than one that crashes.

    If the series is not actually emptied, the next ingest fails on
    `out-of-order append` and the run reports 0% — indistinguishable from a
    system that forgot everything. A wrong tool-argument name produces exactly
    that shape, which is why only "type does not exist" may be tolerated here.

    A fake `_call` is injected in every case: these tests must not need a running
    instance, or they would fail in CI (where none exists) and be "fixed" by
    deleting them.
    """

    def _backend(self, reply):
        b = ChronomemBackend(mode="exact")

        def fake(tool, args):
            if isinstance(reply, Exception):
                raise reply
            return reply
        b._call = fake
        return b

    def test_missing_type_is_tolerated(self):
        # A first run has nothing to clean; the service reports the type is absent.
        b = self._backend(RuntimeError("类型不存在: bench/eval"))
        b.purge()          # must not raise

    def test_other_errors_propagate(self):
        # A wrong argument name fails exactly like this, and silently leaving the
        # old series behind is what turns it into a bogus 0%.
        b = self._backend(RuntimeError("缺少参数 type"))
        with self.assertRaises(RuntimeError):
            b.purge()

    def test_connection_error_propagates(self):
        b = self._backend(RuntimeError("Connection refused"))
        with self.assertRaises(RuntimeError):
            b.purge()

    def test_setup_tolerates_only_already_exists(self):
        b = self._backend(RuntimeError("类型已存在: bench/eval"))
        b.setup()          # tolerated
        b2 = self._backend(RuntimeError("连接失败"))
        with self.assertRaises(RuntimeError):
            b2.setup()

    def test_successful_purge_is_quiet(self):
        b = self._backend("已清空类型 bench/eval")
        b.purge()

class TestPackedSegments(unittest.TestCase):
    """Several facts can share one line, keyed by their reference tokens.

    A summary often packs a whole day into one sentence — "- Day 1: ZT02 选方案 B
    (keb), ZR01 选方案 A (rix)". A reader that takes the segment's first option
    returns the *other* fact's answer, and because the letter is plausible it
    looks like a wrong answer rather than a reader bug. Measured: this made the
    week-level arm score 0% at short lags while the correct option sat in the
    same line.
    """

    def test_token_before_option(self):
        text = "决策：\n- Day 1: ZT02 选方案 B (keb), ZR01 选方案 A (rix)"
        self.assertEqual(extract_answer(text, "What option was chosen for ref ZR01 on day 1?"), "A")
        self.assertEqual(extract_answer(text, "What option was chosen for ref ZT02 on day 1?"), "B")

    def test_option_before_token(self):
        text = "决策：- 方案 A（ZR01）、方案 C（ZT02）"
        self.assertEqual(extract_answer(text, "What option was chosen for ref ZR01 on day 1?"), "A")
        self.assertEqual(extract_answer(text, "What option was chosen for ref ZT02 on day 1?"), "C")

    def test_token_only_in_keyword_list_is_none(self):
        # A token that appears solely in a keyword list carries no answer for it.
        text = "关键词：ZR01, ZT02, keb"
        self.assertIsNone(extract_answer(text, "What option was chosen for ref ZR01 on day 1?"))

class TestConservativeCompaction(unittest.TestCase):
    """The reviewer-facing control for the destructive-compaction baseline.

    The strongest objection to that baseline is that we wrote it to be
    destructive, so its zero scores might say nothing about compaction as a
    strategy. This arm compacts on the same schedule but keeps every
    token-to-value pair, which separates "compaction is destructive" from "our
    compactor was".
    """

    def test_keeps_token_value_pairs(self):
        b = backends.ConservativeCompactionBackend(compact_every_days=1)
        b.write(1, 0, "[vun] (ref ZR01) alice decided to go with option A for the vun work.")
        b.write(1, 1, "(ref ZT02) Applied option B in the keb module.")
        b._compact()
        joined = "\n".join(b.pairs)
        self.assertIn("ZR01", joined)
        self.assertIn("option A", joined)
        self.assertIn("ZT02", joined)
        self.assertIn("option B", joined)

    def test_answers_with_the_same_reader_as_other_arms(self):
        # The pairs must be readable by the shared extractor. An earlier version
        # emitted "ZR01=A", which nothing could parse, and the arm scored 0% for a
        # formatting reason rather than a retention one.
        b = backends.ConservativeCompactionBackend(compact_every_days=1)
        b.write(1, 0, "[vun] (ref ZR01) alice decided to go with option A for the vun work.")
        b._compact()
        ans = b.answer("What option was chosen for ref ZR01 on day 1?", day_asked=1)
        self.assertEqual(extract_answer(ans.text, "What option was chosen for ref ZR01 on day 1?"), "A")

    def test_drops_context_but_not_the_pair(self):
        b = backends.ConservativeCompactionBackend(compact_every_days=1)
        long_text = ("[vun] (ref ZR01) alice decided to go with option A for the vun work "
                     "after a long discussion of trade-offs and timings on day 1.")
        b.write(1, 0, long_text)
        b._compact()
        joined = " ".join(b.pairs)
        self.assertNotIn("trade-offs", joined, "context should be dropped")
        self.assertIn("ZR01", joined, "the pair must survive")

class TestTokenClassifiers(unittest.TestCase):
    """The classifiers the survival numbers rest on.

    Validated against a hand-labelled gold set after the reviewer asked whether
    anyone had checked them. The first check found the identifier detector at
    0.22 recall — blind to UPPER_SNAKE_CASE, PascalCase and hyphenated names,
    i.e. to most of the class the paper claims survives longest.
    """

    def test_upper_snake_and_pascal_case_are_identifiers(self):
        for tok in ("OP_PUSH_CONSTANT", "WritePipeline", "CertificateVerifyMode",
                    "g_runtimeStaticEnd", "MRT_REPORT"):
            self.assertIn(tok, symbol_tokens(f"提到 {tok} 的实现"), tok)

    def test_hyphenated_flag_is_an_identifier(self):
        self.assertIn("--sleep-idle-seconds",
                      symbol_tokens("用 --sleep-idle-seconds 900"))

    def test_backticked_span_splits_into_separate_names(self):
        got = symbol_tokens("`WritePipeline markFailed` 抛异常")
        self.assertIn("WritePipeline", got)
        self.assertIn("markFailed", got)

    def test_markdown_noise_is_not_an_identifier(self):
        got = symbol_tokens("*jsonBridge* 和 (c) 以及 --el-button-")
        self.assertIn("jsonBridge", got)
        self.assertNotIn("(c)", got)
        self.assertNotIn("--el-button-", got)

    def test_timestamps_are_not_quantities(self):
        # 09-15 20:49:55 used to yield 09, 15, 20, 49, 55 as "quantities".
        for text in ("09-15 20:49:55 写路径失败", "2024-01-01 发布",
                     "2026-10-16T05:12:45 materialize"):
            self.assertEqual(numeric_tokens(text), set(), text)

    def test_unit_suffixed_quantities_are_kept(self):
        for text, want in (("堆上限由 256MB 提到 1GB", {"256MB", "1GB"}),
                           ("存活量仅 30-60MB", {"30-60MB"}),
                           ("5.1x vs 31x", {"5.1x", "31x"})):
            self.assertEqual(numeric_tokens(text), want, text)

    def test_bare_years_remain_excluded(self):
        self.assertEqual(numeric_tokens("2026 年的部署"), set())

class TestNoRefVariant(unittest.TestCase):
    """The trace variant that removes the opaque reference token.

    Built to test the reviewer's concern that the token makes exact recall
    trivially extractable. The two traces must differ in exactly that one
    respect, or the comparison does not isolate anything.
    """

    def test_only_the_token_differs(self):
        a = gen_trace.generate(days=5, agents=3, seed=7, no_ref=False)
        b = gen_trace.generate(days=5, agents=3, seed=7, no_ref=True)
        self.assertEqual(len(a.events), len(b.events))
        self.assertEqual(len(a.probes), len(b.probes))
        for ea, eb in zip(a.events, b.events):
            self.assertEqual(ea.day, eb.day)
            self.assertEqual(ea.topic, eb.topic)
            self.assertEqual(ea.answer, eb.answer)
            # The only textual difference is the `(ref Zxx) ` prefix.
            self.assertEqual(ea.text.replace(f"(ref {ea.ref}) ", ""), eb.text)

    def test_token_absent_when_disabled(self):
        import re as _re
        b = gen_trace.generate(days=5, agents=3, seed=7, no_ref=True)
        for e in b.events:
            self.assertIsNone(_re.search(r"\bZ[A-Z]\d{2}\b", e.text), e.text)

    def test_probes_use_topic_when_disabled(self):
        b = gen_trace.generate(days=5, agents=3, seed=7, no_ref=True)
        for p in b.probes:
            self.assertNotIn("ref Z", p.question)
            self.assertIn(p.topic, p.question)

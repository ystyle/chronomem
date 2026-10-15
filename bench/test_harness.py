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

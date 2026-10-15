#!/usr/bin/env python3
"""
Mutation check for the evaluation harness.

Passing tests prove little on their own: a test can pass because the
implementation is right, or because the test never exercises the thing it names.
This script deliberately breaks the implementation in the ways that actually
happened, and asserts the suite notices.

Every mutation below corresponds to a real defect from the harness's history,
listed in `MUTATIONS`. If one stops being caught, a test has silently stopped
covering it — which is exactly how several wrong results got through before.

Nothing here modifies files: the module attribute is patched, the suite is run,
and the original is restored.

Run:  python3 check_mutations.py
Exit code is non-zero if any mutation goes undetected.
"""

from __future__ import annotations

import io
import re
import sys
import unittest

import backends
import gen_trace
import run_eval
import test_harness as th


def _run(cls, names) -> int:
    suite = unittest.TestSuite()
    for n in names:
        suite.addTest(cls(n))
    res = unittest.TextTestRunner(verbosity=0, stream=io.StringIO()).run(suite)
    return len(res.failures) + len(res.errors)


# Each entry: (label, patch, restore, test class, test names)
MUTATIONS: list = []


def mutation(label, cls, names):
    def deco(fn):
        MUTATIONS.append((label, fn, cls, names))
        return fn
    return deco


@mutation("移除中文提取（摘要用中文作答）", th.TestExtractAnswer,
          ["test_chinese_summary_by_ref", "test_chinese_summary_variants"])
def _m1():
    orig = run_eval._option_in

    def english_only(seg):
        for rx in (run_eval.DECISION_RE, run_eval.EDIT_RE):
            mm = rx.search(seg)
            if mm:
                return mm.group("choice").upper()
        return None
    run_eval._option_in = english_only
    return lambda: setattr(run_eval, "_option_in", orig)


@mutation("多天材料只按主题匹配（会取到别天的答案）", th.TestExtractAnswer,
          ["test_multi_day_material_requires_day_match"])
def _m2():
    orig = run_eval.extract_answer

    def loose(text, question):
        m = re.search(r"for ([a-z]+) on day (\d+)", question, re.IGNORECASE)
        if not m:
            return orig(text, question)
        topic = m.group(1).lower()
        for seg in re.split(r"[\n\r;；]", text):
            if re.search(r"(?<![a-z])" + topic + r"(?![a-z])", seg, re.IGNORECASE):
                o = run_eval._option_in(seg)
                if o:
                    return o
        return None
    run_eval.extract_answer = loose
    return lambda: setattr(run_eval, "extract_answer", orig)


@mutation("忽略引用号，取全文第一个选项（歧义句取错主题）", th.TestExtractAnswer,
          ["test_ambiguous_conclusion_sentence_picks_the_right_topic"])
def _m3():
    orig = run_eval.extract_answer

    def sloppy(text, question):
        if not re.search(r"ref\s+Z[A-Z]\d{2}", question, re.IGNORECASE):
            return orig(text, question)
        return run_eval._option_in(text)
    run_eval.extract_answer = sloppy
    return lambda: setattr(run_eval, "extract_answer", orig)


@mutation("默认 URL 指向生产端口且不拒绝", th.TestIsolation,
          ["test_production_port_is_refused", "test_default_points_at_the_bench_instance"])
def _m4():
    orig = backends.ChronomemBackend.__init__

    def permissive(self, url="http://127.0.0.1:8900/mcp", **kw):
        self.url = url
    backends.ChronomemBackend.__init__ = permissive
    return lambda: setattr(backends.ChronomemBackend, "__init__", orig)


@mutation("日窗口基准偏移 1 小时（服务是全等匹配，差一点即落空）",
          th.TestTimeAlignment,
          ["test_day_window_is_midnight_and_stable_within_the_day",
           "test_day_ms_is_inside_its_window"])
def _m5():
    orig = backends.day_window_start
    backends.day_window_start = lambda d: orig(d) + 3600_000
    return lambda: setattr(backends, "day_window_start", orig)


@mutation("基准不再是本地零点", th.TestTimeAlignment, ["test_base_is_local_midnight"])
def _m6():
    orig = backends.BASE_MS
    backends.BASE_MS = orig + 3600_000
    return lambda: setattr(backends, "BASE_MS", orig)


@mutation("每天主题允许重复（探针出现歧义）", th.TestTraceGeneration,
          ["test_no_duplicate_topic_within_a_day"])
def _m7():
    orig = gen_trace.random.Random.sample
    gen_trace.random.Random.sample = lambda self, pop, k: [self.choice(pop) for _ in range(k)]
    return lambda: setattr(gen_trace.random.Random, "sample", orig)


@mutation("引用号不唯一", th.TestTraceGeneration,
          ["test_every_fact_has_a_unique_reference_token"])
def _m8():
    orig = gen_trace.generate

    def const_ref(*a, **kw):
        tr = orig(*a, **kw)
        for e in tr.events:
            if e.ref:
                e.ref = "ZQ01"
        for p in tr.probes:
            if p.ref:
                p.ref = "ZQ01"
        return tr
    gen_trace.generate = const_ref
    return lambda: setattr(gen_trace, "generate", orig)


@mutation("探针改问当天（测不出长期记忆）", th.TestTraceGeneration,
          ["test_probe_asks_about_a_different_day_than_it_is_asked_on"])
def _m9():
    orig = gen_trace.generate

    def same_day(*a, **kw):
        tr = orig(*a, **kw)
        for p in tr.probes:
            p.day_asked = p.day_asked          # unchanged; shift the question day
            p.question = re.sub(r"on day \d+", f"on day {p.day_asked}", p.question)
        return tr
    gen_trace.generate = same_day
    return lambda: setattr(gen_trace, "generate", orig)


@mutation("清理失败被静默吞掉（旧数据残留 → 实验静默归零）", th.TestCleanupIsNotSilent,
          ["test_other_errors_propagate", "test_connection_error_propagates"])
def _m10():
    """Restore the original `except RuntimeError: pass`."""
    orig = backends.ChronomemBackend.purge

    def quiet_purge(self):
        try:
            self._call("mem/truncate", {"type": self.mtype})
        except Exception:
            pass
    backends.ChronomemBackend.purge = quiet_purge
    return lambda: setattr(backends.ChronomemBackend, "purge", orig)


def main() -> int:
    print("mutation check: does the suite actually catch these defects?\n")
    undetected = []
    for label, factory, cls, names in MUTATIONS:
        restore = factory()
        try:
            caught = _run(cls, names)
        finally:
            restore()
        status = "caught " if caught else "MISSED "
        print(f"  [{status}] {label}  ({caught} test(s) failed)")
        if not caught:
            undetected.append(label)

    print()
    if undetected:
        print(f"{len(undetected)} mutation(s) undetected:")
        for u in undetected:
            print(f"  - {u}")
        return 1
    print(f"all {len(MUTATIONS)} mutations detected — the suite covers what it claims.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

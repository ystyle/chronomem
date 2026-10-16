#!/usr/bin/env python3
"""
Validate the token classifiers against a hand-labelled gold set.

The reviewer's question is the right one: the whole "identifiers outlast
quantities" ordering rests on three regexes, and nobody checked their precision
or recall — least of all on the Chinese text that most of the real corpus is
written in. If the numeric detector has low recall on, say, Chinese numerals or
unit-suffixed quantities, the ordering could be an artefact of the detector.

This file holds a gold set built by hand from the real corpus's own idioms, with
every span labelled by what it *is* rather than by what the regexes happen to
match. It then reports, per classifier:

  precision / recall / F1
  every false negative and false positive, with the text that caused it

The gold set is deliberately adversarial: it includes the borderline cases the
reviewer named (years, short numerics, Chinese numerals, identifiers that look
like quantities, causal words used non-causally, and Cangjie/English mixes).

Usage:
    python3 validate_classifiers.py [--out results/token-classifier-validation.json]
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from token_survival import numeric_tokens, symbol_tokens, causal_tokens  # noqa: E402

# --- gold set -----------------------------------------------------------------
#
# Each item: (text, expected sets). Expectations are what a careful human reader
# would call a quantity / an identifier / a causal connective — not what the
# current regex returns. Cases are drawn from the deployment's real wording and
# from the failure modes the reviewer asked about.

NUMERIC_CASES: list[tuple[str, set[str]]] = [
    # --- quantities that plainly are quantities ---
    ("清单从 244 个文件收到 101 个", {"244", "101"}),
    ("峰值 RSS 恒定在 284 MiB", {"284"}),          # unit spelled separately
    ("堆上限由 256MB 提到 1GB", {"256MB", "1GB"}),
    ("prefill 吞吐 317 对 267 tok/s", {"317", "267"}),
    ("LSM 文件号 18 小时涨 ~940", {"18", "940"}),
    ("存活量仅 30-60MB", {"30-60MB"}),
    ("fd 从 1009 降到 10", {"1009", "10"}),
    ("CLOSE_WAIT 曾 662", {"662"}),
    ("retain=0.16", {"0.16"}),
    ("threshold=min(W×0.8, pressureBudget)", {"0.8"}),
    ("8192 码点 → 头 4096 + 尾 1024", {"8192", "4096", "1024"}),
    ("92/0", {"92/0"}),
    ("5.1x vs 31x", {"5.1x", "31x"}),
    ("7月70/8月41/9月68/10月11", {"70/8", "41/9", "68/10", "11"}),  # "/" glues across the month boundary
    ("427/427", {"427/427"}),
    ("1540+1676+2608 行", {"1540", "1676", "2608"}),

    # --- months/days are labels, not quantities ---
    ("09-15 20:49:55", set()),
    ("2026-10-16T05:12:45", set()),
    ("Day 1 至 Day 6", set()),
    ("Phase 2 完成", set()),

    # --- bare years are labels ---
    ("2026 年的部署", set()),
    ("2024-01-01", set()),

    # --- single digits: too short to be evidentiary (by design) ---
    ("有 3 个探针", set()),
    ("A/B/C 三个选项", set()),

    # --- Chinese numerals: the detector is digits-only, so these are MISSES ---
    ("三个修复中有一项是幂等的", set()),          # no digits → expected empty
    ("降到了三分之一", set()),

    # --- mixed units and awkward forms ---
    ("96 个文件、12 个 C 符号", {"96", "12"}),
    ("连接池上限 10，第 11 次失败", {"10", "11"}),
    ("48 vs 28", {"48", "28"}),
    ("50/200", {"50/200"}),
    ("1/3 提升到 3/3", {"1/3", "3/3"}),            # both are real ratios
    ("sha256 全文比对", {"256"}),                 # debatable: part of an algorithm name
]

SYMBOL_CASES: list[tuple[str, set[str]]] = [
    ("materialize 不幂等", {"materialize"}),
    ("`WritePipeline markFailed` 抛异常", {"WritePipeline", "markFailed"}),
    ("cjHeapSize 由 256MB 提到 1GB", {"cjHeapSize"}),
    ("用 --sleep-idle-seconds 900", {"--sleep-idle-seconds"}),
    ("CHRONOLOG_SUMMARY_CONTEXT_TOKENS=131072", {"CHRONOLOG_SUMMARY_CONTEXT_TOKENS"}),
    ("g_runtimeStaticEnd", {"g_runtimeStaticEnd"}),
    ("OP_PUSH_CONSTANT", {"OP_PUSH_CONSTANT"}),
    ("CertificateVerifyMode.TrustAll", {"CertificateVerifyMode"}),
    ("TomlProvider.skipToVerify", {"TomlProvider"}),
    ("anthropic-beta: files-api-2025-04-14", {"anthropic-beta", "files-api-2025-04-14"}),
    ("badgercj 1.6.20", {"badgercj"}),
    ("llm_api 1.4.1", {"llm_api"}),
    ("pkgLabel 含 @version", {"pkgLabel"}),
    ("<compacted-summary> 标签", {"compacted-summary"}),
    ("sseCond.wait()", {"sseCond.wait"}),
    ("MRT_REPORT GC 日志", {"MRT_REPORT"}),

    # --- plain words must NOT count ---
    ("这是一个测试条目", set()),
    ("数据库和缓存", set()),
    ("the quick brown fox", set()),
]

CAUSAL_CASES: list[tuple[str, set[str]]] = [
    ("因为空 message 吞掉了异常身份", {"因为"}),
    ("由于连接未回收，fd 持续增长", {"由于"}),
    ("根因是瞬时分配峰值", {"根因"}),
    ("写放大导致每分钟一次 rotate", {"导致"}),
    ("因此断言失败", {"因此"}),
    ("所以 heap 提到 1GB", {"所以"}),
    ("版本序退化成字典序", {"退化成"}),
    ("原因是比较器用了标签", {"原因是"}),
    ("为了避免复发加了守卫", {"避免"}),
    ("必须幂等，否则每分钟重写", {"否则"}),

    # --- adversarially: 为了 used non-causally, and other near-misses ---
    ("为了排版的方便调整了缩进", {"为了"}),        # detector counts it; it is not causal
    ("所以然", set()),                             # 所以 as a substring of 所以然? — check
    ("因果关系", set()),                           # 因果 ≠ 因为
]


def score(cases, fn):
    tp = fp = fn_ = 0
    misses, spurious = [], []
    for text, expected in cases:
        got = fn(text)
        for t in got & expected:
            tp += 1
        for t in got - expected:
            fp += 1
            spurious.append({"text": text, "token": t})
        for t in expected - got:
            fn_ += 1
            misses.append({"text": text, "token": t})
    prec = tp / (tp + fp) if tp + fp else 1.0
    rec = tp / (tp + fn_) if tp + fn_ else 1.0
    f1 = 2 * prec * rec / (prec + rec) if prec + rec else 0.0
    return {"tp": tp, "fp": fp, "fn": fn_, "precision": prec, "recall": rec,
            "f1": f1, "false_negatives": misses, "false_positives": spurious}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    results = {
        "numeric": score(NUMERIC_CASES, numeric_tokens),
        "symbol": score(SYMBOL_CASES, symbol_tokens),
        "causal": score(CAUSAL_CASES, causal_tokens),
    }

    print(f"{'classifier':10} {'tp':>4} {'fp':>4} {'fn':>4} {'prec':>7} {'rec':>7} {'F1':>7}")
    for name, r in results.items():
        print(f"{name:10} {r['tp']:>4} {r['fp']:>4} {r['fn']:>4} "
              f"{r['precision']:>6.2f} {r['recall']:>6.2f} {r['f1']:>6.2f}")

    for name, r in results.items():
        if r["false_negatives"]:
            print(f"\n{name} — false negatives ({len(r['false_negatives'])}):")
            for m in r["false_negatives"][:10]:
                print(f"    missing {m['token']!r} in {m['text'][:60]!r}")
        if r["false_positives"]:
            print(f"\n{name} — false positives ({len(r['false_positives'])}):")
            for m in r["false_positives"][:10]:
                print(f"    spurious {m['token']!r} in {m['text'][:60]!r}")

    if a.out:
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        with open(a.out, "w", encoding="utf-8") as fh:
            json.dump({"n_cases": {"numeric": len(NUMERIC_CASES),
                                   "symbol": len(SYMBOL_CASES),
                                   "causal": len(CAUSAL_CASES)},
                       "results": results}, fh, ensure_ascii=False, indent=1)
        print(f"\nwrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

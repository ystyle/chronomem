#!/usr/bin/env python3
"""
Semantic survival, to complement the token-overlap metric.

The reviewer's objection to the mechanical metric is precise: counting whether a
token survives conflates lexical with semantic preservation, so a fact restated
in different words is scored as lost and a fact whose tokens remain but whose
meaning is inverted is scored as kept. Both directions are real — §5.2 notes a
case where a summary wrote `pkgLabel` out but dropped what it meant.

This measures the same chain with embeddings instead of string matching, using
the deployment's own `qwen3-embed` endpoint (1024-d). For each (fact, level):

  * `token_kept`   — the token-survival verdict, for reference;
  * `sim_fact`     — cosine similarity between the fact's text and the level's
                     text, which is *not* informative on its own (a long summary
                     is similar to everything in it);
  * `sim_margin`   — the quantity that matters: similarity of the level's text to
                     the fact **minus** its similarity to a control fact drawn
                     from a different window. That difference is ~0 when the level
                     does not distinguish the fact from an unrelated one, and
                     large when it does. It is the embedding analogue of "can you
                     find this fact here".

The comparison the reviewer asked for is then: where do token survival and the
semantic margin disagree? Each disagreement is classified and counted, so the
paper can report the metric's error direction rather than assert it is fine.

Read-only against production for the corpus; embeddings go to the model endpoint.

Usage:
    python3 semantic_survival.py --pairs 8 --out results/real-corpus/semantic-survival.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sample_real                                     # read-only guarded
from token_survival import group_text                  # noqa: E402

CST = timezone(timedelta(hours=8))
PROD = "http://127.0.0.1:8900/mcp"


def load_llm() -> tuple[str, str, str]:
    env = os.path.expanduser("~/docker/chronomem/.env")
    base = key = model = ""
    with open(env, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("LLM_BASE_URL="):
                base = line.split("=", 1)[1].strip().strip('"')
            elif line.startswith("LLM_API_KEY="):
                key = line.split("=", 1)[1].strip().strip('"')
    return base, key, "qwen3-embed"


# The embedding endpoint runs with `--ctx-size 8192`, so a whole week summary
# (tens of thousands of characters) in one request never returns — measured as a
# read timeout with no error message from the server. Split every input into
# chunks that fit and average their vectors; averaging unit-normalised chunk
# vectors keeps the result comparable across inputs of different lengths.
# Measured against the live endpoint: a synthetic string of 1000 ASCII-safe
# characters returns, but real summary text can fail at 800 characters while a
# 718-character prefix of the *same* text succeeds — so the limit is on tokens,
# not characters, and CJK plus code identifiers tokenise far denser than the
# estimate. 300 characters stays clear of it, and `_embed_batch` retries once at
# half the size before giving up, because a single oversized chunk otherwise
# aborts the whole run.
EMBED_CHARS = 300
# The endpoint's --ctx-size is 8192; keep batches small so one dense chunk cannot
# push the total over.
EMBED_BATCH = 8


def _embed_batch(texts: list[str], base: str, key: str, model: str,
                 timeout: int = 240, _depth: int = 0) -> list[list[float]]:
    """One request. On a 500, halve the inputs once and retry.

    The server returns 500 (not a length error) when a chunk is too dense, and
    the threshold depends on the content, so the caller cannot size chunks
    reliably in advance. Halving is safe here: it only changes how a text's
    vector is averaged, and it is attempted at most twice.
    """
    body = json.dumps({"model": model, "input": texts}).encode()
    req = urllib.request.Request(f"{base.rstrip('/')}/embeddings", data=body,
                                 headers={"Content-Type": "application/json",
                                          "Authorization": f"Bearer {key}"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode())
        return [d["embedding"] for d in payload["data"]]
    except urllib.error.HTTPError as exc:
        if exc.code != 500 or _depth >= 2 or all(len(t) <= 40 for t in texts):
            raise
        halves = [t[: len(t) // 2 + 1] for t in texts]
        got = _embed_batch(halves, base, key, model, timeout, _depth + 1)
        # Also embed the tail on the final attempt, so nothing is silently
        # dropped: the vector a caller gets must describe the whole input.
        tails = [t[len(t) // 2 + 1:] for t in texts]
        if all(not t.strip() for t in tails):
            return got
        rest = _embed_batch(tails, base, key, model, timeout, _depth + 1)
        return [[(a + b) / 2 for a, b in zip(v1, v2)] for v1, v2 in zip(got, rest)]


def _norm(v: list[float]) -> list[float]:
    n = math.sqrt(sum(x * x for x in v))
    return [x / n for x in v] if n else v


def embed(texts: list[str], base: str, key: str, model: str) -> list[list[float]]:
    """Embed arbitrarily long texts by chunking and averaging."""
    out: list[list[float]] = []
    for t in texts:
        # Cap the number of chunks per text as well: a week summary would
        # otherwise produce dozens of chunks, and one oversized request makes the
        # server return 500 for the entire batch rather than the offending item.
        chunks = [t[i:i + EMBED_CHARS]
                  for i in range(0, min(len(t), EMBED_CHARS * 24), EMBED_CHARS)] or [" "]
        vecs = []
        for i in range(0, len(chunks), EMBED_BATCH):
            vecs.extend(_norm(v) for v in
                        _embed_batch(chunks[i:i + EMBED_BATCH], base, key, model))
        acc = [0.0] * len(vecs[0])
        for v in vecs:
            for i, x in enumerate(v):
                acc[i] += x
        out.append(_norm([x / len(vecs) for x in acc]))
    return out


def cosine(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


def facts_from(text: str, k: int = 6) -> list[str]:
    """Pull fact-bearing lines out of a raw entry listing."""
    out = []
    for line in text.splitlines():
        m = re.search(r'"(?:task|outcome|decisions)"\s*:\s*"(.{40,400}?)"', line)
        if m:
            out.append(m.group(1)[:400])
        if len(out) >= k:
            break
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pairs", type=int, default=8, help="how many day windows")
    ap.add_argument("--facts-per-window", type=int, default=4)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    base, key, model = load_llm()
    if not (base and key):
        print("no LLM endpoint configured", file=sys.stderr)
        return 1

    s = sample_real.rpc(PROD, "mem/summaries", {"type": "worklog", "limit": 500})
    wins = [(int(x), int(y)) for x, y in re.findall(r"窗口 (\d+)~(\d+)", s)]
    days = sorted({f for f, t in wins if 0.5 <= (t - f) / 86_400_000 < 1.5}, reverse=True)
    weeks = {f for f, t in wins if 6 <= (t - f) / 86_400_000 < 8}
    usable = [d for d in days if any(w <= d < w + 7 * 86_400_000 for w in weeks)][:a.pairs]

    rows = []
    for d in usable:
        raw = sample_real.rpc(PROD, "mem/query", {
            "type": "worklog", "from": d, "to": d + 86_400_000 - 1, "limit": 200})
        day_groups = group_text(sample_real.rpc(PROD, "mem/recall", {
            "type": "worklog", "granularity": "day", "mode": "summary",
            "windowStartMs": d}))
        wk = [w for w in weeks if w <= d < w + 7 * 86_400_000]
        week_groups = group_text(sample_real.rpc(PROD, "mem/recall", {
            "type": "worklog", "granularity": "week", "mode": "summary",
            "windowStartMs": wk[0]})) if wk else {}

        facts = facts_from(raw, a.facts_per_window)
        if not facts:
            continue

        # Control facts: same shape, drawn from a different window, so the margin
        # measures discrimination rather than mere topical overlap.
        other = [x for x in usable if x != d][:2]
        ctrl_raw = " ".join(sample_real.rpc(PROD, "mem/query", {
            "type": "worklog", "from": c, "to": c + 86_400_000 - 1, "limit": 60})
            for c in other)
        ctrl = facts_from(ctrl_raw, a.facts_per_window) or ["(no control)"]

        # Batch everything for this window into one embedding call.
        day_text = "\n".join(day_groups.values())
        week_text = "\n".join(week_groups.values())
        batch = facts + ctrl + [day_text or " ", week_text or " "]
        vecs = embed(batch, base, key, model)
        fv = vecs[:len(facts)]
        cv = vecs[len(facts):len(facts) + len(ctrl)]
        dv, wv = vecs[-2], vecs[-1]
        ctrl_d = [cosine(x, dv) for x in cv]
        ctrl_w = [cosine(x, wv) for x in cv]

        for f, v in zip(facts, fv):
            # Token verdict ≈ does any distinctive 6+ char phrase recur?
            markers = [w for w in re.findall(r"[A-Za-z_][A-Za-z0-9_.\-]{3,}", f)][:6]
            day_hit = sum(1 for m in markers if m in day_text) / max(1, len(markers))
            week_hit = sum(1 for m in markers if m in week_text) / max(1, len(markers))
            rows.append({
                "day": datetime.fromtimestamp(d / 1000, CST).strftime("%Y-%m-%d"),
                "marker_ratio_day": day_hit, "marker_ratio_week": week_hit,
                "sim_day": cosine(v, dv), "sim_week": cosine(v, wv),
                "ctrl_day_max": max(ctrl_d) if ctrl_d else 0.0,
                "ctrl_week_max": max(ctrl_w) if ctrl_w else 0.0,
                "margin_day": cosine(v, dv) - (max(ctrl_d) if ctrl_d else 0.0),
                "margin_week": cosine(v, wv) - (max(ctrl_w) if ctrl_w else 0.0),
            })
        print(f"{rows[-1]['day']}: {len(facts)} facts embedded")

    # Where do the two metrics disagree?
    disagree = []
    for r in rows:
        tok = r["marker_ratio_week"] >= 0.5
        sem = r["margin_week"] >= 0.05
        if tok != sem:
            disagree.append({"day": r["day"], "token_says_kept": tok,
                             "semantic_says_kept": sem,
                             "marker_ratio_week": r["marker_ratio_week"],
                             "margin_week": r["margin_week"]})
    summary = {
        "n_facts": len(rows),
        "n_disagree_week": len(disagree),
        "token_only_kept": sum(1 for x in disagree if x["token_says_kept"]),
        "semantic_only_kept": sum(1 for x in disagree if x["semantic_says_kept"]),
        "mean_margin_day": (sum(r["margin_day"] for r in rows) / len(rows)) if rows else 0.0,
        "mean_margin_week": (sum(r["margin_week"] for r in rows) / len(rows)) if rows else 0.0,
    }
    print()
    print(f"  facts: {summary['n_facts']}")
    print(f"  mean semantic margin  day {summary['mean_margin_day']:+.3f}  "
          f"week {summary['mean_margin_week']:+.3f}")
    print(f"  week-level disagreements between the two metrics: {summary['n_disagree_week']}"
          f"  (token-only kept: {summary['token_only_kept']},"
          f" semantic-only kept: {summary['semantic_only_kept']})")

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump({"model": model, "summary": summary,
                   "disagreements": disagree, "rows": rows}, fh,
                  ensure_ascii=False, indent=1)
    print(f"\nwrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

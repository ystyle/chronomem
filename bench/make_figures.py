#!/usr/bin/env python3
"""
Generate the empirical paper's figures as inline SVG.

Hand-writing SVG in Markdown was a mistake made once: `rx` ended up inside a CSS
rule rather than as an attribute, and during inline-attribute expansion the
`<text>` open tags picked up a spurious self-closing slash. Generating the markup
programmatically and validating it with an XML parser before insertion avoids
both.

Three figures, all from archived results:
  fig1  recall retention by lag, five arms
  fig2  ablation: window size vs the cliff
  fig3  the recursive step: input diversity vs retention

Usage:
    python3 make_figures.py --out ../docs/paper/figures/
    python3 make_figures.py --stdout fig1
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results")

# Palette: distinguishable in print and on screen, and legible in greyscale
# (the solid-vs-dashed distinction carries the signal if colour is lost).
ARMS = [
    ("exact", "#166534", "", "chronomem exact"),
    ("day", "#2563eb", "", "chronomem day"),
    ("week", "#7c3aed", "", "chronomem week"),
    ("flat", "#b45309", "6 4", "flat recency"),
    ("compaction", "#991b1b", "2 3", "one-shot compaction"),
]


def _esc(s: str) -> str:
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def _svg_open(w: int, h: int, label: str) -> list[str]:
    return [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" '
        f'width="100%" role="img" aria-label="{_esc(label)}">',
        '<style>'
        '.ax{stroke:#9aa3ad;stroke-width:1}'
        '.gr{stroke:#e3e7ea;stroke-width:1}'
        '.lb{font-family:system-ui,-apple-system,Segoe UI,sans-serif;'
        'font-size:11px;fill:#4a5766}'
        '.tt{font-family:system-ui,-apple-system,Segoe UI,sans-serif;'
        'font-size:12px;fill:#1f2933;font-weight:600}'
        '.ln{fill:none;stroke-width:2}'
        '</style>',
    ]


def figure_retention(data: dict) -> str:
    """Recall retention across five arms, by lag bucket."""
    W, H = 760, 330
    L, R, T, B = 58, 250, 26, 52
    pw, ph = W - L - R, H - T - B

    buckets = [1, 2, 3, 5, 7, 14]
    labels = {1: "1", 2: "2", 3: "3–4", 5: "5–6", 7: "7–13", 14: "14–29"}
    series = {}
    for key, _c, _d, _n in ARMS:
        src = ("chronomem-summary-week" if key == "week"
               else "chronomem-summary" if key == "day"
               else "chronomem-exact" if key == "exact"
               else "flat-recency" if key == "flat"
               else "one-shot-compaction")
        curve = data["by_backend"][src]["curve"]
        series[key] = {int(k): v["accuracy"] for k, v in curve.items()}

    out = _svg_open(W, H, "recall retention by lag, five arms")
    # gridlines + y axis
    for pct in (0, 25, 50, 75, 100):
        y = T + ph * (1 - pct / 100)
        out.append(f'<line class="gr" x1="{L}" y1="{y:.1f}" x2="{L+pw}" y2="{y:.1f}"/>')
        out.append(f'<text class="lb" x="{L-8}" y="{y+4:.1f}" text-anchor="end">{pct}%</text>')
    out.append(f'<line class="ax" x1="{L}" y1="{T}" x2="{L}" y2="{T+ph}"/>')

    def x_of(i: int) -> float:
        return L + (pw * i / (len(buckets) - 1)) if len(buckets) > 1 else L + pw / 2

    def y_of(a: float) -> float:
        return T + ph * (1 - a)

    for i, b in enumerate(buckets):
        out.append(f'<text class="lb" x="{x_of(i):.1f}" y="{T+ph+18}" '
                   f'text-anchor="middle">{labels[b]}</text>')
    out.append(f'<text class="lb" x="{L+pw/2:.0f}" y="{T+ph+40}" '
               f'text-anchor="middle">days since the fact (bucket)</text>')

    for key, colour, dash, name in ARMS:
        pts = [(x_of(i), y_of(series[key].get(b, 0.0)))
               for i, b in enumerate(buckets)]
        d = "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in pts)
        da = f' stroke-dasharray="{dash}"' if dash else ""
        out.append(f'<path class="ln" d="{d}" stroke="{colour}"{da}/>')
        for x, y in pts:
            out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="3" fill="{colour}"/>')

    # legend
    for i, (key, colour, dash, name) in enumerate(ARMS):
        ly = T + 8 + i * 21
        da = f' stroke-dasharray="{dash}"' if dash else ""
        out.append(f'<line class="ln" x1="{L+pw+18}" y1="{ly}" '
                   f'x2="{L+pw+44}" y2="{ly}" stroke="{colour}"{da}/>')
        out.append(f'<text class="lb" x="{L+pw+50}" y="{ly+4}">{_esc(name)}</text>')

    out.append("</svg>")
    return "\n".join(out)


def figure_ablation(rows: list[dict]) -> str:
    """Window size against the observed cliff."""
    W, H = 460, 300
    L, R, T, B = 58, 24, 26, 52
    pw, ph = W - L - R, H - T - B
    import math
    max_k = max(r["top_k"] for r in rows)
    max_c = 22

    out = _svg_open(W, H, "window size versus observed cliff")
    for c in (0, 5, 10, 15, 20):
        y = T + ph * (1 - c / max_c)
        out.append(f'<line class="gr" x1="{L}" y1="{y:.1f}" x2="{L+pw}" y2="{y:.1f}"/>')
        out.append(f'<text class="lb" x="{L-8}" y="{y+4:.1f}" text-anchor="end">{c}d</text>')
    out.append(f'<line class="ax" x1="{L}" y1="{T}" x2="{L}" y2="{T+ph}"/>')
    out.append(f'<line class="ax" x1="{L}" y1="{T+ph}" x2="{L+pw}" y2="{T+ph}"/>')

    # the identity line "cliff = window / 10 events per day"
    ident = [(L + pw * (math.log10(r["top_k"]) / math.log10(max_k)),
              T + ph * (1 - min(r["predicted_cliff_days"], max_c) / max_c))
             for r in rows]
    d = "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in ident)
    out.append(f'<path class="ln" d="{d}" stroke="#9aa3ad" stroke-dasharray="4 3"/>')
    out.append(f'<text class="lb" x="{ident[-1][0]-4:.0f}" y="{ident[-1][1]-8:.0f}" '
               f'text-anchor="end">predicted (window / 10 events/day)</text>')

    obs = [(L + pw * (math.log10(r["top_k"]) / math.log10(max_k)),
            T + ph * (1 - min(r["observed_cliff_days"], max_c) / max_c))
           for r in rows]
    d = "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in obs)
    out.append(f'<path class="ln" d="{d}" stroke="#166534"/>')
    for (x, y), r in zip(obs, rows):
        out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="3.5" fill="#166534"/>')
        out.append(f'<text class="lb" x="{x:.1f}" y="{T+ph+18}" '
                   f'text-anchor="middle">{r["top_k"]}</text>')
    out.append(f'<text class="lb" x="{L+pw/2:.0f}" y="{T+ph+40}" '
               f'text-anchor="middle">recency window (top_k, log scale)</text>')
    out.append(f'<text class="tt" x="{L}" y="{T-10}">observed cliff</text>')
    out.append("</svg>")
    return "\n".join(out)


def figure_week_step(rows: list[dict]) -> str:
    """Recursive step: input days vs quantity retention and length ratio."""
    import statistics
    by: dict[int, list[dict]] = {}
    for r in rows:
        by.setdefault(r["days_in_week"], []).append(r)

    W, H = 480, 300
    L, R, T, B = 74, 40, 26, 52
    pw, ph = W - L - R, H - T - B
    ks = sorted(by)
    maxk = max(ks)

    out = _svg_open(W, H, "recursive step: input days vs retention")
    for pct in (0, 25, 50, 75, 100):
        y = T + ph * (1 - pct / 100)
        out.append(f'<line class="gr" x1="{L}" y1="{y:.1f}" x2="{L+pw}" y2="{y:.1f}"/>')
        out.append(f'<text class="lb" x="{L-8}" y="{y+4:.1f}" text-anchor="end">{pct}%</text>')
    out.append(f'<line class="ax" x1="{L}" y1="{T}" x2="{L}" y2="{T+ph}"/>')
    out.append(f'<line class="ax" x1="{L}" y1="{T+ph}" x2="{L+pw}" y2="{T+ph}"/>')

    def x_of(k: int) -> float:
        return L + pw * (k - min(ks)) / max(1, (maxk - min(ks)))

    # Only points with at least 2 projects are joined by the line. The 5-day
    # bucket holds a single project whose retention happens to be 97% — drawing
    # it on the curve makes the tail rise, which reads as "more input is better"
    # when it is one observation. Small buckets are plotted as hollow markers
    # beside the curve, with their n labelled, so the trend is not distorted.
    solid, sparse = [], []
    for k in ks:
        vals = [r["numeric"]["rate"] for r in by[k] if r["numeric"]["rate"] is not None]
        if not vals:
            continue
        pt = (x_of(k), T + ph * (1 - statistics.fmean(vals)), len(by[k]))
        (solid if len(by[k]) >= 2 else sparse).append(pt)

    if len(solid) > 1:
        d = "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y, _n in solid)
        out.append(f'<path class="ln" d="{d}" stroke="#b45309"/>')
    for x, y, n in solid:
        out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="3.5" fill="#b45309"/>')
        out.append(f'<text class="lb" x="{x:.1f}" y="{y-9:.1f}" '
                   f'text-anchor="middle">n={n}</text>')
    for x, y, n in sparse:
        out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="3.5" fill="none" '
                   f'stroke="#b45309" stroke-width="1.6"/>')
        out.append(f'<text class="lb" x="{x:.1f}" y="{y-9:.1f}" '
                   f'text-anchor="middle">n={n}*</text>')

    for k in ks:
        out.append(f'<text class="lb" x="{x_of(k):.1f}" y="{T+ph+18}" '
                   f'text-anchor="middle">{k}</text>')
    out.append(f'<text class="lb" x="{L+pw/2:.0f}" y="{T+ph+40}" text-anchor="middle">'
               f'days of input merged into the week summary</text>')
    out.append(f'<text class="tt" x="{L}" y="{T-10}">quantity retention  (* = single project, not joined)</text>')
    out.append("</svg>")
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", help="directory to write fig1.svg … fig3.svg")
    ap.add_argument("--stdout", choices=["fig1", "fig2", "fig3"],
                    help="print one figure to stdout")
    args = ap.parse_args()

    with open(os.path.join(RESULTS, "retention", "five-arm-seed7.json"),
              encoding="utf-8") as fh:
        five = json.load(fh)
    with open(os.path.join(RESULTS, "retention", "ablation.json"),
              encoding="utf-8") as fh:
        abl = json.load(fh)
    with open(os.path.join(RESULTS, "real-corpus", "week-step.json"),
              encoding="utf-8") as fh:
        step = json.load(fh)

    figs = {
        "fig1": figure_retention(five),
        "fig2": figure_ablation(abl["rows"]),
        "fig3": figure_week_step(step["rows"]),
    }

    # Validate before anyone embeds them: a malformed inline SVG renders as a
    # blank box in the PDF and is easy to miss.
    for name, svg in figs.items():
        try:
            ET.fromstring(svg)
        except ET.ParseError as exc:
            print(f"{name}: INVALID XML — {exc}", file=sys.stderr)
            return 1

    if args.stdout:
        print(figs[args.stdout])
        return 0

    if not args.out:
        ap.error("--out or --stdout is required")
    os.makedirs(args.out, exist_ok=True)
    for name, svg in figs.items():
        p = os.path.join(args.out, f"{name}.svg")
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(svg)
        print(f"wrote {p} ({len(svg)} bytes, valid XML)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

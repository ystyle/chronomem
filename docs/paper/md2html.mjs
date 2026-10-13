/**
 * Render a paper's Markdown to a print-ready HTML file.
 *
 * The paper ships as Markdown; the PDF is produced by feeding this HTML to
 * Chrome's `--headless --print-to-pdf`. Layout therefore lives in the CSS below
 * rather than in a LaTeX preamble, which keeps the toolchain to `marked` plus a
 * browser (no pandoc/TeX/typst install).
 *
 * Inline `<figure><svg>` blocks in the Markdown pass through untouched, so
 * diagrams stay in the repository as reviewable text rather than binary assets.
 *
 * Usage:
 *   node md2html.mjs <input.md> <output.html> [--lang en|zh]
 *
 * Then:
 *   google-chrome-stable --headless --disable-gpu --no-sandbox \
 *     --no-pdf-header-footer --virtual-time-budget=8000 \
 *     --print-to-pdf=out.pdf file:///abs/path/out.html
 */

import { readFileSync, writeFileSync } from 'node:fs'
import { marked } from 'marked'

const [, , inPath, outPath, , langArg] = process.argv
if (!inPath || !outPath) {
  console.error('usage: node md2html.mjs <input.md> <output.html> [--lang en|zh]')
  process.exit(2)
}
const lang = langArg === 'zh' ? 'zh' : 'en'

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

const md = readFileSync(inPath, 'utf8')
const titleMatch = md.match(/^#\s+(.+)$/m)
const title = titleMatch ? titleMatch[1].trim() : 'Untitled'

marked.setOptions({ gfm: true, breaks: false })
const body = marked.parse(md)

// A serif face for body text; the Noto CJK families cover the Chinese edition.
const fontStack = lang === 'zh'
  ? `"Noto Serif CJK SC", "Noto Serif CJK TC", "Source Han Serif SC", "Songti SC", serif`
  : `"Latin Modern Roman", "Times New Roman", "Noto Serif", Georgia, serif`
const sansStack = `"Noto Sans CJK SC", "Noto Sans CJK TC", "Helvetica Neue", Arial, sans-serif`

const css = `
@page { size: A4; margin: 20mm 18mm 18mm 18mm; }
* { box-sizing: border-box; }
html { font-size: 10.5pt; }
body {
  font-family: ${fontStack};
  line-height: 1.62;
  color: #111;
  margin: 0;
  text-align: justify;
  hyphens: auto;
}
h1 {
  font-family: ${sansStack};
  font-size: 1.72rem; line-height: 1.3; font-weight: 700;
  margin: 0 0 .5rem; text-align: left; letter-spacing: -.01em;
}
h2 {
  font-family: ${sansStack};
  font-size: 1.18rem; font-weight: 700;
  margin: 1.7rem 0 .55rem; padding-bottom: .2rem;
  border-bottom: 1px solid #d8d8d8;
  page-break-after: avoid;
}
h3 {
  font-family: ${sansStack};
  font-size: 1.02rem; font-weight: 700;
  margin: 1.25rem 0 .4rem; page-break-after: avoid;
}
h4 { font-family: ${sansStack}; font-size: .96rem; margin: 1rem 0 .3rem; page-break-after: avoid; }
p { margin: 0 0 .62rem; orphans: 2; widows: 2; }
a { color: #14427a; text-decoration: none; word-break: break-all; }
strong { font-weight: 700; }
em { font-style: italic; }
code {
  font-family: "DejaVu Sans Mono", "Noto Sans Mono", monospace;
  font-size: .88em; background: #f4f4f6;
  padding: .08em .3em; border-radius: 3px;
}
pre {
  background: #f6f7f9; border: 1px solid #e2e4e8; border-left: 3px solid #9aa4b2;
  border-radius: 4px; padding: .6rem .75rem; overflow-x: auto;
  font-size: .84em; line-height: 1.45; page-break-inside: avoid;
}
pre code { background: none; padding: 0; font-size: 1em; }
/* The author block sits as a paragraph right under the title. */
h1 + p {
  font-family: ${sansStack};
  font-size: .93rem; color: #333;
  margin: .1rem 0 1rem; text-align: left;
  border-bottom: 1px solid #e6e6e6; padding-bottom: .7rem;
}
blockquote {
  margin: .7rem 0; padding: .1rem 0 .1rem .85rem;
  border-left: 2.5px solid #c9ced6; color: #3a3f47;
}
blockquote p { margin: .35rem 0; }
table {
  border-collapse: collapse; width: 100%;
  margin: .7rem 0 1rem; font-size: .88rem;
  page-break-inside: avoid;
}
th, td {
  border: .5px solid #c8ccd2; padding: .3rem .5rem;
  text-align: left; vertical-align: top;
}
th { background: #f2f4f7; font-family: ${sansStack}; font-weight: 700; }
ul, ol { margin: .35rem 0 .8rem; padding-left: 1.5rem; }
li { margin: .18rem 0; }
hr { border: none; border-top: 1px solid #dcdfe4; margin: 1.4rem 0; }
/* A figure never splits across pages, and its caption stays with the drawing. */
figure { margin: 1.1rem 0 1.3rem; page-break-inside: avoid; }
figure svg { display: block; width: 100%; height: auto; }
figcaption {
  font-family: ${sansStack};
  font-size: .82rem; color: #444; line-height: 1.45;
  margin-top: .4rem; text-align: left;
}
h2, h3 { break-after: avoid-page; }
`

const html = `<!DOCTYPE html>
<html lang="${lang}">
<head>
<meta charset="utf-8">
<title>${esc(title)}</title>
<style>${css}</style>
</head>
<body>
${body}
</body>
</html>
`

writeFileSync(outPath, html, 'utf8')
console.log(`wrote ${outPath} (${html.length} bytes)`)

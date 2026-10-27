# Chronomem (忆时塔)

[中文](README.md) | **English**

**Time-layered memory as an MCP service.** Chronomem keeps *temporal memory* (experiences and events) for external tools and serves it back two ways: **structural recall** (materialized time buckets, drill down to raw entries — zero LLM cost) and **semantic summarization** (LLM-distilled window summaries, recursively composable).

> Name: 忆时塔 ("Tower of Remembering Time", memento × time). Package: `chronomem`.
> **Design and rationale live in [`docs/design.md`](docs/design.md)** — the summarization pipeline, the three materialization modes, the storage layout and the full configuration reference.
> This file is scoped to **using** it: build, run, connect, deploy.

## Papers

Two papers accompany this project, both on AiraXiv:

| Paper | What it covers | Version | Review |
|---|---|---|---|
| [**Chronomem (忆时塔): Time-Layered External Memory as an MCP Service for Agent Recall and Summarization**](docs/paper/position-paper.pdf)<br>AiraXiv [`2610.0035`](https://airaxiv.com/papers/view/2610.0035/) | The design: the two-track cost model, recursive summarization, per-type granularity chains | v2 | 6.6/10 |
| [**Empirical Evaluation of Chronomem: Recall Retention, Compression Behaviour, and the Limits of Recursive Summarization**](docs/paper/empirical-paper.pdf)<br>AiraXiv [`2610.0045`](https://airaxiv.com/papers/view/2610.0045/) | The measurements: capacity cliff, recursive-step fidelity governed by input diversity, what survives on real data | v5 | 7.9/10 |

Both have **Chinese and English editions** (English is the submitted version): position [English](docs/paper/position-paper.pdf) / [中文](docs/paper/position-paper.zh.pdf); empirical [English](docs/paper/empirical-paper.pdf) / [中文](docs/paper/empirical-paper.zh.pdf). Markdown sources in [`docs/paper/`](docs/paper/).

Every quantitative claim in the empirical paper resolves to a re-runnable script and an archived result in this repository (see [`bench/results/`](bench/results/)). Several of its findings are counter-intuitive, and they are the ones later design work has to live with:

- **A bounded recency window fails as a cliff, not a decay** — perfect inside the window, zero immediately outside, with the boundary moving as capacity changes. Enlarging the window moves the boundary rather than softening it.
- **What compression has to preserve is the item → value relation** — a compactor keeping the pairing answers 100%, one paraphrasing values away answers 0%, and the two differ by 11 tokens per question. **A coarse level is not a cheaper version of a fine one**: the week summary reads more and answers less.
- **Recursive-step fidelity depends on input diversity, not on the level** — with a single day of input the step usually declines to compress (68% of pairs at ≥0.95x length); with several days it halves the text and loses ~40% of quantities.
- **On real data, evidentiary numbers and causal mechanisms go first while identifiers last** — and reusable rules are the most fragile. If downstream work needs numeric evidence, **instruct the summarizer to keep each value individually** (measured: answerability recovered from 52.4% to 100%, at ~3.4x the summary length).

## Mental model

- **The tower is a hierarchy.** Memory stacks into layers, one materialized granularity per layer, configurable per type: the older, the coarser, the higher. Every layer drills down a reference chain to the raw entries beneath it.
- **A memory type is a series.** Tools define their own types (`worklog`, `proj/decisions`, `tool/errors`); each is an independent store and they do not interfere.
- **Recall vs. summary — two different LLM costs.** Exact drill-down reads raw entries and costs **zero LLM**; semantic recall reads a window summary and **requires that window to have been summarized already** (or `summarize_on_miss` to compute it on the spot).
- **Constant context.** Chronomem only stores and answers. It never pushes content back into a client's context; the client decides what to pull.

## Features

- ✅ User-defined memory types (loose schema: arbitrary JSON payload + tags)
- ✅ **`worklog` type works out of the box** (seeded at startup; disable with `CHRONOLOG_SEED_WORKLOG`)
- ✅ Per-type **granularity chains**, with **calendar-aligned** natural windows (`CHRONOLOG_TIMEZONE`)
- ✅ Structural recall: latest / time-range / tag filter / **keyword content search**, plus **exact drill-down** (zero LLM)
- ✅ Semantic summarization, including **scheduled auto-summaries** and explicit task-phase windows
- ✅ Background structural materialization (zero LLM, idempotent)
- ✅ Streamable HTTP only; many clients share one memory store
- ✅ **Web console built in** (cjxt, dark "time tower" theme) — served on the same port as MCP

## Build and run

Dependencies come from the Cangjie central registry, so a plain clone builds.

```bash
eval "$(cjvs env bash)" && eval "$(cjvs stdx-env bash)"
cjpm build -j 16

# Run (a resident daemon)
CHRONOLOG_DIR=~/.chronolog CHRONOLOG_PORT=8900 \
LLM_BASE_URL=... LLM_API_KEY=... LLM_MODEL=... \
./target/release/bin/chronomem.cli serve
```

> Working on a dependency's source instead? Temporarily swap its line for a path dependency
> (`mcp = { path = "../mcp-cj" }`) — don't commit that.

| Variable | Default | Meaning |
|---|---|---|
| `CHRONOLOG_DIR` | `~/.chronolog` | Storage root (contains `tsdb/`) |
| `CHRONOLOG_ADDR` | `127.0.0.1` | Bind address (local-only by default; use `0.0.0.0` in containers) |
| `CHRONOLOG_PORT` | `8900` | HTTP port — serves both MCP (`/mcp`) and the Web console (`/`) |
| `CHRONOLOG_TIMEZONE` | local zone | Time zone for natural windows (IANA id, e.g. `Asia/Shanghai`) |
| `CHRONOLOG_MATERIALIZE_CRON` | `@every 1m` | Structural materialization cron |
| `CHRONOLOG_SUMMARY_CRON` | `*/10 * * * *` | Auto-summarization cron |
| `CHRONOLOG_SUMMARY_MAX_PER_RUN` | `5` | Max summarization jobs per scheduler tick |
| `CHRONOLOG_SEED_WORKLOG` | `true` | Seed the default `worklog` type at startup |
| `LLM_BASE_URL` | — | OpenAI-compatible endpoint (summarization only) |
| `LLM_API_KEY` | — | API key |
| `LLM_MODEL` | — | Default model |
| `LLM_PROVIDER` | `openai` | `openai` / `anthropic` / `ollama` |

The summarization budget controls (`CHRONOLOG_SUMMARY_CONTEXT_TOKENS`, `_CALL_TOKENS`, `_MAX_CALLS`,
`_MAX_ATTEMPTS`, `_SETTLE`, `_NO_THINK`, …) size the input against the endpoint, chunk when it does not
fit, and bound retries. **They matter when you point the service at your own model** — see
[`docs/design.md` §11](docs/design.md) for the full variable table and
[§7.4](docs/design.md) for the chunking/budget reasoning.

> Without LLM configuration, storage and structural recall work normally; `mem/summarize` returns a clear error.

## Web console (built in, cjxt)

The **Web console** starts with the service ([cjxt](https://ystyle.top/cjxt) server-driven UI, dark "time tower" theme).
It runs in the same process **and on the same port** as MCP: pages, static assets and the WebSocket live at the root
path, MCP at `/mcp`. Pages call the service in-process, so there is no HTTP overhead.

| Variable | Default | Meaning |
|---|---|---|
| `CHRONOLOG_UI_ENABLED` | `true` | Set `false` to run MCP only |

```bash
CHRONOLOG_DIR=~/.chronolog CHRONOLOG_PORT=8900 ./target/release/bin/chronomem.cli serve
# Browser: http://127.0.0.1:8900        (console)
#          http://127.0.0.1:8900/mcp    (MCP endpoint)
```

**Pages**: Overview (stats / type cards / recent entries) · Tower (granularity layers → time buckets → exact drill-down) · Recall (exact / semantic window summary) · Summarize (trigger jobs, list `SummaryRecord`s) · Types (create / detail / truncate / delete guard) · Append (worklog template + live JSON preview).

### Screenshots

> Captured from an isolated instance (separate data dir and port) filled with **synthetic test data**,
> never real memories. Regenerate with `python3 docs/ui/scripts/readme_shots.py`.

**Overview** — scale of types / entries / summaries, with each type card showing its granularity chain and grouping dimension:

![Overview](docs/assets/console-overview.png)

**Tower** — the granularity chain rendered as a tower (older = coarser and higher); click a bucket to drill down. The full tower and today's buckets:

![Tower](docs/assets/console-tower.png)

<details>
<summary>Tower · drilling into raw entries</summary>

On the right: raw entries reached through the reference chain (zero LLM), with an "expand full text" outlet for long content:

![Tower · drill-down](docs/assets/console-tower-drill.png)

</details>

**Recall** — exact recall reads raw entries directly; long outcomes are no longer truncated with nowhere to look, each row offers "expand full text (N bytes)" and "detail · all fields":

![Recall · exact](docs/assets/console-recall.png)

**Summarize** — async window summarization, `SummaryRecord`s rendered as decisions / conclusions / todos / status changes / keywords:

![Summarize](docs/assets/console-summary.png)

**Types** — a type is one independent series; creation lets you pick the granularity chain, destruction is a two-step guard (truncate → drop):

![Types · create](docs/assets/console-types-dialog.png)

**Append** — worklog template form with live JSON payload preview; loose mode, no strict field validation:

![Append](docs/assets/console-append.png)

<details>
<summary>More screenshots (type dropdown / type list)</summary>

The type dropdown under the dark theme (options fully readable, not squeezed into single letters):

![Tower · type dropdown](docs/assets/console-tower-select.png)

Type list: entry count, granularity chain, grouping dimension and auto-summarize state at a glance:

![Types](docs/assets/console-types.png)

</details>

## Releases (binaries / container image)

Prebuilt artifacts are on the [Releases](https://github.com/ystyle/chronomem/releases) page — no Cangjie toolchain needed.

| Artifact | Notes |
|---|---|
| `chronomem_vX.Y.Z_linux_amd64.tar.gz` | Statically linked binary (`--static`, no libcangjie-runtime dependency) |
| `chronomem_vX.Y.Z_public.tar.gz` | Web-console assets; extract **next to the binary** |
| `ghcr.io/ystyle/chronomem:vX.Y.Z` / `:latest` | Container image |

```bash
tar -xzf chronomem_vX.Y.Z_linux_amd64.tar.gz
tar -xzf chronomem_vX.Y.Z_public.tar.gz        # produces ./public
./chronomem                                    # run from the directory that contains public/
```

> **Not published to the Cangjie registry**: this is an application (MCP service, entry point
> `chronomem.cli`), not a library meant to be referenced via `[dependencies]`. Open source
> and package publishing are separate decisions.

### Content search (`mem/query`'s `keyword`)

Find entries by **content** rather than tag. Omitting `keyword` leaves behavior byte-identical
to the pre-feature version.

| Input | Meaning |
|---|---|
| `image` | one term |
| `image error` | space-separated = **all terms must appear** (AND, order-independent) |

- Case-insensitive; AND only (no OR / regex / weighting) — several terms mean "narrow it down".
- Matches the raw payload, JSON not parsed, so field names match too (`cause` finds every entry with that field).
- **No index**: each search scans the whole candidate range. Inside ~10k entries it is unnoticeable;
  on a 100k+ type it takes seconds. Narrow `from`/`to` or add `tag` to cut the scan.

## Docker

> The image **packages a host-built binary**: compile with the host toolchain (`cjpm build`), then `COPY` the result in — nothing is rebuilt inside the image (there is no Rust-style in-image toolchain, and no need for one).
> Base image `archlinux:latest` (matches the host glibc) plus `liburing` (badgercj io_uring), `tzdata` (calendar windows), `ca-certificates` (LLM TLS) and `curl` (healthcheck).

```bash
# 1. Build the binary
eval "$(cjvs env bash)" && eval "$(cjvs stdx-env bash)"
cjpm build -j 16

# 2. Build and run the image
docker build -t chronomem:latest .
docker run -d --name chronomem -p 8900:8900 \
  -e CHRONOLOG_ADDR=0.0.0.0 \
  -v ~/.chronolog:/home/app/.chronolog \
  chronomem:latest
```

A prebuilt image is published to **`ghcr.io/ystyle/chronomem`** by the release workflow (tag `v*`).

**Deployment notes**
- **Create the data directory before first start**, owned by uid 1000 (the in-container `app` user): otherwise Docker creates it as root and the service cannot write.
- Inside a container set `CHRONOLOG_ADDR=0.0.0.0` — Docker port mapping arrives on the container's external IP, so binding `127.0.0.1` is unreachable.
- Put LLM settings in the environment (`LLM_BASE_URL` / `LLM_API_KEY` / `LLM_MODEL`); without them `summarize` reports "LLM not configured" and everything else works.
- The data volume (`~/.chronolog` → `/home/app/.chronolog`) holds the tsdb store and the type registry; recreating the container loses nothing.
- The image sets `STOPSIGNAL SIGTERM` and a `HEALTHCHECK` against `/`. The service flushes memtables on shutdown, so give it time (`stop_grace_period` in Compose).

## Connecting a client

Any MCP client that speaks Streamable HTTP (opencode / Cherry Studio / Inspector / dsh / Claude Desktop):

```jsonc
// opencode.json
{ "mcp": { "chronomem": { "type": "remote", "url": "http://127.0.0.1:8900/mcp" } } }
```

MCP Inspector:

```bash
npx @modelcontextprotocol/inspector --url http://127.0.0.1:8900/mcp
```

## Tool reference

| Tool | Purpose |
|---|---|
| `mem/type_create` | Create a memory type (`name` required; `levels`? granularity chain; `auto_summarize`? background summaries; `summary_levels`? summary granularity; `description`? `schema`? `retention`?) |
| `mem/type_update` | Update a type's mutable config (omitted fields stay; empty string/array clears) |
| `mem/list_types` | List types (name / description / entry count / levels) |
| `mem/type_info` | One type in detail (meta + entry count + bucket count per level) |
| `mem/truncate` | Drop all entries of a type (raw + summaries; TRUNCATE, type kept) |
| `mem/type_delete` | Delete a type (DROP; **guard: both series must be empty** — `mem/truncate` first) |
| `mem/append` | Append an entry (`type` + `payload` required; `tags`? `ts`?) |
| `mem/query` | Structural recall: `from`? `to`? `limit`? `page`? `tag`? `keyword`? (tag syntax below; keyword = content search) |
| `mem/recall` | `mode=exact` drill-down (zero LLM) / `mode=summary` semantic recall; `granularity` must be in the type's levels; `summarize_on_miss`? |
| `mem/buckets` | List materialized buckets at a granularity (discover available windows) |
| `mem/summarize` | **Semantic summarization (async)**: returns a `job_id` immediately, the LLM runs in a background thread and **blocks no other request**; `from`/`to` (task phase) or `granularity`; `instructions`? `store`? (default true) |
| `mem/summarize_status` | Poll a summarization job (`job_id`; pending/running/done/failed) |
| `mem/summaries` | List summary records (newest first) |

## Example: a work log

> The `worklog` type needs no setup — the service creates it at startup (`levels: [day, week]` + `auto_summarize: true`).

```text
# Jot an entry while working (once a day, or several times an hour)
mem/append { type: "worklog", payload: { "task": "Split the Chronomem design", "status": "done", "outcome": "..." }, tags: { "proj": "chronomem" } }

# Auto-summarization handles closed day/week windows (checked every */10 * * * *)
# End of a task phase → summarize that explicit window (async: returns immediately)
mem/summarize { type: "worklog", from: <task start>, to: <task end>, instructions: "Extract decisions and follow-ups" }
mem/summarize_status { job_id: <id returned by mem/summarize> }

# Recall
mem/query  { type: "worklog", tag: "proj=chronomem" }                  # structural (zero LLM)
mem/recall { type: "worklog", granularity: "day" }                     # exact drill-down
mem/recall { type: "worklog", granularity: "day", mode: "summary" }    # semantic recall
```

## Session activity capture (`dsh-mem-bridge/`)

[`dsh-mem-bridge/`](dsh-mem-bridge/README.md) is a dsh host plugin that records agent-session
activity into a Chronomem type (`dsh/activity`) automatically — zero-LLM structure first, plus
pre-distilled turn and compaction summaries. It is the source of the activity corpus reported in
the position paper (§6). It is a Node package (`cd dsh-mem-bridge && npm test`) and is not part of
`cjpm build`.

## Tests

```bash
cjpm test -j 16 --no-progress
```

Covers: Timeline bucket chains / drill-down / validation, the type registry and its persistence, the Summarizer (fake provider), every handler, and a full HTTP end-to-end path.

## Dependencies

| Dependency | Role |
|---|---|
| `mcp` (2.3.15) | MCP framework (streamable HTTP) |
| `tsdb` (0.3.4) | Time-series store (series + materialized buckets + drill-down) |
| `llm_api` (1.4.1) | Thin LLM REST layer (OpenAI / Anthropic / Ollama) |
| `cron` (1.0.1) | Scheduling (structural materialization + auto-summarization) |
| `cjxt` (1.1.1) | Server-driven Web UI |
| `jsonvalue` | Tool arguments / dynamic fields |

## License

MIT

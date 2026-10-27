# Chronomem (忆时塔)

[中文](README.md) | **English**

**Time-layered memory as an MCP service.** It keeps *temporal memory* (experiences and events) for external tools and gives it back either by **structural recall** (drill down to raw entries — zero LLM) or as **semantic summaries** (LLM-distilled windows, recursively composable).

> Name: 忆时塔 ("Tower of Remembering Time", memento × time). Package: `chronomem`.
> Tower = layers: memory stacks over time, one granularity per layer, coarser and higher as it ages,
> with a reference chain back down to the raw entries when you need detail.
> Full design in [`docs/design.md`](docs/design.md).

## Features

- **User-defined memory types** — one independent series each (`worklog`, `proj/decisions`, …), arbitrary JSON + tags
- **Two recall tiers**, at different costs:
  - **exact drill-down** (`mem/recall mode=exact` / `mem/query`) → raw entries, lossless, **zero LLM**
  - **semantic recall** (`mode=summary`) → period summary, **costs LLM**, requires that window already summarized
- **Per-type granularity chains** — `10min → 30min → 1h → day → week`, customizable per type; day/week align to the **local calendar**, not epoch
- **Retrieval**: time range / multi-condition tags (AND + IN) / **keyword content search**, paginated
- **Semantic summarization** → structured digest (decisions / conclusions / todos / status changes / keywords), **recursively summarizable**
- **Background work**: structural materialization (zero LLM, idempotent) + scheduled auto-summaries (opt-in per type)
- **Constant context**: it only stores and queries, and **never pushes content back into your context** on its own
- Streamable HTTP only; many clients share one store; the built-in web console shares the MCP port

## Examples

### Work log (works out of the box)

The `worklog` type is seeded at startup (`levels: [day, week]` + auto-summaries); no type creation needed.

```text
# record as you go
mem/append { type: "worklog", payload: { "task": "split the design", "status": "done" }, tags: { "proj": "chronomem" } }

# end of a task phase → summarize an arbitrary window (async, returns job_id immediately)
mem/summarize { type: "worklog", from: <start>, to: <end>, instructions: "extract decisions and todos" }

# recall
mem/query  { type: "worklog", tag: "proj=chronomem" }         # by tag (indexed, fast)
mem/query  { type: "worklog", keyword: "nftables" }           # by content (no index, see below)
mem/recall { type: "worklog", granularity: "day", mode: "summary" }  # that day's digest
```

### Let dsh record sessions for you (`dsh-mem-bridge`)

[dsh](https://github.com/deepseek-ai/dsh) users can install the bundled host plugin, which **automatically**
writes session activity into the tower — no hand-written `mem/append`, and "how did I solve that last week"
becomes answerable afterwards.

```bash
dsh plugin --profile web add dsh-mem-bridge    # restart that profile's dsh afterwards
```

By default it records session lifecycle, turns, compactions, goal state machine, subagent milestones and
errors (into `dsh/activity`). Put a workspace into **full-context mode** and it also records each real user
message, assistant reply and tool call, one entry at a time (into a separate `dsh/chat` type; tool calls
configurable as `none` / `names` / `full`):

```text
# example config (web UI "Plugins" panel, or the profile config)
fullContextWorkspaces:
  - path: ~/notes      # chat / writing workspaces
    level: names       # record tool names only; use none to skip tools
```

> **Off by default**: with no workspace configured, behaviour is identical to not having the plugin at all —
> nothing is written. Details in [`dsh-mem-bridge/README.md`](dsh-mem-bridge/README.md).

## Install

### Docker (recommended)

```bash
docker run -d --name chronomem -p 8900:8900 \
  -e CHRONOLOG_ADDR=0.0.0.0 \
  -v ~/chronolog:/home/app/.chronolog \
  ghcr.io/ystyle/chronomem:latest
```

> ⚠️ Create the data directory **first and chown it to 1000:1000** (the in-container `app` user), otherwise
> Docker creates it as root and the service cannot write:
> `mkdir -p ~/chronolog && sudo chown -R 1000:1000 ~/chronolog`
>
> ⚠️ Inside a container you must set `CHRONOLOG_ADDR=0.0.0.0` — port mapping arrives on the container's
> external IP, so binding `127.0.0.1` is unreachable.

### Binary

Into `~/.local/bin`:

```bash
VERSION=v0.1.0
curl -fsSL "https://github.com/ystyle/chronomem/releases/download/${VERSION}/chronomem_${VERSION}_linux_amd64.tar.gz" \
  | tar -xz -C /tmp && install -m 755 /tmp/chronomem ~/.local/bin/chronomem

chronomem        # serves web console + MCP on one port; configured by env, not by arguments
```

> A single file is enough: **the web console's styles are embedded into the binary at compile time**, so no
> extra `public/` directory is needed. Requires `liburing` (`apt install liburing2` / `pacman -S liburing`);
> everything else is statically linked.

### From source

Needs the Cangjie toolchain (`cjpm`; version in `cjpm.toml`'s `cjc-version`):

```bash
eval "$(cjvs env bash)" && eval "$(cjvs stdx-env bash)"
cjpm build -j 16
CHRONOLOG_DIR=~/.chronolog ./target/release/bin/chronomem.cli
```

## Environment variables

### Service

| Variable | Default | Notes |
|---|---|---|
| `CHRONOLOG_DIR` | `~/.chronolog` | Storage root (tsdb store + type registry) |
| `CHRONOLOG_ADDR` | `127.0.0.1` | Bind address; **`0.0.0.0` required in containers** |
| `CHRONOLOG_PORT` | `8900` | Port (web console and MCP share it) |
| `CHRONOLOG_TIMEZONE` | local zone | Timezone for natural windows (`Asia/Shanghai`); sets day/week boundaries |
| `CHRONOLOG_UI_ENABLED` | `true` | `false` serves MCP only, no web console |
| `CHRONOLOG_SEED_WORKLOG` | `true` | Seed the default `worklog` type at startup |

### Background jobs

| Variable | Default | Notes |
|---|---|---|
| `CHRONOLOG_MATERIALIZE_CRON` | `@every 1m` | Structural materialization (zero LLM, idempotent) |
| `CHRONOLOG_SUMMARY_CRON` | `*/10 * * * *` | Auto-summary sweep |
| `CHRONOLOG_SUMMARY_MAX_PER_RUN` | `5` | Windows summarized per sweep |
| `CHRONOLOG_SUMMARY_SETTLE` | `600000` | Grace period after a window closes (ms, for late entries) |

### LLM (summarization only)

Everything works without it: store, query and exact recall are unaffected; only `mem/summarize` reports
"LLM not configured".

| Variable | Default | Notes |
|---|---|---|
| `LLM_BASE_URL` | — | OpenAI-compatible endpoint |
| `LLM_API_KEY` | — | API key |
| `LLM_MODEL` | — | Model name |
| `LLM_PROVIDER` | `openai` | `openai` / `anthropic` / `ollama` |
| `CHRONOLOG_SUMMARY_CONTEXT_TOKENS` | `32768` | **Context the endpoint allocates for that model.** Used to budget the input: direct if it fits, otherwise chunk on entry boundaries + aggregate. **Must be updated when you switch models**, or you hit `exceeds the available context size` |
| `CHRONOLOG_SUMMARY_MAX_TOKENS` | `4096` | Max output per summary |
| `CHRONOLOG_SUMMARY_CALL_TOKENS` | `40000` | **Per-call** input cap. A big context ≠ one huge call: measured 4b prefill ~317 tok/s, so a 68K-token chunk hits the 300 s read timeout |
| `CHRONOLOG_SUMMARY_NO_THINK` | `true` | Passes `enable_thinking=false` to skip reasoning. **Only works on vLLM / llama.cpp / SGLang**; set `false` for strict cloud OpenAI APIs |
| `CHRONOLOG_SUMMARY_MAX_ATTEMPTS` | `3` | Stop retrying a window after N consecutive failures (avoids burning tokens every 10 min) |

Other tuning knobs (`SAFETY_TOKENS` / `BYTES_PER_TOKEN` / `MAX_CALLS` / `READ_TIMEOUT`) are in `src/mcp/config.cj`.

## Web console

Built in and started with the service, sharing the process and port with MCP: the console owns the root
path, MCP is at `/mcp`. Pages call the service directly (no HTTP hop).

Open `http://127.0.0.1:8900`.

| Page | Purpose |
|---|---|
| **Overview** | Type / entry / summary counts, cards with granularity chains and grouping dims |
| **Tower** | Layered granularity view → click a time bucket → drill to raw entries |
| **Recall** | Exact recall (raw entries) / semantic recall (window digests) |
| **Summaries** | Trigger background jobs; structured SummaryRecord view |
| **Types** | Create / inspect / truncate / delete (two-step guard) |
| **Append** | worklog template form + live JSON preview |

**Overview** (test data, not real memories) — scale and type cards:

![Overview](docs/assets/console-overview.png)

**Tower** — coarser and higher as it ages; click a bucket to drill down:

![Tower](docs/assets/console-tower.png)

**Recall** — exact recall of raw entries, with "expand full text" and "details · all fields" for long content:

![Recall](docs/assets/console-recall.png)

**Summaries** — structured as decisions / conclusions / todos / status changes / keywords:

![Summaries](docs/assets/console-summary.png)

<details>
<summary>More screenshots</summary>

Tower drill-down to raw entries:

![Tower drill-down](docs/assets/console-tower-drill.png)

Memory types (entry counts / granularity chains / grouping dims / auto-summary state):

![Types](docs/assets/console-types.png)

Creating a type picks its granularity chain (**immutable once created**) and grouping dims:

![Types · create](docs/assets/console-types-dialog.png)

Type dropdown adapted for the dark theme (options stay fully readable, not squeezed to one letter):

![Tower · type dropdown](docs/assets/console-tower-select.png)

Append — worklog template form plus a live payload preview; the loose schema does not enforce fields:

![Append](docs/assets/console-append.png)

</details>

## Tools

| Tool | Purpose |
|---|---|
| `mem/type_create` | Create a type (`name` required; `levels`? chain; `auto_summarize`?; `retention`?) |
| `mem/type_update` | Update type config (omitted fields unchanged; `levels` **cannot change**) |
| `mem/list_types` | List types |
| `mem/type_info` | One type in detail (meta + entry count + bucket count per level) |
| `mem/append` | Append an entry (`type` + `payload` required; `tags`? `ts`?) |
| `mem/query` | Structural recall: `from`? `to`? `limit`? `page`? `tag`? `keyword`? |
| `mem/recall` | `mode=exact` drill-down / `mode=summary` semantic recall; `granularity` must be in the type's levels |
| `mem/buckets` | List materialized buckets at a granularity |
| `mem/summarize` | **Async**: returns `job_id` immediately, the LLM runs in the background |
| `mem/summarize_status` | Poll a summarization job |
| `mem/summaries` | List summary records (newest first) |
| `mem/truncate` | Drop all entries of a type (type kept) |
| `mem/type_delete` | Delete a type (**guard**: both series must be empty) |

### `tag` syntax

| Input | Meaning |
|---|---|
| `proj=chronomem` | equality |
| `proj=chronomem role=user` | space = **AND** |
| `status=todo,done` | comma = multi-value **IN** for one tag |

Conditions are always AND; there is no OR operator (use multi-value IN for that).
**Syntax errors are always reported** — silently degrading to "no filter" would turn "one project" into
"everything" without the caller noticing.

### `keyword` content search

Omitting `keyword` disables it, and behaviour is then **byte-identical** to the version before it existed.

| Input | Meaning |
|---|---|
| `image` | one term |
| `image error` | space = **all terms must appear** (AND, order-independent) |

Case-insensitive; AND only (several terms mean "narrow it down", not "either counts"); matches the raw
payload without parsing JSON.

> **Cost**: content conditions are **not indexed**, so every search scans the whole candidate range.
> Unnoticeable within ~10k entries; seconds on a 100k+ type. Narrowing `from`/`to` or adding `tag` cuts the
> scan substantially. Millisecond search on big types would need an inverted or vector index.

## Known limits

- Content search is unindexed (above); `tag` is indexed
- `levels` is **immutable after creation** — the materialized chain is irreversible, so choose up front
- Semantic recall needs that window **already summarized**: day/week windows only close at midnight, so
  "today" and "this week" digests are necessarily empty
- Without an LLM, only `mem/summarize` is unavailable; everything else works

## Papers

Two papers accompany this project, both on AiraXiv:

| Paper | What it covers | Review |
|---|---|---|
| [Chronomem: time-layered external memory as an MCP service](docs/paper/position-paper.pdf)<br>AiraXiv [`2610.0035`](https://airaxiv.com/papers/view/2610.0035/) | Design: cost model of the two recall tiers, recursive summarization, per-type chains | 6.6/10 |
| [An empirical evaluation of Chronomem](docs/paper/empirical-paper.pdf)<br>AiraXiv [`2610.0045`](https://airaxiv.com/papers/view/2610.0045/) | Evidence: capacity cliff, recursive fidelity, what survives on real corpora | 7.9/10 |

Both are available in English and Chinese (Markdown sources in [`docs/paper/`](docs/paper/)).
Every quantitative claim traces to runnable scripts and archived results in this repo ([`bench/results/`](bench/results/)).

A few **counter-intuitive** findings that later design has to respect:

- **A bounded recency window fails as a cliff, not a decay** — perfect inside, zero outside; enlarging the
  window moves the boundary, it does not soften it
- **The load-bearing part of compression is the entry → value mapping** — a compressor that keeps the pairs
  answers 100%, one that paraphrases values answers 0%, at 11 tokens difference per question. **Coarse layers
  are not a cheaper version of fine ones**
- **Recursive fidelity depends on input diversity, not on level** — single-day input often refuses to compress
  (68% length ratio); multi-day input compresses (0.54x) and drops ~40% of the item count
- **On real corpora, evidential numbers go first, then causal mechanisms; identifiers survive longest** — and
  reusable rules are the most fragile. If downstream needs the numbers, instruct the summarizer to preserve
  values entry by entry (measured: recoverability 52.4% → 100%, at ~3.4× summary length)

## Dependencies

| Dependency | Purpose |
|---|---|
| [`mcp`](../mcp-cj) | MCP framework (streamable HTTP) |
| [`tsdb`](../tsdb-cj) | Time-series store (series + materialized buckets + drillDown) |
| [`llm_api`](../llm_api) | Thin LLM REST client (OpenAI / Anthropic / Ollama) |
| [`cron`](../cron-cj) | Scheduling (materialization + auto-summaries) |
| [`cjxt`](../cjxt) | Server-driven UI (the built-in web console) |
| `jsonvalue` | Tool arguments / dynamic fields |

> **Not published to the Cangjie registry**: this is an application (an MCP service, entry point
> `chronomem.cli`), not a library meant for `[dependencies]`. Open source and package publishing are two
> separate decisions.

## License

MIT

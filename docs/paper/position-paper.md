# Chronomem (忆时塔): Time-Layered External Memory as an MCP Service for Agent Recall and Summarization

> **Status**: Position / design paper — first draft. No empirical evaluation yet.
> **Companion**: implementation at `https://github.com/ystyle/chronomem` (WIP); full design spec at `docs/design.md`.
> **Author responsibility**: This draft was produced with the assistance of an AI writing tool. The author(s) have reviewed and take full responsibility for every claim, and will verify all citations and factual statements before submission (required by arXiv policy).

---

## Abstract

Long-horizon agents need to remember what happened over weeks and months, yet today's external memory systems either store flat recent history or perform destructive one-shot compaction that discards the detail needed for evidence and reasoning. We present **Chronomem (忆时塔, "Tower of Remembering Time")**, a time-layered external memory service exposed through the Model Context Protocol (MCP). Inspired by how financial systems materialize quarterly reports from raw ledgers, Chronomem organizes episodic records into a hierarchy of time windows—from ten minutes up to a week—where each level is a materialized snapshot that references finer levels and can be drilled down to original records. Its central design principle is the separation of two kinds of recall with different costs: **exact recall**, which navigates reference chains to raw records and costs no LLM tokens, and **semantic recall**, which reads LLM-generated summaries and is the form that truly compresses coarse windows. Summary records are themselves append-only temporal entries, so summaries can be recursively summarized, realizing progressive, non-destructive compression. Memory types are user-defined with per-type granularity chains, so high-frequency channels (chat, tool calls) keep minute-level granularity while sparse channels (work logs) converge to day/week. We position the design, discuss open problems (semantic drift, token-budgeted trigger strategies, privacy), and outline an evaluation plan; empirical results are forthcoming.

---

## 1. Introduction

Agents operating over long horizons—iterating on a codebase, writing a thesis, maintaining a project over months—face a fundamental limitation: their context window is bounded, while the events worth remembering are unbounded. Existing approaches fall into two camps with opposite failure modes:

- **Flat external memory** (store everything, retrieve by recency or similarity) preserves detail but provides no compression: after months, no level of the system tells you "what happened, in summary," short of reading everything.
- **One-shot compaction** (periodically compress the whole conversation into a single report) destroys the evidence: decisions are remembered, but *why* and *how* — the raw events — are gone, and re-deriving them is impossible.

Chronomem is designed to occupy the middle ground, which we call **time-layered memory**: organize episodic records into a materialized hierarchy of time windows, where each layer is both (a) a *navigation* structure referencing finer layers down to the raw records, and (b) optionally a *semantic* summary readable at a glance. This mirrors how financial accounting materializes quarterly reports from a raw ledger: the ledger is never deleted, the reports are recomputed progressively, and each report can be audited back to the underlying entries.

We expose Chronomem as an **MCP (Model Context Protocol) service**—a single daemon that any MCP-capable client (opencode, Cherry Studio, custom agents) can attach to. Memory as a *protocol* rather than a private library is, we argue, a systems contribution in itself: it lets heterogeneous tools share one memory substrate without code coupling.

This paper is a **position and design** paper. We motivate the design from a cognitive-science analogy (memory consolidation), relate it to concurrent work in LLM memory systems, state the dual-track cost model that distinguishes our approach, and lay out the open problems we intend to address empirically.

## 2. Background and Related Work

**Memory consolidation in cognitive science.** The idea that recent detailed memory is progressively reorganized into coarser, more durable forms over time is a well-established account of human memory (consolidation; sleep-based replay). Our "分季财报式" (quarterly-report) materialization is an engineering analogue: fresh records are kept at fine granularity, and coarser summaries are progressively materialized without deleting the fine layers. We cite this only as inspiration; we make no claims about biological fidelity.

**Time-series databases and rollups.** Layered time windows with materialized aggregates are standard in time-series databases (rollups / continuous aggregation / downsampling, e.g., TimescaleDB continuous aggregates, Prometheus downsampling). Chronomem reuses this machinery (built on the `tsdb` library) but extends it in a direction databases do not: the coarse layers are not only numeric aggregates but **LLM-generated semantic summaries** of arbitrary JSON events.

**LLM memory systems.** A rapidly growing line of work addresses long-term memory for LLM agents: MemGPT [Packer et al.] introduces hierarchical context management and a memory hierarchy; Generative Agents [Park et al.] couple a memory stream with retrieval and reflection; A-MEM [arXiv:2502.12110] and Mem0 [arXiv:2504.19413] develop agentic/organized memory; **HiMem** [arXiv:2601.06377] proposes hierarchical long-term memory for long-horizon agents; **RaMem** [arXiv:2606.22844] studies contextual reinstatement; **AriadneMem** [arXiv:2603.03290] threads lifelong memory for agents. Our work differs in emphasis: (i) we separate *exact* (zero-token, reference-chain) recall from *semantic* (LLM, compressed) recall as an explicit cost model; (ii) summaries are first-class append-only temporal entries enabling recursive summarization; and (iii) we standardize the whole substrate behind an MCP interface.

**Thematic vs. temporal memory.** "LLM wiki" systems (e.g., LLM WIKI; *Beyond RAG: LLM Wikis as Living Semantic Memory* [Zenodo 20078453]) organize knowledge by topic/semantic entry—thematic memory, analogous to a Wikipedia. Chronomem organizes by time—temporal memory, analogous to a ledger. They are complementary: a time log can precipitate thematic entries, and a thematic entry can trace back to time evidence. We make this contrast explicit because we believe many "memory" systems conflate the two axes, and the choice of axis should follow the use case (a thesis is a process—temporal; a reference manual is a body of knowledge—thematic).

**Model Context Protocol.** MCP (modelcontextprotocol.io) standardizes tools, resources, and prompts between clients and servers. Chronomem's contribution here is to treat *memory* as a first-class MCP capability through a `mem/*` toolset, so any MCP client can adopt a shared, evolving memory without integrating a proprietary SDK. (Memory is currently exposed as tools only; resources and prompts are natural later extensions of the same substrate.)

## 3. Design Overview

Chronomem is a standalone daemon serving a single streamable-HTTP MCP endpoint. Storage is a single time-series database (`tsdb`); one series per memory type. The design has five pillars.

**P1 — Memory types are user-defined.** A *type* is a named series with an optional description and schema (for documentation and LLM prompting; not enforced), optional retention, and a *granularity chain* (below). Clients create types such as `work/chat`, `paper/decisions`, `tool/errors`. Type names are whitelisted (`[A-Za-z0-9_/-]`) to prevent path traversal.

**P2 — Per-type granularity chains.** Each type declares its own materialization levels, drawn from {10min, 30min, 1h, 3h, day, week, month}, defaulting to 10min→30min→1h→day→week. High-frequency channels keep minute-level levels for *same-day exact recall*; sparse channels (e.g., a work log with one entry a day) use day→week and avoid building mostly-empty fine buckets. Week is the default semantic-summary ceiling: a full year of weekly summaries is only ~52 records, cheap to load, and whole-year recall is rarely needed.

**P3 — Materialization modes.** A tower layer can in principle be materialized in three ways, with different costs. The current implementation covers the first two; the third is a planned extension for which the underlying store already provides the aggregation primitives.

| Mode | Content of a layer | Supports | LLM cost | Status |
|---|---|---|---|---|
| Reference chain (default, events) | `PointRef`/`BucketRef` to finer layers | exact drill-down | none | implemented |
| Semantic summary (optional) | LLM `SummaryRecord` | semantic recall | yes | implemented |
| Numeric aggregation (metrics) | count/avg/min/max JSON | overview + drill-down | none | planned |

**P4 — Dual-track recall.** Two read operations with an explicit cost difference:
- `mem/recall mode=exact`: navigate the reference chain to the *raw entries*—lossless, zero LLM tokens, but returns raw volume (reference chains *navigate*, they do not *compress*).
- `mem/recall mode=summary`: return the *semantic summary* of a window—this is the form that genuinely compresses coarse windows, and it is *dependent on a summary having been generated* (previously via `mem/summarize`, or computed on demand when `summarize_on_miss=true`).

**P5 — Summaries are first-class temporal records.** `mem/summarize` reads a window (by granularity+anchor, or by explicit `from`/`to` for irregular "task-phase" windows), asks an LLM to produce a structured summary (anchors: decisions / conclusions / todos / state changes / keywords), and appends a `SummaryRecord {ts, windowFrom, windowTo, model, refs, text}` to the type's `.summary` series. Because summaries are themselves temporal entries, they can be re-summarized: raw → 10min summary → 1h summary → day summary is the semantic analogue of the structural tower, giving **recursive, non-destructive compression**. A `recompute` flag forces re-derivation from raw entries to control semantic drift.

## 4. The Dual-Track Cost Model

Our central conceptual claim is that *recall* must not be treated as a single operation. We distinguish:

- **Exact recall** = zero-token navigation. It is reliable and lossless, but its information content is the raw volume; a coarse-layer exact recall returns everything, so it provides no compression benefit. This is *navigation*, not *summary*.
- **Semantic recall** = reading a summary. It is the only form that truly satisfies "the coarser the window, the smaller the answer." But it has a strict *precondition*: the summary must exist (generated earlier, or generated now at LLM cost). Hence "recall is zero-LLM" holds **only for exact recall**; coarse-grained overview recall is inherently summary-dependent.

This distinction, trivial in retrospect, has concrete consequences that we argue prior systems blur:
1. **Trigger strategy.** Structural materialization (reference chains, aggregates) is a minute-level job that costs no tokens. Semantic summarization is the opposite: an unguarded scheduler would silently burn tokens on empty or low-value windows, and would keep retrying a window that cannot succeed. Chronomem therefore makes it **per-type opt-in** (new types default to off) and, once enabled, bounds it with five mechanisms: (a) only the most recent *closed* window is summarized, after a settle delay, so a window is never summarized while still being written; (b) summarization is idempotent per window and per group, and a successful run clears prior retry state; (c) empty windows cost nothing and are skipped; (d) repeated failures back off and, after a bounded number of attempts, are recorded as abandoned instead of being retried forever every ten minutes; and (e) each scheduler run is capped, so a backlog cannot become an unbounded burst. The built-in `worklog` type ships with this enabled—one summary per closed day per project—while arbitrary new types default to off, and the semantic-summary "miss" path on recall remains explicit (`summarize_on_miss`).
2. **Semantic drift.** Recursive summarization of summaries is cheap but drifts; re-deriving from raw is faithful but expensive. Exposing both, with an explicit `recompute`, turns a silent quality problem into a caller-controlled trade-off.
3. **Context-hygiene.** The service only stores and retrieves; it never pushes content back into a client's context. Clients decide whether and how much recall to inject, preserving a constant-context discipline.

## 5. Open Problems

- **Semantic drift quantification.** How quickly does a chain of summaries diverge from the underlying events, and when is `recompute` worth its tokens? We plan to measure information retention along the chain with a fixed set of probe questions.
- **Token-budgeted triggering.** Given a token budget, when should summaries be computed proactively (e.g., end-of-hour/end-of-week) versus lazily on recall? This is an optimization problem over {window, value, cost}.
- **Retention and privacy.** MVP stores payloads in full with no privacy tiers; type-level privacy/encryption is future work, motivated by the observation that memory becomes *more* sensitive as it grows.
- **Evaluation methodology.** Agent-memory evaluation is immature. We propose: fixed long-horizon task suites, query sets with ground-truth answers, and metrics {recall precision/recall, token cost, latency} against baselines {flat recency memory, one-shot compaction, a MemGPT-style memory hierarchy}. One lesson from operating our own deployment is that **materialized-view consistency deserves to be a metric rather than an assumption**: a layered store can return a stale window (entries written after that window's last materialization are simply missing) or a neighboring window's records altogether, while the returned evidence looks entirely self-consistent and carries no error signal. Evaluations of hierarchical memory should therefore include an explicit consistency check between each coarse view and the raw records it claims to cover.

## 6. Evaluation Plan (Forthcoming)

Empirical results are out of scope for this position paper and will appear in a follow-up. Planned studies: (i) a controlled long-horizon agent task (e.g., incremental project maintenance across simulated weeks) comparing Chronomem against flat memory and one-shot compaction on recall accuracy and token cost; (ii) a semantic-drift study along the summary chain; (iii) a qualitative study of the work-log use case (day/week granularity with task-phase summaries) by the authors. The authors have been running a single-user deployment continuously since August 2026, accumulating a few hundred structured work-log records, several hundred agent-activity records, and dozens of recursively generated day- and week-level summaries; this corpus will serve as the material for (iii) and will supply realistic window-size and compression-ratio distributions for calibrating (i) and (ii).

## 7. Conclusion

We presented Chronomem, a time-layered external memory service over MCP, whose contributions are: (1) a dual-track recall model that separates zero-token exact recall from summary-dependent semantic recall; (2) summaries as first-class append-only temporal records enabling recursive, non-destructive compression; (3) per-type granularity chains adapting to the frequency distribution of each memory channel; and (4) memory as a standardized MCP capability shared across tools. The idea is neither a claim of biological fidelity nor of algorithmic novelty in any single component—each is borrowed from databases, consolidation theory, or LLM-memory systems—but the *combination*, and the honest cost accounting between navigation and compression, is the contribution we put forward for discussion and future empirical validation.

## References (to be verified by the author before submission)

1. Packer, C., et al. *MemGPT: Towards LLMs as Operating Systems.* arXiv:2310.08560.
2. Park, J. S., et al. *Generative Agents: Interactive Simulacra of Human Behavior.* UIST 2023 / arXiv:2304.03442.
3. *HiMem: Hierarchical Long-Term Memory for LLM Long-Horizon Agents.* arXiv:2601.06377.
4. *RaMem: Contextual Reinstatement for Long-term Agentic Memory.* arXiv:2606.22844.
5. *AriadneMem: Threading the Maze of Lifelong Memory for LLM Agents.* arXiv:2603.03290.
6. *Beyond RAG: LLM Wikis as Living Semantic Memory: Patterns, Empirical Findings, and Open Problems.* Zenodo: 20078453.
7. *Memory as Metabolism: A Design for Companion Knowledge Systems.* Zenodo: 19501652.
8. Model Context Protocol specification. https://modelcontextprotocol.io
9. Xu, W., et al. *A-MEM: Agentic Memory for LLM Agents.* arXiv:2502.12110.
10. Chhikara, P., et al. *Mem0: Building Production-Ready AI Agents with Scalable Long-Term Memory.* arXiv:2504.19413.
11. Letta (formerly MemGPT): stateful agents with long-term memory. https://github.com/letta-ai/letta
12. (to add) LLM WIKI knowledge-graph paper; any additional baselines cited in §6.

## AI-Use Disclosure

This document was drafted with the assistance of an AI writing tool. The author(s) have reviewed the content, take full responsibility for its accuracy, and will verify every factual claim and bibliographic reference before submission. No AI is listed as an author.

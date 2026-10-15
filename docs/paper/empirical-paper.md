# Empirical Evaluation of Chronomem: Recall Retention, Compression Behaviour, and the Limits of Recursive Summarization

**YSTYLE**¹  ·  ORCID: [0009-0009-6929-0070](https://orcid.org/0009-0009-6929-0070)  ·  lxy5266@live.com\
**DeepSeek V4.1 Flash**²  ·  AI co-author

¹ *Empirical companion to the position paper (`arXiv`/AiraXiv 2610.0035). Implementation, evaluation harness and raw result archives: `https://atomgit.com/ystyle/chronomem`.*
² *AI co-author, as credited on the AiraXiv preprint. See the AI-use disclosure at the end.*

---

## Abstract

The position paper for Chronomem (忆时塔) specified an evaluation plan and reported no measurements. This paper carries it out. We evaluate a time-layered external memory service — which separates **exact recall** (reference-chain navigation to raw records, no LLM call) from **semantic recall** (reading LLM-generated window summaries) — along three axes: how recall degrades with the age of the fact, how much information the recursive summarization chain preserves, and what the system actually retained over two months of real use.

Three findings. **(1) The recency baseline's failure is structural, not gradual.** A bounded recency window answers perfectly at a one-day lag and then drops to zero, and an ablation over six window sizes shows the cliff tracks capacity (20 items → 1 day; 200 items → 7 days). One-shot compaction scores zero at every lag, including the most recent. Layered exact recall holds 100% across the full 14-day span, with zero variance across seeds. A coarse-summary arm was added after we noticed that the original comparison never exercised the layer the architecture is named for; its results are reported separately (§3.4).

**(2) The recursive step's fidelity depends on input diversity, not on the level.** Measuring the step correctly — same project, same 7-day window — shows that when a project has only one day of summaries in the week, the week summary is *byte-identical* to its input (measured similarity 1.0000 across 755–1112-character texts): 90% token retention with a 0.94x length ratio, i.e. no compression at all. With two or more days of input the step actually compresses (0.53x) and retention falls to 58% for quantities, 48% for causal connectives. Aggregated naively, the single-day cases inflate fidelity from 58% to 81%.

**(3) Over two months of real use, what survives is names, not numbers.** A blind recall test — an agent allowed to consult only the memory service, never the repository — answered 6/6 prepared questions correctly, all via the no-LLM path, including exact figures. But along the summary chain the first casualties are quantitative evidence and causal mechanism, while proper nouns and identifiers persist longest. We also report two measurement traps that produced confidently wrong results before being caught: a length artefact that made the coarser level look *more* faithful, and a grouping error that made a single day's input dominate the average.

Finally, we report a negative result about evaluation methodology itself: independent LLM judges produced specific claims that did not survive verification — two of the two claims we checked in detail were wrong, both in the direction of overstating loss. Conclusions here therefore rest on mechanical, reproducible measurements, with judge output used only to indicate where to look.

---

## 1. Introduction

The position paper introduced Chronomem as a time-layered external memory service and stated its central design claim: recall is not one operation. **Exact recall** walks materialized reference chains down to raw records and calls no LLM; **semantic recall** reads LLM-generated summaries and is the only form that genuinely compresses coarse windows. It closed with an evaluation plan and no results.

This paper reports those results. The plan had three parts, and we address each:

- **(i)** a controlled comparison against flat memory and one-shot compaction, on recall accuracy and token cost;
- **(ii)** a semantic-drift study along the summary chain;
- **(iii)** a study of the work-log use case on the authors' own continuous deployment.

Two things distinguish this evaluation from a synthetic benchmark exercise. First, part (iii) runs on a deployment that has been accumulating real records for roughly two months, so the corpus is not invented. Second, in carrying out (ii) we found that the *obvious* way to measure it is wrong in a way that inverts the conclusion, and we report the correction in detail — the measurement method is part of the result.

We also report a methodological negative result (§6). We ran independent LLM judges over the same material; of the two specific claims we verified in depth, **both were wrong**, both overstating information loss. This is not a claim that judges are useless — they pointed at two real phenomena worth investigating — but it does mean their counts cannot be cited, and it motivates our reliance on mechanical measurement throughout.

### 1.1 Summary of contributions

1. A controlled comparison over five arms — recency, one-shot compaction, exact drill-down, day-level summaries and **week-level summaries** — showing that the recency baseline's degradation is a **capacity cliff** rather than gradual decay, verified by a six-point ablation (§3).
2. A corrected measurement of the **recursive summarization step**, showing that its fidelity is governed by *input diversity*: single-input steps do not compress at all and can be byte-identical to their input, while multi-day steps halve the text and lose ~40% of quantities (§4).
3. A characterisation of **what survives** along the chain on real data: identifiers outlast causal connectives, which outlast quantitative evidence (§5).
4. Evidence that the no-LLM path is **sufficient for exact recall** of concrete operational facts months later, via a blind recall test scored against independently established ground truth (§5.1).
5. A **negative methodological result** on LLM judges, and two measurement traps documented with their corrections (§6).

<!-- Sections 2-8 to follow. -->

---

## 2. Method

### 2.1 Two corpora, deliberately different

**Synthetic trace.** A seeded generator (`bench/gen_trace.py`) emits N simulated days of agent activity: each day produces a small number of *facts* (a decision with a recorded outcome) plus filler activity, and a probe set asks about facts from earlier days. Constraints established by measurement during development:

- **Answers are assigned round-robin**, not uniformly: a uniform draw over a small probe set clusters, so with 9 probes one option took 7 (a 78% majority-class baseline that leaves no headroom to detect a real difference). Round-robin bounds that baseline near 1/|choices|.
- **Topics are drawn without replacement per day.** Repeating a topic within a day makes "what was chosen for X on day N" ambiguous; 6 of 54 (day, topic) pairs were ambiguous, and those accounted for *every* miss the layered backend showed — the system had retained the fact and the extractor picked the other one.
- **Probes always look backwards, and the lag grows with the run.** Same-day probes are answered by any recency window (a 20-item window scored 7/9); a fixed short lag is likewise answered by any bounded window (a 20-item window still scored 90.6% on a 30-day trace with a 1-day lag). The lag therefore grows with the day, which is the axis a layered store should win on.
- Each fact carries an **opaque reference token** (`ref ZQ01`) inside the text. Summaries reproduce it verbatim, which makes extraction unambiguous — keying on (topic, day) is unreliable because a summary's prose conclusion routinely names several topics and several options in one sentence.

**Deployment corpus.** The authors' own Chronomem deployment, running continuously since 2026-08-29, single-user. At evaluation time it held 480 work-log records, 1201 agent-activity records and 63 lesson records, with 37 day-level and 6 week-level summary windows for the work log. This corpus has no ground truth, so it is used for *survival* measurements (§4, §5) rather than accuracy.

### 2.2 Four backends under identical input

| Backend | Mechanism |
|---|---|
| `flat-recency` | keeps everything, exposes the most recent 20 entries |
| `one-shot-compaction` | rewrites history into a running report every 2 days, discarding detail |
| `chronomem-exact` | reference-chain drill-down to raw entries (no LLM call) |
| `chronomem-day` | reads the **day-level** LLM summary of the fact's own window |
| `chronomem-week` | reads the **week-level** LLM summary containing the fact |

All arms see the same trace, answer the same probes, and are read by the **same extractor** — a weak extractor depresses all of them equally and leaves the comparison intact, whereas a per-backend reader would confound the two.

**A missing arm, and why it matters.** Our first version of this comparison had no coarse-summary arm: the summary backend read the *day-level* summary only. For a paper whose claim is about *layering*, that is a real gap — the "layered" side of the comparison exercised exactly one layer, and the coarse level — the thing that is supposed to trade information for span — was never asked a question. We therefore added a fifth arm, `chronomem-week`, which answers each probe from the week-level summary containing the fact.

The two summary arms are not two granularities of the same measurement. A day arm reads the window the fact came from, so the question and the material have the same extent; a week arm reads a window covering six other days, so the answer is one compressed item inside a larger bundle. That asymmetry is precisely the trade the architecture claims, and it is only visible if both arms are present.

The runner ingests the whole trace before asking anything (so that summary-generating backends can do off-line work), which means bounded backends must filter by the day being asked about. Without that filter the recency baseline answers day 5's question from day 30's most recent events and scores as well as a system that actually remembers.

### 2.3 What "lag" means, and why buckets are ranges

Probes are bucketed by lag (days between the fact and the moment of asking). Bucket edges are 0/1/2/3/5/7/14/30/60, so a bucket labelled 7 holds lags 7–13, and on a 30-day trace the top bucket contains 29-day probes. Tables report the true span (`7-13`, `14-29`): reporting the lower edge as if it were the lag invited a capacity conclusion the data did not support.

### 2.4 Measuring the chain: three attempts, two wrong

This is worth stating explicitly because the wrong versions produced confident, publishable-looking numbers.

**Attempt 1 — whole day vs whole week.** Retention came out at 81–84%, suggesting the coarse level was nearly lossless. It is not a valid comparison: a week bundle covers 5–7 days and runs ~3.4x longer than a day bundle, so it contains the measured day's content *plus* six other days'. Bigger target text contains a given token more often for no reason. In a variant that compared the full day against the full week, the artefact was strong enough to make the coarser level look *more* faithful than the finer one (42% vs 29% for quantities) — a result that should have been immediately suspect.

**Attempt 2 — one day vs the week's matching project section.** Still unequal: the week section covers the whole week.

**Attempt 3 (used).** Restrict *both* sides to the same project and the same 7-day window — which is what the recursion actually transforms, since the summarizer aggregates a project's child summaries by group key. Only then does the effect of interest appear (§4).

### 2.5 Mechanical token survival

To avoid judging prose, survival is measured over **tokens classified by kind**:

- **numeric** — quantities of 2+ digits, ratios, decimals (years excluded as labels);
- **symbolic** — backticked identifiers, `--flags`, camelCase and snake_case names;
- **causal** — connectives marking reasoning (因为/由于/根因/导致/因此/所以/退化成/…).

For each level we report the fraction of the finer level's tokens still present. This is objective and repeatable. It does not judge whether a human would say a fact "survived"; it measures whether the specific carriers of information did.

`absent` (the level exists but omits the fact) and `missing` (no summary exists for that window) are counted separately throughout. Conflating them reports non-generation as information loss — a mistake made twice during development, once here and once in an earlier drift study.

### 2.6 Isolation

The synthetic experiments write, so their client **refuses** the production port at construction. The real-corpus readers default *to* production — the real corpus exists nowhere else — and therefore allow only read-only tools, enforced in code rather than documented. During development a default pointing at production caused a synthetic trace to be written into the live store; it was removed and the guard added.

<!-- Sections 3-8 to follow. -->

---

## 3. Recall retention: the baseline fails structurally

### 3.1 Setup

30-day synthetic trace, 300 events, 32 probes, three seeds (7/11/23). Accuracy per lag bucket, averaged over seeds; `±` is the standard deviation across seeds.

### 3.2 Results

| lag (days) | flat-recency | one-shot compaction | **chronomem exact** | **chronomem day** | **chronomem week** |
|---|---|---|---|---|---|
| 1 | 100% | 0% | **100%** | **100%** ±0% | *pending* |
| **2** | **0%** | 0% | **100%** | **100%** ±0% | *pending* |
| 3–4 | 0% | 0% | **100%** | 91.7% ±14.4 | *pending* |
| 5–6 | 0% | 0% | **100%** | 58.3% ±38.2 | *pending* |
| 7–13 | 0% | 0% | **100%** | 54.8% ±18.0 | *pending* |
| 14–29 | 0% | 0% | **100%** | 77.8% ±25.5 | *pending* |
| **overall** | 16.7% | **0.0%** | **100.0%** | **80.4%** | *pending* |

> The `week` column is still being measured and is left as `pending` rather than estimated. Note that the `day` column was produced *before* the coarse arm existed, so it characterises the finest summary level only; whether the coarse level does better or worse on these probes is exactly what the pending column will answer, and we do not predict its direction here.

Three observations, in decreasing order of how much they surprise us.

**(a) The recency baseline's drop is a cliff, not a decay.** It is perfect at lag 1 and zero from lag 2 onward. The window holds 20 items and the trace emits ~10 events/day, so the boundary falls at ~2 days. Nothing about the *content* changes across that boundary — the information is simply absent from the target text.

**(b) One-shot compaction scores zero everywhere, including lag 1.** This is the strongest single result against destructive compaction: not only does it lose old detail, it loses the *most recent* detail too. In our implementation the compaction pass rewrites each window into a paraphrase ("a decision was made about X"), so the option letters never appear in the material at lag 1 either. The implementation is deliberately destructive, since fidelity is the property under test — an earlier version that preserved decision lines verbatim scored 100% and was, on inspection, not compressing at all but merely dropping filler.

**(c) The layered store's loss is compression loss, not temporal decay.** Exact recall holds 100% at every lag with **zero variance across seeds** (all six buckets, std 0.0). Summary recall does not decline monotonically with lag — 78% at 14–29 days is *higher* than 55% at 7–13 days — because a summary is produced once and does not change as it ages. What it loses is what compression dropped at generation time; time is not the variable.

The variance column is informative. Exact recall is deterministic (std 0.0 in every bucket, since the reader resolves a reference chain). Summary recall's spread comes from **LLM sampling**: re-summarizing the same window (`recompute`) twice produced 237 and 453 characters respectively, i.e. entirely different text from identical input. This means summary bucket means are centres of a distribution rather than precise values, and it is why we report ± and treat single-run bucket figures as indicative.

### 3.3 Ablation: the cliff tracks capacity

If (a) is a capacity effect, moving the window must move the cliff. Six window sizes, local backends only (no instance, no LLM):

| top_k | predicted cliff (top_k ÷ 10 events/day) | observed cliff | overall |
|---|---|---|---|
| 10 | 1.0 d | ≤0 d | 0.0% |
| 20 | 2.0 d | ≤1 d | 6.2% |
| 30 | 3.0 d | ≤2 d | 12.5% |
| 50 | 5.0 d | ≤3 d | 25.0% |
| 100 | 10.0 d | ≤5 d | 56.2% |
| 200 | 20.0 d | ≤7 d | 93.8% |

The cliff moves monotonically (0→1→2→3→5→7). Had it stayed at 2 days regardless of window size, the capacity explanation would be refuted and the difference would require an explanation in terms of the extractor or probe construction. Observed values sit slightly below predicted, for two reasons that are not defects: bucket edges are sparse (the cliff can only land on a boundary, and the intervening bucket requires *all* its probes correct), and the two errors at `top_k=200` are 29-day probes, which a 20-day window cannot cover.

### 3.4 The coarse arm (measurement in progress)

The five-arm run — which adds `chronomem-week`, answering each probe from the week-level summary containing the fact — is still executing at the time of writing. The day-level figures in §3.2 were measured without it and are reported as such.

Two things make this arm worth waiting for rather than inferring:

1. **It is the arm the architecture's claim is actually about.** A client asking about a month-old decision reads a coarse summary, not the day summary of the day the decision was made. If the coarse level answered as well as the day level, that would undercut the reason to keep the finer levels; if it answers much worse, the practical value of a month-deep hierarchy is in question. Both are informative, and neither follows from the day numbers.
2. **Its expected behaviour is genuinely uncertain.** The day arm reads the window the fact came from, so material and question have the same extent. The week arm reads a window six days larger, so the fact competes with everything else in that week — but it also sees a *summary of summaries*, which on real data sometimes returns its input verbatim (§4). Whether that helps or hurts on these probes is an empirical question.

We report the day column as final and the week column as pending rather than estimating it.

---

## 4. The recursive step: fidelity depends on input diversity

### 4.1 Why the obvious measurement is wrong

The step we want to characterise is: *a project's summaries for a week → that project's week summary*. Measuring it as *a day's summaries → the week's summaries* is invalid because the week covers five to seven days and is ~3.4x longer, so retention is inflated by the target simply being bigger.

Measured both ways on the same 24-day sample:

| comparison | target length | quantity retention |
|---|---|---|
| day bundle vs week bundle (unequal ranges) | 13143 chars median vs 3440 | **42.2%** — coarser level looks *better* |
| same project, one day vs the week section | unequal ranges | **~81%** |
| **same project, same 7-day window (used)** | equal ranges | see below |

The first row is the tell: a measurement in which the coarser level appears *more* faithful than the finer one is measuring text length, not compression.

### 4.2 The real result

40 project-week pairs from three closed weeks. Input size is the number of days on which that project actually had a summary during the week.

| days of input | pairs | quantities | identifiers | causal markers | length ratio |
|---|---|---|---|---|---|
| **1** | 29 | **90%** | 97% | 90% | **0.94x** |
| **≥2** | 11 | **58%** | 65% | **48%** | **0.53x** |
| all (mixed) | 40 | — | — | — | 0.82x |

**The single-input case is not compression.** For those 29 pairs the week summary is *byte-identical* to the day summary it was built from — measured similarity 1.0000 on texts of 755, 1112 and 972 characters. An LLM cannot reproduce 755 characters of Chinese verbatim; the model is choosing to restate its input unchanged. So "90% retention" there means "no compression occurred", not "compression is lossless".

Compression appears only when the input is diverse. With two or more days, the step halves the text (0.53x) and retention falls to 58% for quantities and 48% for causal connectives. The trend continues with input size:

| days of input | length ratio | quantity retention |
|---|---|---|
| 1 | 0.94x | 90% |
| 2 | 0.64x | 66% |
| 3 | 0.15x | 30% |
| 4 | 0.20x | 21% |

### 4.3 Consequences

**(a) Aggregating across input sizes inflates fidelity.** Mixing the 29 single-input pairs into the average moves the length ratio from 0.53x to 0.82x and raises apparent fidelity substantially. Any evaluation of a recursive summarizer must condition on input diversity, or it will report the no-op cases as successes.

**(b) The two hops differ by an order of magnitude.** `raw → day` compresses 3.1–4.2x; `day → week` compresses 0.53x. The reason is not the level but the input: the first hop consumes raw entries, the second consumes summaries that have already been compressed. A fixed "compression ratio per level" is therefore not a property of the architecture.

**(c) The chain is not a fixed-point compressor.** Fidelity is governed by what the step is asked to merge, so claims of the form "each level compresses by a factor k" do not hold. What holds is: the chain never loses information it was not given, and it compresses in proportion to input diversity.

---

## 5. What survives on the real corpus

### 5.1 Blind recall: the no-LLM path is sufficient for exact facts

**Design.** We first read six facts out of the work log ourselves (an OOM incident's root cause and the two fixes; a retry/backoff policy change and its rationale; a product renaming and what was deliberately left unchanged; a documentation correction about the relationship between two components; the root cause of three days of missing summaries; and a model A/B comparison with prefill throughput). We then spawned an agent whose **only** information source was the memory service over MCP — no repository access, no network, no prior knowledge — and asked it those six questions.

**Result: 6/6 correct**, all answered through the `exact` path (reference-chain drill-down, no LLM call in the loop). The answers included exact operational detail: resident memory 30–60 MB against a transient peak of 217–240 MB, a heap cap raised from 256 MB to 1 GB, prefill throughput of 317 vs 267 tok/s, and the specific keys the rename deliberately preserved and why.

This is the claim the position paper made about cost asymmetry, now measured rather than argued: **the no-LLM path alone recovers concrete operational facts from two months earlier.** It does not show that everything worth keeping was kept — only that what was kept is recoverable.

A narrower test of the same kind, on a 36-hour synthetic trace, gave 3/6 from the summary path where exact gave 6/6, i.e. summaries lose facts that raw entries retain.

### 5.2 What the chain drops, and in what order

Along the same corpus the first losses are **quantitative evidence** and **causal mechanism**; proper nouns and identifiers persist longest. Representative cases, each verified by retrieving the three levels and searching for the fact's terms:

- *Quantities.* A packaging cleanup reduced a manifest from 244 files to 101. Both numbers are absent from the day summary and the week summary; what remains is "version 0.4.1 released". A download guardrail improved from 1/3 to 3/3 with peak RSS held at 284 MiB; the week summary contains none of `guardrail`, `3/3` or `284`.
- *Mechanism.* "The sort comparator used a label containing `@version` as the primary key, so version ordering degraded to lexicographic" becomes, at both coarser levels, only the word **"sorting"**. The identifiers `pkgLabel`, `@version` and the term `lexicographic` are all gone.
- *Rules are the most fragile of all.* Reusable rules ("check the API docs before changing a builtin's semantics") almost never survive as rules; they leave a trace only inside an unrelated todo ("sync docs-site").

Two qualifications. First, quantities that are **used to state a conclusion** are dropped, while quantities that function as **status or acceptance criteria** often survive — so it is not "numbers are lost" but "evidentiary numbers are lost". Second, this ordering holds only where compression actually happens (§4): in the single-input case nothing is dropped because nothing is compressed.

### 5.3 An operational finding: a summary failure left a lasting gap

The deployment's week summaries covered 4 of 6 closed weeks. The two missing weeks (09-07 and 09-14) were not randomly absent: a scheduler bug in the same period (compact entries exceeding the endpoint's 32768-token context → HTTP 400 → failed → unbounded retry) meant that for two days the summarizer produced **zero** records, while the work-log path was unaffected. Normal weeks are generated at Monday 00:10–00:20; those two never appear at that cadence.

Because the scheduler only summarizes the most recently closed window, the gap persisted. Backfilling the two weeks (an explicit `mem/summarize` per window) restored week coverage to 6 weeks and moved the chain measurement from 0/6 to 3/6 recoverable.

We report this because it is the kind of evidence a synthetic benchmark cannot produce: **a failure in the memory system produced a measurable, persistent gap in its own memory**, and the shape of the gap (bounded to the failure window, day summaries intact) identifies the cause.

---

## 6. Methodology: two traps and a negative result

### 6.1 Trap 1 — a length artefact that inverted the conclusion

Comparing the whole day's summaries against the whole week's summaries gave the week level *higher* retention than the day level (42% vs 29% for quantities). A coarser level being more faithful than its input is impossible as a compression claim, and the cause was arithmetic: the week bundle is ~3.4x longer and covers six more days, so a token is likelier to appear there by coincidence. Restricting both sides to the same project and window reversed the ordering (§4).

**Generalisation.** Any retention metric computed over texts of different sizes and scopes is suspect. The tell is an ordering that contradicts the mechanism.

### 6.2 Trap 2 — an extraction ambiguity that manufactured failures

Probes originally located their answer by (topic, day). A summary's prose conclusion frequently names several topics and several options in one sentence ("keb and vun were applied options A and C"), so a reader taking the first option letter returns another topic's answer — and the wrong answer is *plausible*, so it does not look like a bug. Every miss the layered backend showed traced to this; with per-fact opaque reference tokens the backend scored 100%.

**Generalisation.** When a backend's failures cluster on one answer value, suspect the reader before the system.

### 6.3 Negative result — LLM judges overstate loss

Judging whether a fact "survived" is not mechanically defined, so we ran independent LLM judges over the same material. Their outputs are confident and detailed. Of the specific claims we verified in depth, **two of two were wrong**:

| judge claim | verification |
|---|---|
| Week summaries for the same week are byte-identical (same md5, 15796 chars) | ✅ **holds** |
| The week summary is "the last day's day-summary set" | ❌ **refuted** — per-day comparison finds only 0–1 groups verbatim-identical |
| A given day's summary "omits the chronomem group entirely; the whole causal chain and all figures are gone" | ❌ **refuted** — the group is present and complete, including the root-cause chain and the terms `OOM`, `sseCond`, `CLOSE_WAIT`, `heartbeat` |

Both refuted claims erred in the same direction: asserting absence that was not there. The judge's *counts* (intact / partial / absent distributions) are likewise not citable for this reason.

Judges remain useful for one thing: they **pointed at the right phenomena** — the byte-identical week output was real, and finding it led to the per-input-size analysis of §4. But the direction and the numbers had to come from mechanical re-measurement.

### 6.4 What we therefore rest on

Every quantitative claim in §3–§5 comes from a script that can be re-run and whose output is archived with the repository: the seeded trace generator, the four-backend runner, the ablation, the token-survival and week-step measurements, and the chain checks. The judge outputs are archived too, marked as direction-only. The harness itself has 31 regression tests plus a mutation check that deliberately breaks the implementation in ten ways (including the ones above) and fails if the suite does not notice — added after the traps of §6.1–6.2, precisely because passing tests prove little if the tests never exercise the thing they name.

---

## 7. Limitations

- **Three seeds.** The synthetic results rest on seeds 7/11/23. Exact recall's zero variance across buckets makes its 100% robust; the summary figures carry bucket standard deviations up to 38% and should be read as centres, not point estimates. Summary buckets hold 2–14 probes each.
- **Synthetic trace.** Mechanism-level claims (capacity cliff, destructive compaction) transfer; magnitudes calibrated to this trace do not.
- **No ground truth on the real corpus.** §5 is survival measurement and blind recall, not accuracy. §5.1 shows that what was recorded is recoverable; it cannot show that everything important was recorded.
- **Judge coverage incomplete.** Of four planned judge shards (24 days), two produced output (12 days). Since judge counts are not citable (§6.3) this affects only the qualitative colour, not the reported numbers.
- **Single deployment, single user, ~2 months.** No multi-tenant, authenticated or encrypted operation was exercised; scale is thousands of records across a handful of types.
- **Only day→week recursion measured.** The service supports finer levels (1h and below) and their behaviour is not characterised here.
- **One implementation of compaction.** The one-shot baseline is our own; a stronger compressor would shift its numbers, though not the structural argument that it cannot answer about content it has discarded.

---

## 8. Conclusion

We set out to execute the position paper's evaluation plan and found that the most interesting result was about the measurement.

The comparison part is unambiguous: a bounded recency window answers perfectly within its capacity and then not at all, with the cliff tracking capacity across a 6-point ablation; one-shot compaction scores zero even at the shortest lag; layered exact recall holds 100% across the full span with zero variance. The cost asymmetry the position paper argued for is real and measurable: the no-LLM path alone answered 6/6 blind questions about two-month-old operational facts.

The recursive-summarization part required correcting our own method twice, and the corrected result is more specific than the original claim. **The step's fidelity is governed by input diversity, not by the level.** When a project contributes a single day, the week summary is byte-identical to its input — no compression, and therefore no loss; when several days are merged, the text halves and roughly 40% of quantities and half the causal connectives disappear in one step. A "compression ratio per level" is not a property of the architecture. On real data the ordering of losses is stable: evidentiary numbers first, then mechanism, with identifiers lasting longest — and the fragility of reusable rules is the pattern most likely to matter in practice, since rules are the part of experience that is supposed to generalise.

Finally, a negative result we did not expect to be reportable: independent LLM judges produced specific, confident, wrong claims — both of the two we verified in depth asserted absence that was present. We report it because the same failure mode will affect any evaluation of memory systems that relies on model judgement of "did this survive": the judge cannot see what it has been given only in summary form, and neither, without care, can the evaluator.

---

## References

*(Inherits the reference list of the position paper. Newly cited artefacts:)*

1. Position paper: *Chronomem (忆时塔): Time-Layered External Memory as an MCP Service for Agent Recall and Summarization.* AiraXiv 2610.0035.
2. Evaluation harness and archived results: `chronomem/bench/` and `chronomem/bench/results/` in the implementation repository.
3. Consolidated evaluation documents: `chronomem/docs/evaluation-retention.md`, `chronomem/docs/evaluation-real-corpus.md`, `chronomem/docs/evaluation-baseline.md`.

---

## AI-Use Disclosure

The implementation, the evaluation harness and the analysis were developed in collaboration with an AI assistant (DeepSeek). Independent LLM judges were used as a *foil*: their outputs are reported as a negative result in §6.3 and are not the source of any quantitative claim. All reported numbers are produced by scripts archived with the repository and were re-verified against that output during writing.

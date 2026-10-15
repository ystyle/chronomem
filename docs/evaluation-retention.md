# 召回随时间的衰减：对照实验

> **日期**：2026-10-15
> **结论**：分层存储在整个 14 天跨度上保持召回，而**有界窗口与一次性压缩在 2 天后归零**。
> **状态**：单次实验（3 seeds）已完成，代码与数据均可复现；尚未并入论文。

## 1. 实验要回答什么

论文的核心主张是「分层时间记忆能用**有界的信息量**换来**无界的可召回时间跨度**」。评测要直接量这一点，而不是裁决某条摘要写得好不好：

**同一个事实，距今多久之后，还能被正确召回？**

这个问题有两个好处：

- 它不需要评判散文摘要的质量（用正则从散文里抠答案，测的其实是正则）；
- 它正是分层存储相对有界窗口的胜负手——对方不是"答得差一点"，而是**根本没有那段信息**。

## 2. 方法

### 2.1 四组后端

| 后端 | 代表 | 机制 |
|---|---|---|
| `flat-recency` | 朴素近期记忆 | 保留全部，但只把最近 20 条交给读者（≈2 天） |
| `one-shot-compaction` | 破坏性压缩 | 每 2 天把历史重写成一份简报，丢弃原始细节 |
| `chronomem-exact` | 忆时塔·精确下钻 | 沿物化引用链取回原始条目（服务端零 LLM） |
| `chronomem-summary` | 忆时塔·语义回顾 | 读按天生成的结构化摘要（有 LLM 成本） |

四组**吃同一份 trace、答同一组探针、用同一个提取器**——弱提取器会同等压低四者，不破坏对比。

### 2.2 探针与评分

trace 由 `gen_trace.py` 确定性生成：`--days 30 --agents 3 --seed 7`，300 条事件、32 个探针。每个事实带一个**无意义引用号**（`ref ZR01`），摘要在转述时会原样保留它，因此提取器能以唯一键定位——而不是在散文里按主题猜。

探针按**滞后天数**分桶（事实所在天 → 提问日）。每个后端在回答时只能看到提问日之前的material。

评分为精确匹配；`None`（材料中不存在该事实）计为错误，且**绝不退化成猜测**。

### 2.3 关键：判断任务状态的教训

同名结果文件不代表同一次运行。本实验中一次误判（把 5 天小测试留下的 `result-s7.json` 当成"新任务少了整组"）导致杀掉了一个正常运行的 job。**判断后台任务状态要看时间戳与 metadata 规模，不能只看文件名。**

## 3. 结果

### 3.1 主表：准确率 vs 事实距今时间（3 seeds，mean）

| lag(d) | flat-recency | one-shot-compaction | **chronomem-exact** | **chronomem-summary** |
|---|---|---|---|---|
| 1 | 100.0% | 0.0% | **100.0%** | **100.0%** |
| **2** | **0.0%** ← 断崖 | 0.0% | **100.0%** | **100.0%** |
| 3 | 0.0% | 0.0% | **100.0%** | 91.7% ±14.4 |
| 5 | 0.0% | 0.0% | **100.0%** | 58.3% ±38.2 |
| 7 | 0.0% | 0.0% | **100.0%** | 54.8% ±18.0 |
| 14 | 0.0% | 0.0% | **100.0%** | 77.8% ±25.5 |

整体（各 seed 整体准确率的均值）：

| 后端 | overall |
|---|---|
| flat-recency | 16.7% |
| one-shot-compaction | 0.0% |
| **chronomem-exact** | **100.0%** |
| **chronomem-summary** | **80.4%** |

### 3.2 三个可直接引用的观察

1. **有界窗口的断崖发生在它容量的边界上，与内容无关。**
   flat 的窗口是 20 条、每天约 10 条事件，于是滞后 1 天满分、滞后 2 天归零。这不是"记性差"，是**结构性**的：超窗口的信息不在它手里。实测 lag 1 为 100%，lag 2 起全部 0.0%。

2. **一次性压缩全程接近零。**
   compaction 把窗口重写成简报后，选项字母不再出现在材料里（简报表述为"a decision was made about X"）。lag 1 即 0.0%——**连最近的内容也被它丢掉了**。

3. **分层存储的召回不随时间衰减；损失是"压缩损失"，与时间无关。**
   - `exact` 全程 100%，**6 个桶的 std 全部为 0.0**；
   - `summary` 均值 54.8%–100%，不随 lag 单调下降（lag 14 是 77.8%，反而高于 lag 7 的 54.8%）——因为摘要一旦生成即定形，**时间是变量，压缩才是**。

### 3.3 std 的来源（重要）

`summary` 的桶标准差最高达 38.2%，而 `exact` 全为 0.0。差异来自**同一输入下 LLM 总结的采样随机性**——实测同一窗口连续两次 `recompute` 总结，产出文本分别为 237 与 453 字符，完全不同（trace 本身经 `cmp` 验证逐字节确定）。

因此：

- `exact` 的 100% 是**确定性结论**，不受采样影响；
- `summary` 的每个桶均值应视为**分布的中心**，不是精确值；桶内探针仅 2–14 个，单次运行不足以定论。

## 4. 边界与未做的事

- **单次实验、3 个 seed**。`summary` 桶内样本小（2–14 探针），标准差大；结论应表述为"summary 有显著但有界的压缩损失"，**不是**某个具体百分比。
- **trace 是合成的**。它证明的是机制层面的差异（有界窗口 vs 分层），不是真实会话分布下的效果。真实语料（`worklog` / `dsh/activity`）可用于定性佐证，但不含 ground truth，无法直接算准确率。
- **只测了 day 粒度的摘要**。1h/week 层的衰减未纳入本表。
- **未做**：消融（不同 `top_k`、不同压缩周期）、真实语料上的定性对照、以及 §3.2 第 3 点所暗示的"压缩损失 vs 时间损失"的分离实验。

## 5. 复现

```bash
# 独立实例（不碰生产；见 .bench-ctr/README.md）
cd .bench-ctr && docker compose up -d

# 单 seed
cd ../bench
python3 gen_trace.py --days 30 --agents 3 --seed 7 --out .work/t.json
python3 retention_eval.py --trace .work/t.json --url http://127.0.0.1:18900/mcp \
    --backends flat,compaction,chronomem-exact,chronomem-summary \
    --json-out .work/r.json

# 多 seed（报 mean±std）
python3 multi_seed.py --days 30 --seeds 7,11,23 --json-out .work/multi.json

# 工具自身的正确性（离线，不连塔）
python3 -m unittest test_harness -v
python3 check_mutations.py
```

> ⚠️ `ChronomemBackend` 的默认端点是研究实例 `18900`，并在构造时**硬拒绝**生产端口 `8900`。
> 实验绝不应写入 `~/docker/chronomem/data`；实验类型（`bench/eval`）用完即删。

## 6. 数据出处

| 内容 | 位置 |
|---|---|
| 多 seed 聚合（含 per-seed 原始 JSON） | `bench/.work/multi3.json`（生成物，未入版本控制） |
| 评测实现 | `bench/retention_eval.py` · `bench/backends.py` · `bench/run_eval.py` |
| trace 生成 | `bench/gen_trace.py` |
| 工具自检 | `bench/test_harness.py` · `bench/check_mutations.py` |
| 运行数据评估（能否写实证论文） | [`evaluation-baseline.md`](evaluation-baseline.md) |

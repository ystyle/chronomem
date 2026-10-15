# 评估结果存档

> **为什么这个目录要进版本控制**：`bench/.gitignore` 排除了 `.work/`（生成物），
> 但其中一部分结果**跑一次要几十分钟到几百分**（数百次 LLM 调用），
> 或**依赖当时的特定语料状态**（真实部署的摘要窗口），**不可再生**。
> 论文与文档引用它们，因此把关键结果固化在这里。

## 目录

```
results/
├── README.md              本文件
├── retention/             合成对照实验（可重跑，但耗时）
│   ├── multi3.json        3 seeds × 30 天 × 4 后端，含 per-seed 原始曲线
│   ├── ablation.json      top_k 消融（本地后端，秒级可重跑）
│   └── ret30final.json    单 seed 30 天四组完整结果（含 per_probe）
├── drift/                 语义漂移（独立实例，数百次 LLM 调用）
│   └── d36r.json          36h trace 的 chained/recompute 逐层结果
└── real-corpus/           真实语料（依赖当时的生产语料状态）
    ├── chain.json         链式存活测量（补算前，week 全 MISSING）
    ├── chain2.json        链式存活测量（补算后）
    ├── recall-result.md   盲测报告：仅用忆时塔回答 6 个问题，6/6 全对
    └── chain-result.md    链式判定报告：35 条事实 × 3 层
```

## 归档口径

**存**（不可再生或成本高）：
- 需要 LLM 调用才能得到的结果（`multi3.json`、`d36r.json`）
- 依赖特定语料状态的测量（真实语料的摘要窗口会随后续补算改变）
- 报告的**结论性文本**（agent 的理解与判断，重跑未必一致）

**不存**（可再生 / 体积大 / 中间产物）：
- trace 文件 —— `gen_trace.py` 同 seed 逐字节可复现
- 拉取的原始 MCP 响应 —— 重新检索即可
- `sample*.json` —— 采样脚本可重跑（但语料状态变了结果会变，故只存基于它的结论）

## 与文档的对应

| 结果 | 引用它的文档 |
|---|---|
| `retention/multi3.json` · `ablation.json` | [`docs/evaluation-retention.md`](../../../docs/evaluation-retention.md) |
| `real-corpus/chain2.json` · `recall-result.md` · `chain-result.md` | [`docs/evaluation-real-corpus.md`](../../../docs/evaluation-real-corpus.md) |
| 全部 | [`docs/share-chronomem-findings.md`](../../../docs/share-chronomem-findings.md) |

## 已知局限（引用时须一并说明）

- **合成实验只跑了 3 个 seed**（7/11/23）。
- **真实语料判定样本量小**：8 个日期 / 35 条事实，且判定是**主观判断**（真实语料无 ground truth）。
- **真实语料的 week 层曾因采样缺陷失真**：早期 `sample_real.py` 只取每个 week 窗口的第一条记录，
  而 week 摘要按 `proj` 分组（一周 13–14 条）。受此影响的两个判定者报告（`drift-judgement-A/B.json`）
  **其 week 层结论已作废**，未收入本目录；其 day 层结论不受影响。
- 补算（`mem/summarize` 周窗口）会**改变真实语料状态**，因此 `chain.json` 与 `chain2.json` 分别
  记录了补算前后的测量，两者都要保留才能说明"缺口 → 补算 → 结果变化"这条链。

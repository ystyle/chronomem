# 忆时塔（chronomem）

分层时间记忆的 **MCP 服务**：替外部工具保存**时序记忆**（经历/事件），并按需提供**结构回想**（物化桶下钻，零 LLM）与**语义总结**（LLM 提炼，可递归）。

> 品牌：忆时塔（memento × time）。项目/包名：`chronomem`。
> 完整设计见 [`docs/design.md`](docs/design.md)。

## 心智模型

- **塔 = 分层**：记忆按时间堆叠成塔，一层一个物化粒度（`10min → 30min → 1h → day → week`，**每类型可自定义**），越久越粗、越久越高；每层可沿引用链下钻到底层原始条目。
- **记忆类型 = 一条 series**：外部工具自定义「记忆类型」（= 消息类型），如 `worklog`、`proj/decisions`、`tool/errors`；各类型独立成库，互不干扰。
- **回想 vs 总结**（LLM 成本不同）：
  - **精确下钻**（`mem/recall mode=exact` + `mem/query`）：原始条目，语义保真、**零 LLM**。
  - **语义回顾**（`mem/recall mode=summary`）：时段摘要——前提是该时段**已总结过**（或 `summarize_on_miss=true` 现算），**有 LLM 成本**。
- **上下文恒定**：忆时塔只「存 + 查」，永不主动把内容塞回客户端上下文；由客户端自决。

## 特性

- ✅ 自定义记忆类型（宽松 schema，任意 JSON + tags）
- ✅ 每类型自定义**粒度链 levels**（10min/30min/1h/3h/day/week/month 子集）
- ✅ 结构回想：最近/时间范围/tag 过滤 + 物化桶**精确下钻**（零 LLM）
- ✅ 语义总结：窗口 → LLM 结构化摘要（决策/结论/待办/状态变更/关键词）→ 落 `SummaryRecord`，**可递归再总结**
- ✅ 任务阶段总结：`from/to` 显式窗口任意不规则时段
- ✅ 后台结构物化（每 60s，零 LLM，幂等）
- ✅ 仅 streamable HTTP（2025-11-25 session），多客户端共享同一记忆库

## 构建与运行

```bash
eval "$(cjvs env bash)" && eval "$(cjvs stdx-env bash)"
cjpm build -j 16

# 运行（常驻守护进程）
CHRONOLOG_DIR=~/.chronolog CHRONOLOG_PORT=8900 \
LLM_BASE_URL=... LLM_API_KEY=... LLM_MODEL=... \
./target/release/bin/chronomem.cli serve
```

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `CHRONOLOG_DIR` | `~/.chronolog` | 存储根目录（内含 `tsdb/`） |
| `CHRONOLOG_PORT` | `8900` | HTTP 监听端口 |
| `LLM_BASE_URL` | 无 | OpenAI 兼容端点（仅 summarize 需要） |
| `LLM_API_KEY` | 无 | API Key |
| `LLM_MODEL` | 无 | 默认模型 |
| `LLM_PROVIDER` | `openai` | `openai` / `anthropic` / `ollama` |

> 未配置 LLM 时：结构回想/存储照常可用，`mem/summarize` 返回明确错误。

## 客户端接入

任意支持 Streamable HTTP 的 MCP 客户端（opencode / Cherry Studio / Inspector / dsh / Claude Desktop 等）：

```jsonc
// opencode.json
{ "mcp": { "chronomem": { "type": "remote", "url": "http://127.0.0.1:8900" } } }
```

MCP Inspector：

```bash
npx @modelcontextprotocol/inspector --url http://127.0.0.1:8900
```

## 工具参考

| 工具 | 作用 |
|---|---|
| `mem/type_create` | 创建记忆类型（`name` 必填；`levels`? 粒度链；`description`? `schema`? `retention`?） |
| `mem/list_types` | 类型列表（name/描述/条目数/粒度链） |
| `mem/type_info` | 单类型详情（meta + 条目数 + 各粒度物化桶数） |
| `mem/append` | 追加条目（`type` + `payload` 必填；`tags`? `ts`?） |
| `mem/query` | 结构回想：`from`? `to`? `limit`? `tag`?（key=value） |
| `mem/recall` | `mode=exact` 下钻原始（零 LLM）/ `mode=summary` 语义回顾；`granularity` 须在类型 levels 内；`summarize_on_miss`? |
| `mem/buckets` | 列某粒度物化桶（发现可用窗口） |
| `mem/summarize` | 语义总结：`from/to`（任务阶段）或 `granularity`（按粒度）；`instructions`? `store`?（默认 true） |
| `mem/summaries` | 查总结记录（最新在前） |

## 示例：工作日志

```text
mem/type_create { name: "worklog", levels: ["day", "week"], description: "工作日志" }
# 干活时随手记（可能一天 1 条，也可能一小时好几条）
mem/append { type: "worklog", payload: { "task": "拆分忆时塔设计", "detail": "..." }, tags: { "proj": "chronomem" } }

# 任务阶段结束 → 按阶段总结（不规则窗口）
mem/summarize { type: "worklog", from: <任务开始>, to: <任务结束>, instructions: "提炼本次任务的决策与待办" }
# 按天/周规律总结
mem/summarize { type: "worklog", granularity: "day" }

# 回想
mem/query  { type: "worklog", tag: "proj=chronomem" }          # 结构回想（零 LLM）
mem/recall { type: "worklog", granularity: "day" }             # 精确下钻当天原始条目
mem/recall { type: "worklog", granularity: "day", mode: "summary" }  # 语义回顾（当天摘要）
```

## 测试

```bash
cjpm test -j 16 --no-progress
```

覆盖：Timeline 物化桶链/下钻/校验、类型注册表/持久化恢复、Summarizer（fake Provider）、全部 handler、HTTP 全链路 e2e。

## 依赖

| 依赖 | 用途 |
|---|---|
| [`mcp`](../mcp-cj) | MCP 协议框架（streamable HTTP） |
| [`tsdb`](../tsdb-cj) | 时序存储（series + 物化桶 + drillDown） |
| [`llm_api`](../llm_api) | 自研薄层 LLM REST 库（OpenAI/Anthropic/Ollama） |
| `jsonvalue` | 工具参数 / 动态字段 |

## License

MIT

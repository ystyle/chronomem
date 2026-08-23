# 忆时塔（chronomem）设计文档（spec）

> **定位**：分层时间记忆（回想 + 语义总结）的 **MCP 服务**，供任意 MCP 客户端（opencode / Cherry Studio / Inspector / dsh / Claude Desktop 等）复用。
>
> **来源**：泛化 liveboard 的「分层时间记忆」机制（`core/timeline.cj` + `requirements.md §9`）——把「分季财报式」结构物化桶链 + 精确回想，做成可自定义记忆类型、可按需 LLM 语义总结的独立 MCP。
>
> **品牌**：忆时塔（memento × time）。项目/包名：`chronomem`。

## 1. 命名与心智模型

- **忆时塔（chronomem）**：一个常驻 MCP 守护进程，替外部工具保存**时序记忆**（经历/事件），并提供**回想**（精确下钻原始条目 = 零 LLM；语义回顾摘要 = 依赖 LLM 总结）与**语义总结**（LLM 提炼窗口，写 `SummaryRecord`）。
- **塔 = 分层**：记忆按时间堆叠成塔，一层一个物化粒度，越久越粗、越久越高；每层可沿引用链下钻到底层原始条目。**粒度链是类型级配置**（§5.1）：默认 `10min→30min→1h→day→week`，高频类型保分钟级（当天精确回想），低频类型（工作日志）可收敛到 `day→week`。
- **记忆类型 = 一条 series**：外部工具自定义「记忆类型」（= 消息类型），如 `work/chat`、`proj/decisions`、`tool/errors`；各类型独立成库，互不干扰。
- **回想 vs 总结**（注意：**回想不全是零 LLM**）：
  - **精确下钻（`mem/recall mode=exact` + `mem/query`）**：沿物化桶引用链下钻到**原始条目**——语义保真、零丢失、**零 LLM 成本**；但返回的是原始体量，「越久越粗」在这里只是结构导航、不是内容压缩。
  - **语义回顾（`mem/recall mode=summary`）**：返回目标时段的**语义摘要**——这是「越久越粗」的真正形态，但**前提是该时段已做过总结**（此前 `mem/summarize` 过，或本次现算），**有 LLM 成本**。
  - **语义总结（`mem/summarize`）**：把窗口条目/低层摘要提炼成 `SummaryRecord`（决策/结论/待办/状态变更），是语义物化的内容来源，也是语义回顾的前提。
- **上下文恒定**：忆时塔只「存 + 查」，**永不主动把内容塞回客户端上下文**；由客户端自决是否取回（呼应 liveboard 恒定上下文原则）。
- **对比 wiki**：wiki 是「主题记忆」（知识按词条布局）；忆时塔是「时间记忆」（经历按时间布局，分季财报式）。二者可互补：时间日志沉淀出主题词条，词条回溯到时间证据。

## 2. 技术栈与依赖

| 依赖 | 用途 | 说明 |
|---|---|---|
| `mcp`（mcp-cj） | MCP 协议框架 | `McpServer` + `SessionHttpServerTransport`（2025-11-25），tools / resources / prompts |
| `tsdb`（tsdb-cj） | 时序存储 | series append-only + tag 过滤 + 分层物化桶 + `drillDown`；一个库承载全部类型 |
| `jsonvalue` | 工具参数 / 动态字段 | payload 与 schema 是动态字段（用 jsonvalue）；固定结构类一律 json.stream |
| `llm_api` | LLM 调用 | 自研薄层 LLM REST 库（`Provider` 接口 + OpenAI/Anthropic/Ollama 实现），**从 atelier.provider 抽取的独立库**；chronomem 只依赖它，不依赖 atelier 本体 |
| `stdx.net.http` | HTTP 传输 | 经 atelier.provider 传递依赖 |

> **为何抽取 `llm_api` 独立库**：chronomem 只需「调 LLM REST API」这一层。atelier 当初「自研优先、直接对接 REST、不引第三方 OpenAI SDK」，`atelier.provider` 正是这层薄封装（OpenAI/Anthropic/Ollama，~1300 行）。把它从 atelier 抽成独立库 `llm_api`（含 message 模型 + EventStream + util.json + provider），chronomem 只依赖 `llm_api`（jsonvalue + stdx.net.http），**不拖 atelier 依赖树**（mcp/bstorm/sonyflake/mustache/tomlcj/jsonrpc/ulid）。
>
> **为何不引入完整 atelier**：只为「存 + 回想 + 总结」服务，不需要 Message/Tool/Session/Trust/Skill 等 Agent 运行时。
>
> **llm_api 抽取边界**：`atelier.message`（消息模型，零外部依赖）+ `atelier.event.EventStream` + `atelier.util.json`（toJsonString/fromJsonString）+ `atelier.provider`（接口/实现/工厂/类型，含 OpenAITool）；atelier 改造为 path 依赖 `llm_api` 并保持源码兼容（re-export shim 或改 import）。

## 3. 传输与部署

- **仅 streamable HTTP**（`SessionHttpServerTransport`，协议 2025-11-25）：常驻守护进程，多 MCP 客户端共享同一份记忆库。
- 默认监听 `127.0.0.1:8900`（`CHRONOLOG_PORT` 可改）。
- 启动：`chronomem serve`（阻塞，`McpServer.serve()`）。
- 客户端连接：`SessionHttpClientTransport("http://127.0.0.1:8900")` 或任意支持 streamable HTTP 的 MCP 客户端配置。
- 安全：MVP 仅本机监听、无鉴权；鉴权（Bearer / OAuth）列为后续阶段（见 §10）。

## 4. 存储布局

```
CHRONOLOG_DIR（默认 ~/.chronolog/）
└── tsdb/                     # 一个 tsdb 库（TimelineStore 共享容器）
    ├── <type>                # 每个记忆类型一个 series（原始条目）
    ├── <type>.summary        # 该类型的语义总结 series（type_create 时自动创建）
    └── __meta                # 类型注册表：每类型一条 TypeMeta（tag=name 定位，可覆盖更新）
```

- 一个进程一个库；重启恢复 = 打开 tsdb + 读 `__meta` 重建类型注册表。
- 原始条目与总结条目**分 series**：结构回想与语义总结互不污染，且总结可独立物化。

## 5. 记忆类型（自定义）

`type` = 一个 tsdb series + 可选描述 + 可选 schema + 可选保留期 + **自定义粒度链（levels）**。

- **宽松模式**：`mem/append` 接受任意 JSON payload + tags，**不做字段强校验**；schema 仅作文档 / LLM 提示，供客户端或 LLM 生成符合预期的 payload。
- **命名**：白名单 `[A-Za-z0-9_/-]`，建议 `namespace/name`（如 `work/chat`、`proj/decisions`），多工具逻辑隔离；禁止 `..` 与绝对路径（防路径穿越，与 liveboard 同约定）。
- **保留期**：可选（如 `30d`），走 `tsdb.setRetention` + `clean()`；不设默认淘汰，MVP 全量保留，淘汰策略后续再设计。
- **粒度链（levels）**：自定义物化层级与按粒度总结/回想的档位，见 §5.1。

### TypeMeta（固定结构，json.stream 序列化）

```cangjie
public struct TypeMeta <: JsonSerializable & JsonDeserializable<TypeMeta> {
    public let name: String                 // 类型名（白名单）
    public let description: String
    public let schema: Option<String>       // 可选字段描述（JSON 字符串；动态字段 → JsonValue/字符串载体）
    public let levels: ArrayList<String>    // 粒度链（结构物化层级 + 按粒度总结/回想档位）
    public let retention: Option<String>    // 可选保留期（如 "30d"）
    public let autoSummarize: Bool          // 后台自动语义总结（默认 false，opt-in；§7.3）
    public let summaryLevels: Option<ArrayList<String>>  // 自动总结粒度（缺省 = 最粗 2 档）
    public let createdAt: Int64
}
```

### 5.1 粒度链（levels）—— 物化层级与总结时段

**粒度是类型级配置，不是全局写死**（liveboard 现为全局 `10min→30min→1h→day`，不满足不同类型的需求差异）。

- **允许粒度集**：`10min / 30min / 1h / 3h / day / week / month`。
- **默认链**：`10min → 30min → 1h → day → week`（liveboard 基础上加 week 为默认封顶）。
- **类型可覆盖为任意子集**（须升序、至少 1 档）：
  - 高频类型（chat / 工具调用）→ 默认全链；分钟/半小时档服务**当天内精确回想**。
  - 低频类型（worklog / decisions）→ `["day", "week"]` 甚至 `["week"]`；10min/30min 桶基本是空窗口，建了纯浪费。
- **week 为默认语义总结封顶**：周在年的尺度上已很小，一整年的周级摘要仅 ~52 条，加载成本低，且极少需要回忆整年；`month` 仅作长期归档的可选层，不默认。
- **结构物化只按该类型声明的层级建桶**；`mem/recall` / `mem/summarize` 的 `granularity` 校验为「该类型已配置的粒度」，不在链上的粒度报错。

### 5.2 自然时间窗口（日历对齐）

**窗口按自然时间对齐，不是 epoch 锚定**（粒度落到墙上要遵循日历语义）：

- **钟表对齐**：`10min / 30min / 1h / 3h` —— `ts - ts % windowMs`（epoch 锚定恰好 = 钟表对齐，:00/:10/:20…）。
- **日历对齐**：`day` = **本地零点**；`week` = **周一起点**；`month` = **1 号零点**。时区由 `CHRONOLOG_TIMEZONE` 决定（默认本地时区；DST/大小月由日历计算正确处理）。
- **桶 key** = 窗口起点按 UTC ISO 编码（`yyyy-MM-ddTHH:mm:ssZ`，与 tsdb.bucketKeyOf 同格式、可排序、对 tsdb 透明）；读写同用本套 `windowKeyOf` 生成，跨粒度一致。
- **意义**：`day` 不再是 UTC 08:00 切、`week` 不再是周四起、`month` 不再是固定 30 天——工作日志「按天/按周」的日历语义成立。

## 6. MCP 工具集

| 工具 | 作用 | 关键参数 |
|---|---|---|
| `mem/type_create` | 建类型（+ 自动建 `<type>.summary` series） | `name`(必填), `levels`?(粒度链，默认 §5.1), `description`?, `schema`?, `retention`?, `auto_summarize`?(默认false), `summary_levels`?(缺省=最粗2档) |
| `mem/list_types` | 类型列表（name/description/count/updatedAt） | — |
| `mem/type_info` | 单类型详情（meta + 条目数 + 各粒度物化桶数） | `name`(必填) |
| `mem/append` | 追加一条原始条目 | `type`(必填), `payload`(对象,必填), `tags`?, `ts`?(缺省=now) |
| `mem/query` | 结构回想：最近 / 时间范围 / tag 过滤 | `type`(必填), `from`?, `to`?, `limit`?(默认20), `tag`? |
| `mem/recall` | 回想：`mode=exact` 下钻原始条目（零 LLM）；`mode=summary` 返回时段语义摘要（依赖已生成或现算） | `type`(必填), `granularity`(必填，须在类型 levels 内), `windowStartMs`?, `mode`?(exact/summary，默认 exact), `summarize_on_miss`?(默认 false，仅 summary 模式) |
| `mem/buckets` | 列某粒度物化桶（发现可用窗口 + 桶摘要） | `type`(必填), `granularity`(必填), `from`?, `to`? |
| `mem/summarize` | 语义总结（见 §7）：**按粒度**总结（须在类型 levels 内）或**按显式窗口**总结（`from/to`，任意不规则时段 = 任务阶段） | `type`(必填), `from`?, `to`?, `granularity`?, `instructions`?, `model`?, `recompute`?, `store`?(默认true) |
| `mem/summaries` | 查某类型的总结记录（最新在前） | `type`(必填), `from`?, `to`?, `limit`? |

> 前缀统一 `mem/`：语义中立（任何工具的通用记忆），且不与具体客户端命令冲突。**只读工具**（query / recall(mode=exact，或 mode=summary 且 summarize_on_miss=false) / buckets / summaries / list / type_info）不改变任何状态；**写工具**（type_create / append / summarize / recall(mode=summary 且 summarize_on_miss=true)）显式落盘。

## 7. 语义总结（核心设计）

> 语义总结 = 物化的**第三种模式**（另两种见 §8），也是「语义回顾」（`mem/recall mode=summary`）的内容来源与前提：没有总结，粗粒度回顾就只能拿原始条目，或提示「该时段尚无摘要」。

### 7.1 流程

```
mem/summarize { type, from/to 或 granularity+anchor, instructions?, model? }
  → 查窗口内条目（结构回想，零成本）
  → 格式化（条目列表：ts + payload 摘要 + tags）
  → 调 llm_api Provider（OpenAI 兼容端点；env: LLM_BASE_URL / LLM_API_KEY / LLM_MODEL）
      prompt = 系统指令 + 窗口范围 + instructions + 条目列表 → 要求输出结构化摘要
  → 摘要文本落库为 <type>.summary series 的一条 SummaryRecord
  → 返回摘要文本 + 记录 ts
```

- **结构化锚点**（requirements §9.4「总结 schema」）：系统指令引导 LLM 输出固定章节——`决策 / 结论 / 待办 / 状态变更 / 关键词`，保证可回忆、可下钻、可再聚合。
- **输入窗口两种形态**：
  - **按粒度**：`granularity + anchor`（锚点所在物化桶的窗口）——自动对齐该类型的粒度链，适合规律性总结（如每天/每周）。
  - **按显式窗口（任务阶段）**：`from/to` 任意不规则时段——**存储层不做「阶段」特殊机制**，由调用方（agent 客户端）在阶段结束时把「任务阶段」映射成 `from/to` 窗口调用；工作日志这类「一天 1 条、也可能一小时好几条」的不均匀分布，正是由「按天/周粒度」+「任务阶段显式窗口」两条腿覆盖。两条路径产生的 `SummaryRecord` 同存 `<type>.summary`，凭 `windowFrom/windowTo` 区分。
- **model 覆盖**：缺省用 `LLM_MODEL`；可传 `model` 单次覆盖。

### 7.2 总结也是时序记录（可递归）

```cangjie
public struct SummaryRecord <: JsonSerializable & JsonDeserializable<SummaryRecord> {
    public let ts: Int64
    public let windowFrom: Int64
    public let windowTo: Int64
    public let model: String
    public let refs: ArrayList<Int64>      // 被总结的条目 ts（原始条目 或 更低层总结）
    public let instructions: String
    public let text: String                 // 结构化摘要（决策/结论/待办/状态变更）
}
```

- **递归总结**：对 `<type>.summary` 里的记录再 `mem/summarize`（refs 指向总结记录）→ 高层语义总结。原始 → 10min 语义 → 1h 语义 → day 语义，与结构桶链正交叠层 = 真·「分季财报式」语义压缩。
- **语义漂移控制**：
  - 默认**基于最近一层**总结提炼（便宜、快）。
  - `recompute=true` 时**强制基于原始条目**重算窗口（贵、但无链式传话漂移）。
  - 原则（requirements §9.4）：底层总结尽量基于原始数据；是否允许多层「传话」由调用方权衡。

### 7.3 触发策略（避免空转烧 token）

- **手动为主**：`mem/summarize` 只在被调用时才烧 token——默认形态。
- **后台自动总结（已落地）**：`SummarizeScheduler` 用 cron-cj 定时驱动（默认 `*/10 * * * *` 墙钟对齐），对 `auto_summarize=true` 的类型总结「最新已闭合且未总结」的**自然时间窗口**。成本护栏：
  - **per-type opt-in**：`type_create` 传 `auto_summarize=true` 才参与（默认 false，未 opt-in 的类型零 LLM）；
  - **目标粒度**：`summary_levels` 可配，缺省 = 粒度链最粗 2 档（如 day/week，呼应「总结到周」）；
  - **窗口闭合 + 沉降**：只总结已结束且超过沉降期（默认 10min）的窗口，防漏窗口末尾条目；
  - **幂等**：已覆盖摘要的窗口不重跑；
  - **每轮上限**：`CHRONOLOG_SUMMARY_MAX_PER_RUN`（默认 5）次 LLM 调用/轮。
- **语义回顾的懒计算**：`mem/recall mode=summary` 遇目标时段无摘要时，`summarize_on_miss=true` 会现算并落库（等同一次 `mem/summarize`，有 LLM 成本与写副作用）；`false`（默认）则提示「该时段尚无语义摘要，请先 summarize」。
- **结构物化 ≠ 语义总结**：结构物化（引用链/数值聚合）由 `MaterializeScheduler`（cron-cj，默认 `@every 1m`）自动跑，**零 LLM 成本**、幂等、空窗口零成本。

## 8. 分层物化（三种模式）

物化 = 给「时段」建塔层；三种模式对应不同的「塔层内容」与 LLM 成本：

| 模式 | 适用 | 塔层内容 | 支持的回想 | LLM |
|---|---|---|---|---|
| **引用链**（默认，事件型） | 任意类型 | `PointRef` / `BucketRef` | 精确下钻（exact） | 零 |
| **数值聚合**（可选，指标型） | 数值采样类型 | 桶 summary = count/avg/min/max JSON | 概览 + 下钻 | 零 |
| **语义摘要**（可选，LLM） | 任意类型 | `<type>.summary` series 的 `SummaryRecord` | 语义回顾（summary） | **有** |

- **纯引用链 = 导航，不压缩**：下钻回想拿的是原始体量；「越久越粗」的**内容压缩**只由数值聚合与语义摘要承载——这正是「回想零 LLM 只对精确下钻成立」的原因（见 §1）。
- 泛化 liveboard `Timeline` / `TimelineStore`：**剥离 atelier.message 依赖**（不再耦合 Message 类型），payload 一律字符串载体（JSON），成为纯 tsdb 之上的通用分层时间线。
- **粒度按类型配置**（§5.1）：`Timeline.materializeLevels()` 从全局写死改为**每 series 传入自身 levels**（默认 `10min→30min→1h→day→week`）；结构物化只建该类型声明的层级，逐层 `PointRef`/`BucketRef` 桶链，每层物化落盘不删下层、越久越粗；`drillDown` 沿链精确回忆。
- `MaterializeScheduler`：后台线程每 60s 对全部已注册类型（含各 `<type>.summary`）统一**结构**物化（引用链 / 数值聚合）；幂等、空窗口零成本。**语义摘要不自动物化**（受 token 预算约束，见 §7.3）。
- 结构物化（引用链 + 数值聚合）**零 LLM**；语义摘要依赖 LLM——「物化」名义下二者成本必须区分表述。

## 9. MCP resources（只读浏览，加分项）

| 资源模板 | 内容 |
|---|---|
| `mem://types` | 类型注册表（name/description/count） |
| `mem://<type>/latest` | 该类型最近 N 条原始条目 |
| `mem://<type>/<granularity>/<bucketKey>` | 某物化桶下钻出的原始条目 |
| `mem://<type>/summaries/latest` | 该类型最近一条语义总结 |

> 资源与工具同源（同一查询函数），仅以不同 MCP 入口暴露；客户端可用 resources 做只读浏览、用 tools 做操作。

## 10. 边界 / 安全 / 隐私

- **类型名白名单** `[A-Za-z0-9_/-]`，拒绝 `..` 与绝对路径 → 防路径穿越（同 liveboard）。
- **tag key/value 白名单**（如 `[A-Za-z0-9_.-]`），防注入 tsdb tag 解析。
- **隐私分级**：MVP 无分级，payload 全文入库；隐私分级（按类型标记敏感、加密落盘）列为后续（对应 liveboard Phase 4 用户建模）。
- **鉴权**：MVP 仅 `127.0.0.1` 本机监听；远程部署 / 多用户需鉴权（Bearer / OAuth），列为后续。

## 11. 配置（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `CHRONOLOG_DIR` | `~/.chronolog` | 存储根目录 |
| `CHRONOLOG_ADDR` | `127.0.0.1` | 绑定地址（本地安全；容器/远程用 `0.0.0.0`） |
| `CHRONOLOG_PORT` | `8900` | HTTP 监听端口 |
| `CHRONOLOG_TIMEZONE` | 本地时区 | 自然窗口时区（IANA id，如 `Asia/Shanghai`） |
| `CHRONOLOG_MATERIALIZE_CRON` | `@every 1m` | 结构物化 cron |
| `CHRONOLOG_SUMMARY_CRON` | `*/10 * * * *` | 自动语义总结 cron |
| `CHRONOLOG_SUMMARY_MAX_PER_RUN` | `5` | 每轮自动总结次数上限 |
| `CHRONOLOG_SUMMARY_SETTLE` | `600000`(10min) | 窗口闭合沉降期（毫秒） |
| `LLM_BASE_URL` | 无（必填以启用 summarize） | OpenAI 兼容端点基址 |
| `LLM_API_KEY` | 无 | API Key |
| `LLM_MODEL` | 无 | 默认模型名 |
| `LLM_PROVIDER` | `openai` | openai / anthropic / ollama（映射 llm_api ProviderFactory） |

> summarize 在未配置 LLM 环境时返回明确错误（「未配置 LLM_BASE_URL/LLM_API_KEY/LLM_MODEL」）；其余工具不依赖 LLM，可正常使用。

## 12. 项目结构

```
chronomem/
├── AGENTS.md            # 工程规范（照抄本仓库约定）
├── cjpm.toml            # 依赖：mcp / tsdb / jsonvalue / atelier
├── docs/design.md       # 本文件
├── src/
│   ├── chronomem.cj     # root 导出（public import chronomem.core.*）
│   ├── core/            # 分层时间记忆库（独立可测，不依赖 MCP）
│   │   ├── timeline.cj      # 通用 Timeline / TimelineStore / MaterializeScheduler
│   │   ├── registry.cj      # MemoryTypeRegistry + TypeMeta
│   │   ├── summary.cj       # SummaryRecord + Summarizer（包 llm_api Provider）
│   │   └── *_test.cj        # 单元测试（TDD）
│   └── mcp/             # MCP 服务层
│       ├── config.cj        # env 解析
│       ├── handlers.cj      # 各 mem/* 工具 handler + 参数解析（动态字段 → jsonvalue）
│       ├── resources.cj     # mem:// 资源模板
│       ├── server.cj        # McpServer 装配 + 工具注册 + 启动
│       └── main.cj          # 入口（streamable HTTP，阻塞 serve）
└── test/ 或 src 内 *_test.cj   # 测试随包放（仓颉单元测试惯例）
```

## 13. 实现路线（TDD，仓颉单元测试优先）

> 遵循仓库工程规范：新功能先写单元测试；固定结构类用 json.stream 序列化；仅动态字段用 jsonvalue；有测试后再提交；开发开功能分支。

- **前置：抽取 `llm_api`**（独立于 chronomem，见 §2 边界）：新项目 `~/Projects/Cangjie/llm_api`（message + event + util.json + provider，依赖 jsonvalue + stdx.net.http）；atelier 改为 path 依赖并保持源码兼容。验收：llm_api 自带测试（原 provider 测试迁移）绿 + atelier 全量 `cjpm test` 绿。
- **Phase 0 脚手架**：cjpm 项目 + 依赖（mcp / tsdb / jsonvalue / llm_api）+ `main.cj`（streamable HTTP，`McpServer.serve()`）。验收：起服务 → Inspector / MCP client `tools/list` 连通。
- **Phase 1 core**：`Timeline` 泛化（剥 atelier.message，`materializeLevels` 改为每 series 传 levels）+ `MemoryTypeRegistry` + `TypeMeta`（含 levels）+ `SummaryRecord`。单测：append/query/tag 过滤/**按类型 levels 建桶链**/drillDown 精确回想/**非法粒度校验**/类型注册与恢复。
- **Phase 2 总结**：`Summarizer`（包 llm_api Provider）+ env 配置 + 结构化摘要 prompt。单测：fake Provider 注入，验证窗口查询 → prompt 组装 → SummaryRecord 落库 → 递归总结 → `recompute` → **recall 双档位**（exact 下钻原始 / summary 返回摘要；无摘要时 summarize_on_miss=true 现算落库 / false 提示「先 summarize」）。
- **Phase 3 MCP 层**：`mem/*` 工具注册 + handler + 参数解析。单测：直接调 handler 函数（不依赖网络），覆盖正常 / 缺参 / 非法类型名 / 未配置 LLM。
- **Phase 4 e2e**：起 HTTP server → `McpClient`（`SessionHttpClientTransport`）连 → 建类型 / append / query / recall / buckets / summarize / summaries 全链路。
- **Phase 5 交付**：README（安装 / 启动 / 客户端配置示例）+ 发版准备（中心仓，若发库则把 `core` 拆独立库）。

## 14. 非目标（后续阶段）

- 主题记忆 / wiki 布局（与忆时塔互补，另立项目）。
- 指标型聚合物化的类型接入（能力保留，按需开启）。
- 后台自动语义总结调度器（受 token 预算约束，默认关闭）。
- `month` 级长期归档（week 已覆盖「整年 ~52 条」的概览需求，month 仅按需可选，非默认）。
- 鉴权 / 加密 / 隐私分级。
- 多库 / 远程同步（多机共享记忆）。

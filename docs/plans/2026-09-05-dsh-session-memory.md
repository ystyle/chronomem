# dsh 会话记忆全自动存储 —— 设计文档（讨论稿 v4）

> 日期：2026-09-05 ｜ 状态：草案，待逐点讨论 ｜ 关联：忆时塔（chronomem）`docs/design.md` §5-§8
> 目标形态：**dsh 会话全程无需 agent 自觉记录，记忆自动落库忆时塔**（结构层零 LLM；语义层尽量免 LLM——核心洞察见 §0）。
> v3 变更：**dsh/turn + dsh/session + dsh/goal 三类型合一为 `dsh/activity`**（2026-09-05 讨论定案），类型收敛为三本账：`dsh/activity`（活动时间线）+ `dsh/lesson`（教训）+ 既有 `worklog`（项目账）。
> v4 变更（2026-09-12 源码级复核）：**D1（插件形态）/ D7（写入通道）/ D12（压缩事件口径）三项"待验证"已定案**（见 §3.0、§3.4、§9）；M1 瘦身并新增 M0 前置；§2.1 `phase` 枚举修正；补 `mem/type_create` 非幂等的硬约束。其余决策点（D2-D6 / D8 / D10）仍待逐一讨论。
> v5 变更（2026-10-27）：新增 **§2.1b `dsh/chat`**——对话历史拆为独立类型（`levels: 1h/day/week`），由配置项 `fullContextWorkspaces` 按工作区开启；补类型自愈（create → update，不动 levels）。

## 0. 结论摘要

- 记忆类型收敛为**三本账**：`dsh/activity`（会话活动时间线，核心）、`dsh/lesson`（教训，半自动）、既有 `worklog`（项目账，只扩 tag 约定、不碰注册表）。
- **为什么合一**：忆时塔的回想与语义总结都是 per-type（一条 series 一个窗口一条摘要）——三类型分开 = 每天三条摘要要人工拼接；合一 = 一条时间线、一次 day/week 总结**同时覆盖轮次流水、会话生命周期、目标状态**（摘要按 kind 自然分节），这正是合并的收益所在（详见 §2.1）。
- 核心洞察①：**每个完成轮次的 agent 末条回复 = 模型自产的天然总结**（预蒸馏产物）——事件层可精确定位、捕获零 LLM，比存会话 log / 工具调用更有用；忆时塔只做存储与再聚合。
- 核心洞察②：会话被 dsh **上下文压缩（compaction）**时，**压缩摘要是第二个白送总结**（会话级，dsh 已付 LLM 账）。
- 插件 `dsh-mem-bridge` 把三样东西写塔：事件自带的结构骨架（L1）、轮次/压缩自然总结（L2a）、塔内条目聚合出的里程碑/收口账（L2b）；原始对话与工具入参出参**永不入塔**。
- 全自动覆盖：会话 open/resume、**会话标题**、**轮次台账**、**上下文压缩**、goal 全状态机、子代理完成（总结文本事件白送）；聚合账（close/里程碑）基于塔内条目蒸馏，可整体关闭（见 §7）。
- **v4 事实复核**：D1（宿主/profile 顶层单实例即可）、D7（进程内插件用全局 `fetch` POST `/mcp`）、D12（压缩产生三个扩展事件，捕获点 = `compaction/summary`）已定案，原文"待验证 / 先 spike"的表述作废；证据与出处见 §9。

## 1. 背景与目标

### 1.1 现状与痛点

- 忆时塔现有 `worklog` 类型，按**项目任务**记录，靠 agent 按 AGENTS.md 约定自觉追加——有会话视角盲区：会话 open/close、跨会话目标、轮次过程、子代理产出、非项目活动都记不到；且依赖自觉，非全自动。
- dsh 宿主本身**不生成"任务总结"记录**：goal 完成只有目标原文，会话结束没有总结事件，总结文本散落在轮次末条 assistant 消息与压缩摘要节点里。
- 目标是：dsh 里发生的、值得跨会话/跨天回溯的事，自动、分层、可查地进忆时塔。

### 1.2 分层模型（全文档的总纲）

| 层 | 内容 | 写入者 | LLM | 去向 |
|---|---|---|---|---|
| L0 原文层 | 逐条消息、工具调用、chunk | dsh 自身 | — | **dsh session log（不入塔）** |
| L1 结构层 | 事件自带字段：id/时间/状态/目标原文/阻塞原因/压缩事实 | 插件（事件直取） | 零 | 塔：`dsh/activity` 骨架条目（open/resume/goal/error/compact 事实） |
| L2a 自然总结层 | ① 每完成轮次的 agent 末条回复；② 会话级上下文压缩摘要（dsh 已生成） | 插件（事件/持久流直取 + 截断） | **零** | 塔：`dsh/activity` kind=turn / kind=compact |
| L2b 聚合层 | 跨轮聚合账：milestone/close/收口 | 插件触发 LLM（原料 = 塔内 activity 条目） | 有 | 塔：`dsh/activity` kind=milestone/close |
| L3 总结层 | 按 day/week 的语义总结 | 忆时塔 auto_summarize（已有能力） | 有 | 塔：`dsh/activity.summary` |

原则：**L1/L2a 永远自动且零 LLM；L2b 尽量自动、可关；L0 永不复制**。轮次末条回复与压缩摘要是"预蒸馏"产物——比原始层更有用、比事后蒸馏更便宜，这是本设计区别于"镜像会话日志"的关键。**所有层写同一条时间线（一个类型）**，day/week 自动总结天然覆盖全部 kind。

## 2. 记忆类型套件（忆时塔 TypeMeta 提案）

> 共性：命名空间 `dsh/`（来源域隔离，避免与其他 MCP 客户端撞库）；levels 统一 `[day, week]`（低频类型不需要分钟档，忆时塔 §5.1）；schema 仅作文档约束（宽松模式，忆时塔 §5）；机器 id 一律进 tags（可过滤、可 join），叙述文本进 payload。
> **建类型的硬约束（v4 复核）**：`mem/type_create` **不幂等**（类型已存在直接抛 `类型已存在`），且 MCP 原先**未暴露** `mem/type_update`（`registry.updateMeta` 有实现，无工具入口）。因此 schema / `summary_group_by` 必须**一次定稿**，否则只能 `truncate` + `type_delete` 重建（丢数据）。**对策已落地（v4 M0 完成，commit `4f84ccb`）**：忆时塔已补 `mem/type_update`（边界见 §6）。bridge 侧的自愈调用序 = **`mem/type_create` → 若返回"类型已存在"错误 → `mem/type_update`**（update 不是 upsert，类型不存在时同样报错），无需解析 type_info 文本。

### 2.1 `dsh/activity` — 会话活动时间线（核心，合一类型）

- 描述：dsh 会话活动时间线：一个类型承载会话生命周期（open/resume/close）、会话标题（title）、轮次台账（turn）、上下文压缩（compact）、子代理/聚合里程碑（milestone）、错误（error）与目标状态机（goal）；用 tag 可过滤出任意子视图。
- **合一的理由与对策**：

| 分开的理由 | 合并后的对策 |
|---|---|
| 三种事件频率差异大（turn 每天几十条 vs goal 每条状态变更 vs session 每会话几条） | 体量由 turn 主导属正常——它就是"流水账主体"；低频条目靠 kind tag 仍可单独过滤 |
| schema 会变宽（各 kind 字段不同） | 宽松模式 + 按 kind 分节的 schema 文档（union 风格，见下） |
| goal 想单独出周报 | 周摘要整体覆盖目标状态；需要单出时用显式窗口手动 summarize |
| turn 万一要单独 retention / 10min 档 / 单独关总结 | 随时可拆新类型（旧条目带 kind tag，零迁移零丢失）——**没有沉没成本**。已在 2026-10-27 实际拆出 `dsh/chat`（§2.1b）：对话流需要 `1h` 档而 activity 只需要 `day/week` |

- **合一的收益**：一次 `recall mode=summary` 就是"今天/本周 dsh 全貌"；时间线叙事连贯（轮次流水中嵌会话开合、压缩、goal 变化）；类型管理、UI、自动总结都收敛。
- 配置：`levels: ["day","week"]`、`auto_summarize: true`、`summary_group_by: ["proj"]`、**无 retention（v4 D13：先不设 + 体积监控）**。
- schema（按 kind 分节的宽松文档）：

```jsonc
{
  "payload": {
    // 所有 kind 共有
    "title": "string 本条一句话标题（title→会话标题；turn→该轮末条回复首行截断≤120字；compact→'上下文压缩 span a..b'；goal→objective；open/resume→会话标题**此时尚未产生**，留空由 kind=title 后补）",
    "note": "string 本条内容（turn→该轮末条回复，上限 6KB；compact→压缩摘要，上限 16KB；milestone→聚合产出；其余→状态叙事）",
    // kind 专属
    "outcome": "string close/milestone：产出物与结果（提交/PR/文件/数字）",
    "blocker": "string close/error/goal(block)：阻塞原因或错误 code（不落错误全文/堆栈）",
    "next": "string close/resume/goal：下一步/续接抓手",
    "stats": "string turn/compact：tools=13: write×2… 或 shadowedTokenCount（纯计数，不含入参出参）",
    "progress": "string goal 专用：本轮推进"
  },
  "tags": {
    "kind":   "open|resume|title|compact|turn|milestone|close|error|goal",
    "phase":  "goal 专用状态：active|paused|blocked|complete（= GoalPhase，**无 cleared**；clear 是 operation，GoalChanged.goal 缺失即墓碑）",
    "session": "string dsh SessionId（原文层引用键）",
    "agent":  "string",
    "proj":   "string 可选（v4 D8 定案：cwd 目录名 + 映射表推断；无 cwd 则未分组）",
    "goal":   "string GoalId（kind=goal 必填；进行中的 turn 可选）",
    "turn":   "string 轮次号（kind=turn）",
    "rev":    "string GoalRef.revision（kind=goal，去重用）",
    "span":   "string 遮蔽 seq 范围（kind=compact，如 123..456）",
    "branch": "string 可选"
  }
}
```

- kind × 追加点与写入者（**全部自动**，去重键见括号）：

| kind | 写入者/层级 | 触发 | LLM |
|---|---|---|---|
| `open` / `resume` | L1 自动 | `agent/session-start`（startup/clear → open；resume → resume） | 无 |
| `title`（v4 探针新增） | L1 自动 | `session/event` 过滤 `session/title`（先 fallback、后 LLM 标题各一条，取最新；去重：session+kind） | 无 |
| `turn` | L2a 自动 | `session/event` 过滤 `turn/end` reason=completed + 实质阈值（D10），取该轮末条 `assistant/message` text 块（去重：session+turn） | **零** |
| `compact` | L1+L2a 自动 | **`session/event` 过滤 `compaction/summary`**（已核实：携带 `summary` 正文 + `shadowedRange` + `shadowedTokenCount`；`compaction/start` / `compaction/end` 只用于生命周期与失败判定，见 §9.1）；摘要文本截断 16KB（去重：compactionId） | **零**（dsh 已生成） |
| `goal` | L1 自动 | `goal/changed`（operation→phase；快照→objective/progress 留空/blocker 等；去重：goal+rev，edit 重复只记最新） | 无 |
| `milestone` | L2b（子代理分支零 LLM） | `subagent/end`（lastAssistantMessage 直取）/ `workflow/end`（聚合其子代理）/ 跨轮蒸馏（去重：runId/workflowRunId/…） | 零或可选压缩（D4） |
| `close` | L2b | goal complete（**v4 D2 定案：无 goal 会话不出 close**，靠 day/week 自动总结覆盖流水），原料 = 塔内该会话 turn+compact 条目聚合蒸馏 | 有 |
| `error` | L1 自动 | `agent/error` / `turn/end` reason=error（去重：session+turn+step，只记事实骨架） | 无 |

- 摘要分节：类型 description 与 schema 固化指引——**day/week 自动总结按「轮次流水 / 生命周期与压缩 / 目标状态」三节组织**（条目自带 kind tag，LLM 可自然分组）；必要时手动 summarize 时在 `instructions` 里重申。

### 2.1b `dsh/chat` — 对话历史（全上下文工作区专用，2026-10-27 新增）

- 描述：dsh 对话历史：全上下文工作区里逐条记录的真人输入、assistant 回复与工具调用；供按小时/天/周回想一次具体交谈。
- **为什么拆出来**（对应 §2.1 表格里「随时可拆新类型」那条）：`dsh/activity` 是**低频运营时间线**（每会话几条生命周期事件、每轮一条末条回复、goal 状态变更），而对话流是**高频逐条**。两者对 `levels` 的要求相反——activity 的 `day/week` 对对话流太粗（当天内无法按小时回想），对话流的 `1h` 对 activity 又纯粹是空桶。
- **决定性理由**：忆时塔的 `levels` **建了不能改**（`mem/type_update` 拒绝修改，物化桶链不可逆）。一旦混在一个类型里，必然有一半内容用错粒度且无法补救——所以只能一开始就分开，没有事后调整的余地。
- 配置：`levels: ["1h","day","week"]`（取 `1h` 而非默认 `10min` 起：聊天消息间隔几分钟到十几分钟，10min 桶基本是空的）、`auto_summarize: true`、`summary_group_by: ["proj"]`、无 retention。
- kind：`user`（真人输入，`source.kind === 'user'` 且 `surfaceOp === 'append'`）、`say`（每条 assistant 文本，带 `turn`/`step`）、`tool`（工具调用，按工作区级别 `none`/`names`/`full` 决定存多少）。
- **触发面**：只由配置项 `fullContextWorkspaces` 命中的会话写入；列表为空（默认）时该类型不产生任何条目。
- **体积实测依据**（1265 KB 真实会话）：工具出参 736 KB + 入参 334 KB = 86.9%，assistant 全部 144 KB，真人输入仅 4.4 KB（0.34%）。故工具必须分级录入，不能一刀切全存。

**类型自愈**：桥挂载时确保两个类型存在，调用序 `mem/type_create` →（「类型已存在」）→ `mem/type_update`。update **只补** `description` / `auto_summarize` / `summary_group_by`，**不带 `levels`**（不可逆，已存在类型保持自身粒度链）。此前 README 描述过这段自愈但代码并未实现——给一个不存在的类型名会静默丢数据（每条 append 失败并丢弃，只有计数日志）。

### 2.2 `dsh/lesson` — 教训/决策（半自动，不并入 activity）

- 为什么不并入：lesson 是**知识长尾**而非时间线——无日总结需求、靠 topic 检索、卷进 activity 只会污染流水账摘要与物化链。
- 描述：可复用教训：坑/根因/解法/复用条件。**不自动总结**（稀疏长尾，烧 token 不值），需要时手动 `mem/summarize` 月/季窗口蒸馏成 wiki 词条。
- 配置：`levels: ["day","week"]`、`auto_summarize: false`、无 retention。
- schema：

```jsonc
{
  "payload": {
    "title": "string 一句话教训",
    "context": "string 场景/触发条件",
    "cause": "string 根因",
    "fix": "string 解法",
    "prevention": "string 如何避免复发",
    "ref": "string 证据引用（session/提交/文件）"
  },
  "tags": { "topic": "string 检索键（如 nftables/cjpm/lsp）", "proj": "string", "session": "string" }
}
```

- 追加点：**不自动（v4 D5 定案）**。理由：事件只能给 `error.code` 这类事实，根因/预防是语义推断，全自动产出低信噪比条目；由 agent 在踩坑时自报，或定期从 activity 的 error 条目人工提炼。**不实现**"error → lesson 草稿"开关。

### 2.3 `worklog` 扩展（只改约定，不动注册表）

- AGENTS 约定在既有 append 上**新增可选 tags**：`agent`、`session`、`goal`。
- 收益：`mem/query {type: worklog, tag: "session=<id>"}` 可跨项目捞回某会话的全部任务日志；group 仍 `[proj]`，与 `dsh/activity` 摘要口径对齐。
- 写端仍是 agent（worklog 语义 = 项目任务账；`dsh/activity` = 会话活动账，两者用 tags 互链，不互相替代）。v4 D9 定案：`dsh/activity` **不开任何人工写入口**。

## 3. dsh 集成插件 `dsh-mem-bridge` 设计

### 3.0 插件形态（D1 / D15 已定案，v4）

- **运行形态**：把 bridge 做成一个 **npm 包**（dsh 插件包）；本期以 `link:` 依赖挂进 profile 并进 `dsh.profile.bundles`（**先不发布**，试用满意后再发 npm —— D16）。包内 `dsh.bundle.patch` 指向自己的 `cordis.patch.yml`（内容只有一行 `insert`）。先例：`dsh-better-sidebar` 就是这个模型（`dsh.bundle.patch` + bundles 列表 + `dsh plugin --profile <name> add` 自动 reconcile）。
- **采集点**：root / 未打 scope 标签、单实例常驻 —— 记忆采集必须跨会话、跨宿主重启存活，不能挂在单个 agent preset 里。依据：`dsh-scope` 契约确认**未打标监听器全局准入**（见 §9.1），故"每 agent preset 挂一行采集插件"的退路不需要。
- **为什么是包而不是 profile 里的裸 `.mjs`（D15）**：`~/.dsh` **不在任何 git 仓库内**，裸 `.mjs` 既无历史也无测试运行环境；而本插件最吃测试的恰是热路径纯逻辑（轮次文本抽取、截断、去重键、proj 映射、队列背压）。包只多约半小时脚手架，换来 git + 单测 + 多 profile 单一来源 + 以后真要发布也不用重构。
- **探针 ≠ 实现**：事件语义的未知项（"该轮末条 `assistant/message` 到底是哪条"、扩展事件运行时的实际载荷与顺序）用一个**丢弃型探针**回答 —— 优先用**动态 Cordis 插件**（`ctx.on` + `console.log`，当场可跑、无需重启、无需落文件；它做不了 HTTP，但写入通道已定案、不需要探）。探针结论回写本文档后再写实现。
- 代价：profile 级而非宿主级 —— 多 profile（web / tui / headless）需各自 `link` + 在 `dsh.profile.bundles` 加一行；改动后需重启该 profile 的 dsh 进程才生效。

### 3.1 事件 → 写入映射（已核实的契约，全部入 `dsh/activity`）

| 事件（签名已核实） | kind | 载荷来源 | LLM | 去重键 |
|---|---|---|---|---|
| `agent/session-start`（source: startup/clear/resume/compact；Agent{id}） | open/resume | source + agent.id + 时间（compact 续跑只登记，卡由压缩标记行产出） | 无 | session+kind+首个事件 seq |
| 压缩三事件（**已核实**）：`session/event` 过滤 `compaction/start` / **`compaction/summary`** / `compaction/end` | compact | 以 **`compaction/summary`** 为准：`summary` 正文（截断 16KB）+ `shadowedRange` + `shadowedTokenCount`；start/end 提供生命周期与失败（`error`）。**`compaction/prune` 是工具结果裁剪，不计入本 kind** | 无 | compactionId |
| `goal/changed`（operation 7 种；GoalView 含 objective/phase/blockedReason/roundsStarted/maxGoalRounds/revision/activation） | goal | 事件快照直取（phase tag；objective→title） | 无 | goal+rev（edit/重复事件只记最新） |
| `session/event` 过滤：`turn/end`（reason=completed）＋该轮**最后一条** `assistant/message`（**探针实证**，见 §9.3：完成轮的末条必为 `[reasoning,text]`、无 tool-call；中间步骤多为 textLen 0，偶有 31–967 字**过程旁白**，故不得取"轮内所有 text"。护栏：末条无 text 时回退到最近一条含 text 的。`assistant/attempt` 是重试噪音，不得当轮边界） | turn | 末条回复 text 块（截断 6KB）+ 轮内工具计数 | 无 | session+turn |
| `agent/error`（turn/step/error） | error | code/时间，**不落错误全文** | 无 | session+turn+step |
| `subagent/end`（stopReason 5 种；**lastAssistantMessage?: ContentBlock[]**） | milestone | 子代理最后回复文本块（截断/限长） | 无* | runId |
| `workflow/end`（stopReason 3 种；agentsStarted；**明确不含结果值**） | milestone | 自身仅事实；总结=其子代理 end 的聚合 | 无* | workflowRunId |
| `agent/disposed` / `api-session/removed` | （不直接写）触发收口判定（D2） | — | — | — |

\* 子代理最后回复即"结果汇报"形态，属**事件白送的语义层**；只做文本抽取/截断，**不再过 LLM**（v4 D4 定案：L2a 全层保持零 LLM）。

`session/event` 是**订阅点**而非写入源：bridge 过滤消费其中的轮次边界 / 消息定位 / 工具计数，只在进程内瞬时读取末条 text 块做截断入库。明确**不接**：`tools/result` 与 `assistant/message` 的完整内容（L0）、`agent/status`（idle⇄running 噪音）。

### 3.2 状态、去重与恢复

- **去重依据 = 幂等键 tag（v4 D3 定案）**：每条写入自带 `session+turn` / `goal+rev` / `compactionId` / `runId` 之一作为幂等键；插件只在**进程内**维护 per-session 状态（最近 turn / goal revision）做快速防重，热路径**零查询、零磁盘**。
- **为什么够用**：`session/event` 只对**新 append** 发射，构造种子不 emit（`dsh-session` 源码），故 dsh 重启**不会重放历史事件**；重启后最多多出一条 `resume`，而那是真实的生命周期事件、本就该记。若要核查历史重复，用 `mem/query tag="session=<id>"` 取回后按幂等键 tag 本地比对即可（运维手段，不进热路径）。**原"以塔为唯一事实源、插件完全无状态"（塔内回溯）方案不再采用** —— 长会话翻页会让写入路径变慢。
- **重启打断的轮次不会入塔（实测确认的边界）**：`kind=turn` 由 `turn/end` 触发，若 dsh 在一轮进行中被重启/杀掉，该轮没有 `turn/end` 事件 → 不产条目（也不回溯）。2026-09-12 实测：turn 号出现 6/7/9/10，缺的 5、8 正是两次重启时正在飞的轮次。这是"只记事件、不回溯"的直接后果，属设计内行为。
- **写入失败 / 塔不可用（v4 D6 定案）**：**有界内存队列 + 退避重试 + 满则丢最旧 + 计数日志**。不落盘、不阻塞 dsh：塔短时抖动可自愈，长时间宕机丢中间条目但日志给出丢弃计数；明确**不做**本地缓冲补写（避免补写时间戳与会话 summary 窗口错位）。

### 3.3 语义卡（L2）生成策略 —— "全自动"的核心与边界

| 场景 | 触发 | 原料 | 产物（均入 `dsh/activity`） | LLM |
|---|---|---|---|---|
| **轮次完成（最高频，全自动主体）** | `session/event` 过滤 `turn/end` reason=completed + 实质阈值（D10） | 该轮末条 `assistant/message` text 块 | kind=turn（note=末条回复截断） | **零** |
| 上下文压缩（会话级，第二个白送总结） | `session/event` 过滤 `compaction/summary`（已核实） | compactionId / shadowedRange（遮蔽 seq 范围）/ shadowedTokenCount + `summary` ContentBlock 文本 | kind=compact | **零**（dsh 已生成） |
| 子代理完成/异常 | `subagent/end` | lastAssistantMessage + stopReason | kind=milestone | **零**（截断，v4 D4 定案） |
| goal 完成 | `goal/changed` op=complete | **塔内该会话 kind=turn+compact 条目聚合**（必要时补尾部消息） | kind=close（outcome/next） | 有 |
| 会话收口（无 goal） | **v4 D2 定案：先不判** —— 无 goal 会话不出 close，流水由 day/week 自动总结覆盖 | （不适用） | — | — |

- 关键转变：**L2b 聚合蒸馏的原料从"读会话原文尾部"改为"读塔内 activity 条目"**（turn + compact）——原文只在捕获瞬间于插件进程内出现，聚合时不再触碰原文：隐私面缩小、成本降低、与 L0 边界更干净。
- 补充：compact 条目天然适合进 L2b 聚合原料——压缩摘要已含早期历史要点，close/收口聚合输入 = 该会话 turn + compact 条目，**跨"压缩边界"的信息不丢**。
- LLM 调用走 `llm` service（`stream(GenerateOptions)`），模型/开关可配；护栏：每会话收口最多 1 次、每日上限、可整体关闭（关闭后 L1+L2a 仍全自动，只缺聚合账）。
- 蒸馏**失败/关闭**时退化为：骨架 close 条目（title=会话标题 + 轮次/工具统计），不留空洞。

### 3.4 写入通道（D7 已定案，v4）

**结论：进程内插件（工程形态见 §3.0 / D15）用全局 `fetch` 直接 POST JSON-RPC 到 `http://127.0.0.1:8900/mcp`。**

- `ctx.web.fetch` **不可用**：`WebFetchRequest` 只有 `{ url: string }`，没有 method / body 能力 —— 原候选 1 出局。
- **动态 Cordis 插件同样不可行**：动态沙箱把 `fetch` 设为 trap（报错指向 `ctx.web`），`require` / Node timer 也是 trap，数据型全局（如 `process`）为 `undefined`。动态插件只能用于**采集侧**验证，不能写塔。
- **现成先例（无需 spike）**：`~/.dsh/profiles/web/cordis.patch.yml` 已用 `insert: name: "./xxx.mjs"` 挂载本地 Node ESM 插件（`extra-writable-roots.mjs`、`ntfy-announce.mjs`），其中 `ntfy-announce.mjs` **正在用全局 `fetch` 发 POST** —— 证明"profile 内的插件拥有真 Node 能力"。bridge 走同一挂载语义，只是形态改为包（见 §3.0）。
- 该插件挂在 profile 顶层（root / 未打 scope 标签）→ 按 `dsh-scope` 契约收取**全部**会话的事件（见 D1），并拥有完整 Node 能力（`fetch`、`ctx.get('llm')`）。
- 备选路径（不采用，仅记录）：部署已挂 `mcp-chronomem` MCP 客户端，理论上可复用其连接；但进程内 `fetch` 更简单、无中间层。

> 原"M1 先做 15 分钟 spike 验证写入通道"**已无必要**；M1 改为直接端到端 append 一条验证。

### 3.5 配置与护栏

- **配置面（v4 D16② 定案）**：主入口是**插件行 `config` + `settings.installSection`**（在 Web 设置页里配服务地址 / key / 开关 / 模型；已验证纯 host 插件即可做到，无需客户端 UI —— 见 §9.1）；下列 env 作为兜底与无 settings provider 时的默认值。
- **认证（v4 D16③）**：配置了 key 就带 `Authorization: Bearer <key>`；忆时塔目前无鉴权，其 design §10 已把 Bearer 列为后续项，届时零改动对接。

```text
DSH_MEM_BRIDGE_URL      塔地址，默认 http://127.0.0.1:8900
DSH_MEM_BRIDGE_TOKEN    认证 key（Bearer；留空 = 不带 Authorization 头）
DSH_MEM_BRIDGE_ENABLE   总开关，默认 true
DSH_MEM_BRIDGE_DISTILL  聚合蒸馏（L2b）开关，默认 true（false = L1 骨架 + L2a 自然总结，无聚合账）
DSH_MEM_BRIDGE_MODEL    蒸馏模型（缺省沿用宿主默认）
DSH_MEM_BRIDGE_READ_ORIGIN L2b 聚合是否读会话原文兜底（默认 false = 只用塔内条目；v4 D11 定案）
DSH_MEM_BRIDGE_TAIL_N   聚合原料取尾部 activity 条目数，默认 20
DSH_MEM_BRIDGE_MAX_DAILY 每日 LLM 蒸馏上限，默认 20 次
DSH_MEM_BRIDGE_QUEUE_MAX 写入队列上限（内存；满则丢最旧并计数日志），默认 500
DSH_MEM_BRIDGE_PROJ_MAP 路径→proj 映射（`前缀=proj` 列表；未命中取 cwd 目录名，无 cwd 则未分组）
DSH_MEM_BRIDGE_IDLE_MS  （预留；v4 D2 定案不判收口，暂不使用）静默时长，默认 10min
DSH_MEM_BRIDGE_TURN_MIN_TOOLS 轮次计入条件一：轮内工具数 ≥ 该值（默认 1；0 = 关闭该条件）
DSH_MEM_BRIDGE_TURN_MIN_LEN   轮次计入条件二：末条回复 ≥ 该字符数（默认 120，滤寒暄；0 = 关闭该条件）
                              # 两条件为「或」：满足任一即计入（v4 D9/D10 定案）；两者同时为 0 = 全量入塔
DSH_MEM_BRIDGE_TURN_NOTE_MAX  kind=turn 的 note 上限字符（默认 6000，超限截首尾 —— 探针实测末条回复 1879–4259 字，4000 会截到真实内容，见 §9.3）
DSH_MEM_BRIDGE_COMPACT_NOTE_MAX kind=compact 的 note 上限字符（默认 16000）
```

## 4. 查询场景（验收用例）

> 注意：忆时塔 `mem/query` 的 tag 过滤为单键值（`session=x` 或 `kind=turn`）；组合视图用时间范围 + 本地聚合。

1. 会话续接（主入口）：`mem/query {type: dsh/activity, tag: "session=<id>", limit: 50}` → 该会话时间线（最近 close 的 next / 最新 turn 的 note 即可恢复上下文）。
2. 轮次流水子视图：`mem/query {type: dsh/activity, tag: "kind=turn"}` + 时间范围 → 逐轮自然总结。
3. 挂账盘点：近 7 天该 session 有 open/resume 无 close（query 原始条目按 session 聚合）。**注意**：v4 D2 定案后 close 只由 goal complete 产出，故此视图实际是"目标挂账"。
4. 目标史：`mem/query {type: dsh/activity, tag: "goal=<id>"}` → 目标推进链（kind=goal + phase 序列，跨会话 join）。
5. 项目日报/周报：`mem/recall {type: dsh/activity, granularity: day|week, mode: summary, group: "<proj>"}` → **一次覆盖**轮次流水 + 生命周期/压缩 + 目标状态（三节结构）。
6. 压缩边界回溯：`mem/query {type: dsh/activity, tag: "kind=compact"}` + session 范围 → 早期历史要点（跨压缩边界续接的关键）。
7. 子代理产出检索：`mem/query {type: dsh/activity, tag: "kind=milestone"}` + 时间范围。
8. 教训检索：`mem/query {type: dsh/lesson, tag: "topic=<词>"}`。

### 4.1 验收结果（2026-09-12 生产实测）

| # | 用例 | 结果 |
|---|---|---|
| 1 | 会话续接 | ✅ `session=<id>` 返回该会话完整时间线（实测 15 条：resume/turn/goal/close 混合） |
| 2 | 轮次流水 | ✅ `kind=turn` + 时间范围；turn 号唯一无重复 |
| 3 | 挂账盘点 | ✅ 按 session 聚合生效：子代理会话（有新 `open`+`title`、无 `close`）正确判为"挂账"；本会话（有 `close`）判为已收口 |
| 4 | 目标史 | ✅ `goal=<id>` 返回 5 条，相位链 `create→pause→resume→complete` 可还原 |
| 5 | 项目日/周报 | ✅ **三节结构如期产出且质量高**：`mem/recall {granularity:"day", mode:"summary", group:"Cangjie"}` 准确覆盖轮次流水 / 生命周期与压缩 / 目标状态，并抓到 commit 号与关键决策。前置修好了总结超时（见 §9.5） |
| 6 | 压缩边界回溯 | ⏳ **无数据**：本会话至今未发生 `compaction`（探针 `memprb-1` 仍挂着等真实压缩）；查询形状本身可用 |
| 7 | 子代理产出 | ✅ 起一个子代理后 `kind=milestone` 出现 1 条（`session=子代理会话`、`role=subagent`、`proj` 正确） |
| 8 | 教训检索 | ✅ 写入 1 条真实教训（本次踩的"只看响应非空就判成功"坑），`topic=verification` 可检索 |

## 5. 安全与边界

- 入塔内容 = 结构化事实 + **轮次末条回复（截断 4KB）** + **上下文压缩摘要（截断 16KB）** + 聚合蒸馏摘要；**不含**消息原文全量、工具入参出参、错误堆栈全文。轮次末条回复与压缩摘要都是对用户（上下文）可见的 agent/LLM 自产文本，属"预蒸馏"产物而非原文。
- L2b 聚合蒸馏的原料 = 塔内 activity 条目（不再读会话原文）；原文只在捕获瞬间于插件进程内瞬时出现，不落盘、不入日志。
- 忆时塔本机监听、无鉴权（现状）；若 dsh 与塔分机部署则需先补鉴权（忆时塔后续阶段）。
- 塔内类型命名 `dsh/` 前缀与其它客户端隔离。

## 6. 里程碑（落地顺序）

- **M0 —— ✅ 已完成并部署验证（2026-09-12，commit `4f84ccb`，分支 `feat/type-update`）**：忆时塔新增 `mem/type_update`（走已有 `registry.updateMeta`）。**允许改**：`description` / `schema` / `retention` / `auto_summarize` / `summary_levels` / `summary_group_by`；**禁止改 `levels`**（物化桶链不可逆）与 `name`（series 键）—— 要改 levels 只能 `truncate` + `type_delete` 重建；**传与现值相同的 levels 按 no-op 接受**（bridge 幂等自愈需要）。字段语义：**省略 = 不变，空串 / 空数组 = 清空**。类型不存在时拒绝（不是 upsert-create）。附带：`updateMeta` 补上 `validateTypeName` + `validateLevels`（此前缺，非法 levels 会静默落库）；`mem/type_info` 补显示自动总结 / 总结粒度 / 保留期 / 字段描述。6 个新测试、全套 126 通过；已重建塔容器部署，5 项生产冒烟通过（见 §9.2）。
- M1：① **探针 —— ✅ 完成**（2026-09-12，见 §9.3）；② **包 —— ✅ 完成**（`dsh-mem-bridge/`，commit `0658090`：`package.json` + `dsh.bundle.patch` 的 `cordis.patch.yml` + `lib/pure.js`（纯逻辑）+ `lib/index.js`（接线与写入队列）+ 30 个纯逻辑单测 + 1 个真实塔集成自测）；③ **端到端 append —— ✅ 完成**（集成自测 `create → append → query → cleanup` 通过，且塔内无残留）；④ **建 2 个类型 —— ✅ 完成**（`dsh/activity`：levels `[day,week]` / auto_summarize true / summary_group_by `[proj]`；`dsh/lesson`：auto_summarize false）。**M1 全部完成并已上线**（2026-09-12）：profile 已装好（`dependencies` 加 `link:` 依赖、`dsh.profile.bundles` 追加 `dsh-mem-bridge`、`node_modules` 软链，均由官方 `dsh plugin --profile web add` 自动完成），`MOUNT OK` 预挂载通过，dsh 已重启 → **`dsh/activity` 开始实际落库**（首轮实测：`proj` 按 cwd 正确分到 `Cangjie` / `deepseek-harness` / `ystyle` 等）。首轮暴露的两个缺陷（D17 生命周期噪声/重复、D18 超时重试导致重复）已修复并提交（`ae31489`，49 个测试通过），**待下一次 dsh 重启生效**。
- **M2 —— ✅ 已完成（2026-09-12）**：插件 v0 —— L1 骨架 + L2a 自然总结，全入 activity。已实现并上线：`open`/`resume`（D17 延迟 resume）、`title`、`turn`（末条回复）、`compact`（`compaction/summary`）、`goal` 状态机、`milestone`（`subagent/end` + `workflow/end`）、`error`。**零 LLM**。
- **M3 —— ✅ 已完成（2026-09-12，commit `2991454`）**：插件 v1 —— L2b 聚合蒸馏 `close`。goal complete 触发 → 读**塔内**该会话 activity 时间线（D11）→ 一次蒸馏（模型缺省沿用宿主默认）→ `outcome`/`next`/`note`；护栏：每会话 1 次、每日 `maxDaily`、`distill=false` 可关、失败/无模型路由退化为**骨架收口**（`distilled=false`）；全程在事件分发之外跑，不阻塞 dsh。测试 49 → **58**。**已在生产实测通过（2026-09-12）**：测试 goal 的 `create` / `pause` / `resume` / `complete` 四条 `kind=goal` 精确捕获（含 `phase` 与 goal id）；标 `complete` 后 **5 秒**产出 `kind=close`，`tags.distilled=true`（**真蒸馏，非骨架**），payload 含 title / note(556 字) / outcome(321 字) / next；桥日志无告警，且不阻塞 dsh。
> **质量观察**：本次测试 goal 的 objective 是占位词（「随便定个目录」），材料又是会话时间线，故产出偏向"会话叙事"而非"围绕目标的收口"。真实目标下会更贴题；若仍偏，可调优 `DISTILL_SYSTEM`（例如强调"围绕 objective 归因"）。
- **M4 —— ✅ 已完成（2026-09-12）**：约定收口。① 工作区 `AGENTS.md` 的 `worklog` append 约定补 `session`/`agent`/`goal` 三个可选扩链 tag，并新增两节：**`dsh/activity` 全自动、禁止手写**（含各 kind 与只读回想入口）、**`dsh/lesson` 手动写入路径**（字段与 `topic` 检索）。② 验收用例 8 条逐条过：**7/8 生产实测通过，1 条（压缩边界）无数据待真实 compaction** —— 逐条结果见 §4.1。
- M5（可选）：UI / 忆时塔展示适配 `dsh/activity` 多 kind 卡片（"error → lesson 草稿开关"已由 D5 否决，移出）。

## 7. 决策点清单（v4：D1 / D7 / D12 已定案，其余待逐点拍板）

- **D1 插件形态 —— 已定案（v4）**：profile 顶层（root / 未打 scope 标签）单实例常驻（工程形态见 D15）。依据 `dsh-scope` 的 `scopeTarget` 契约：**未打标监听器全局准入**，且外层 scope 监听器收其全部后代 scope 事件（"events flow up the chain, never down"）；动态 Cordis 插件的 group 也挂在 `rootCtx`。**"每 preset 挂一行 + 宿主 service 汇聚"的退路方案删除。**
- **D2 无 goal 会话的"收口"判定 —— 已定案（v4）：先不判。** 只有 goal complete 产出 kind=close；无 goal 会话的流水由 day/week 自动总结覆盖（有了 activity 流水后，close 本就只是"聚合账"而非"补记录"）。不引入定时器，也不踩 dsh 关停时批量 dispose 的竞态；真需要会话级收口时再评估 idle 超时（`DSH_MEM_BRIDGE_IDLE_MS` 已预留）。
- **D3 去重状态 —— 已定案（v4）**：**进程内状态 + 幂等键 tag**（`session+turn` / `goal+rev` / `compactionId` / `runId`），热路径零查询零磁盘。依据：dsh 重启不重放历史事件（`session/event` 只对新 append 发射、构造种子不 emit），跨重启最多多出一条真实的 `resume`。**原"塔内回溯（插件无状态）"方案不采用。**
- **D4 轮次/子代理末条回复的入库形态 —— 已定案（v4）**：**直接截断入库**（turn 4KB / milestone 限长），**不做 LLM 压缩** —— L2a 全层保持零 LLM，"预蒸馏产物"不再被二次蒸馏。质量不足时再评估。
- **D5 lesson 是否支持 error 事件自动蒸馏草稿 —— 已定案（v4）：不做。** lesson 全靠 agent 踩坑时自报，或人工从 `dsh/activity` 的 error 条目提炼。
- **D6 塔不可用时的降级 —— 已定案（v4）**：**有界内存队列**（`DSH_MEM_BRIDGE_QUEUE_MAX`，默认 500）+ 退避重试 + 满则丢最旧 + 计数日志；**不落盘补写**。
- **D7 写入通道 —— 已定案（v4）**：进程内插件（形态见 D15）用全局 `fetch` POST `/mcp`（见 §3.4）。`ctx.web.fetch` 无 method/body 能力、动态插件沙箱 trap `fetch`，两条路均出局；无需 spike。
- **D8 `proj` tag 的自动推断 —— 已定案（v4）**：取**会话 cwd 的目录名**为 proj，另配一张**路径→proj 映射表**（`DSH_MEM_BRIDGE_PROJ_MAP`）处理例外；无 cwd 则归"未分组"。零 LLM、确定、写入时即可定值。子代理会话建议显式带 parent 的 proj + `role=subagent` tag（否则子代理会把 proj 分组搅乱）。
- **D9 类型口径 —— 已全部定案（v4）**：合一为 `dsh/activity`（2026-09-05 定案）；**纯问答轮计入** kind=turn（靠 D10 阈值）；close / milestone **只保留聚合语义，不设 agent 自报入口** —— `dsh/activity` 是纯自动账本，人工记录一律走 `worklog`。
- **D10 实质轮次过滤阈值 —— 已定案（v4）**：**「或」语义** —— 轮内工具数 ≥1 **或** 末条回复 ≥120 字（§3.5 可配；两项同时置 0 = 全量入塔）；寒暄/追问不计；`turn/end` 非 `completed`（aborted / interrupted / error）不入 kind=turn，其中 error 走 kind=error。
- **D11 L2b 聚合原料 —— 已定案（v4）**：close / goal 聚合**只用塔内 activity 条目**（turn + compact），不读会话原文；保留"读原文兜底"开关（`DSH_MEM_BRIDGE_READ_ORIGIN`，**默认关**），质量不足时再开。理由：compact 条目已含早期要点，跨压缩边界不丢信息，且 L0 边界最干净。
- **D12 上下文压缩入库口径 —— 已定案（v4）**：事实骨架（`compactionId` / `shadowedRange` / `shadowedTokenCount`）永远自动；**摘要文本截断 16KB 入塔**（`DSH_MEM_BRIDGE_COMPACT_NOTE_MAX`，dsh 已付 LLM 账，属白送总结）。事实基础：压缩产生**三个扩展 session 事件**——`compaction/start {compactionId, sourceCommandId?, turn}`、**`compaction/summary {compactionId, summary(ContentBlock[]), shadowedRange, shadowedSeqs, shadowedTokenCount, provider, model, maxTokens?, usage?}`**、`compaction/end {…, error?}`，随后一条 `user/message`（带 `surfaceOp:replace` + `sourceEventSeqs`）。**捕获点 = `compaction/summary`**。三者均不在基础 `SessionEventMap`，但都会从 `session/event` firehose 出来（`Session.append` 必 emit）→ 插件按 type 字符串宽松处理，勿依赖基础类型。见 §9.1。

- **D13 体量与 retention —— 已定案（v4，新增）**：**不设 retention**，改为加**体积监控与阈值告警**（条目数 / 桶数 / 存储体积）。理由：`retention` 是**类型级**字段，而 v3 已把 turn/session/goal 合一，"只给 turn 保留"必须拆类型、会推翻合一的收益；当前量级估算 ~200KB/天（一年 ~100MB 量级）尚可接受。忆时塔有 OOM 前科，出现增长异常时再设整类型 retention。

- **D14 自动总结粒度 —— 已定案（v4，新增）**：保持 **`day` + `week`**（忆时塔 `summary_levels` 默认即粒度链最粗两档，无需额外配置）；`summary_group_by: ["proj"]` 下每天每个活跃 proj 各一条，只对已闭合且有内容的窗口跑、不空转。

- **D15 工程形态 —— 已定案（v4，新增）**：**做成 npm 包**（本期不发布，`link:` 进 profile；用户确认公开时以 npm 包对接），而不是 profile 里的裸 `.mjs`。理由：`~/.dsh` 不在任何 git 仓库内，裸文件无历史、无测试运行环境，而本插件最需要单测的就是热路径纯逻辑；打包只多约半小时脚手架，却换来 git、单测、多 profile 单一来源、以及"以后要发布也不用重构"。**同时明确"探针 ≠ 实现"**：事件语义的未知项用丢弃型探针（优先动态 Cordis 插件）回答，探针不进实现、不长期保留。

- **D16 公开发布准备（v4 新增，已定案）**：目标形态 = **npm 包**（D15），使用定位 = **自部署**，忆时塔本体在论文之后整体公开。
  - **① sink 不做通用抽象，chronomem-only**：忆时塔本身会发布（依赖库已在中心仓），故不需要"零依赖默认 sink"来兜外部用户。仅在代码内保留一层薄的写入模块边界以便单测，**不引入 sink 接口/多实现**。
  - **② 配置面 = 插件行 `config` + `settings.installSection`（Web 设置页）**，env 降级为兜底。设置项至少：服务地址、认证 key、总开关、蒸馏开关/模型。已核实 host-only 插件可做到（见 §9.1），**无需写客户端 UI**。
  - **③ 默认开关 = 默认开启**（只自部署，可接受）；但需在设置页与 README 明确写清"会上报轮次末条回复与压缩摘要"，并且**支持 `Authorization: Bearer <key>`**（配置了才带），忆时塔后续加 key 认证即可对接（其 design §10 已列该后续项）。
- **D17 生命周期口径 —— 已定案并落地（v4 生产实测）**：**`open` 每会话只写一次；`resume` 延迟到该会话出现第一个真实事件才落库**（时间戳仍用 resume 自身）。依据：2026-09-12 重启后塔里出现 20 条 `kind=resume`、全部集中在 1 秒内 —— dsh 会为**每个被恢复的会话**发 `agent/session-start`，用户根本没碰的那些成了纯噪声；且同一会话的 session-start 可能发两次（17 个会话里 3 个被写了两遍）。落地于 `dsh-mem-bridge` commit `ae31489`。
- **D18 写入语义（不可靠传输下的重试规则）—— 已定案并落地（v4 生产实测）**：**只有"可证明未送达"的错误才重试**（`ECONNREFUSED` / `EHOSTUNREACH` / `ENETUNREACH` / `ENOTFOUND` / `EAI_AGAIN`）；**超时、连接中断、应用级错误一律不重试**，计数后丢弃。依据：实测忆时塔**约 1/8 的请求永久挂住**（12 次里 2 次卡到客户端超时，90s 仍不返回），而服务端很可能已经写入成功 —— 原先"超时也重试"正是那 3 条重复条目的来源。取舍：**缺一条远便宜于重复一条**（重复会污染每一次窗口总结）。落地于 `dsh-mem-bridge` commit `ae31489`。**注意**：该挂住是塔/传输侧的真问题（见 §9.2 末两行），需另行排查 —— 它同样影响 L3 自动总结与所有 MCP 客户端。

- **D19 忆时塔传输层修复 —— ✅ 已完成并部署（v4，根因见 §9.4，mcp-cj `f30cadc`）**：`mcp-cj` 的 streamable HTTP 传输原为「单槽位响应路由 + 无界等待」→ **并发请求 100% 挂住、顺序请求约 5~7% 挂住**，且挂住的请求其实已执行（客户端重试 = 重复写）。已按方案 (a) 落地：改为**按 JSON-RPC id 的等待队列（FIFO）+ 注册先于入队 + 有界等待（超时返回显式错误）**，并补上并发回归测试（该测试在旧实现下必 ERROR）。实测前后对照与回归覆盖见 §9.4。chronomem 已重建部署并复测通过；此项是 L3 自动总结、所有 MCP 客户端与 bridge 共同的地基。

## 8. 参考（已核实的事实来源）

- 忆时塔：`chronomem/docs/design.md` §5（类型/TypeMeta）、§5.1（levels）、§6-§7（per-type 回想与语义总结 → 类型合一动机）、`src/mcp/service.cj`（worklog 播种 schema 样例）。
- dsh 宿主：Event 目录 —— `agent/session-start`、`goal/changed`、`subagent/end`、`workflow/end`、`agent/error`、`agent/disposed`；Service 目录 —— `sessionQuery`（readSession/listEvents/readTitle/readSurface）、`goals`、`llm`、`agents`、`timer`、`sessions`、`compaction`（`CompactionResult`：compactionId/startSeq/summarySeq/endSeq/summary/shadowedSeqs/shadowedTokenCount）。
- **修正（v4）**：压缩的持久标记是**三个**扩展 session 事件（`compaction/start` / `compaction/summary` / `compaction/end`），不是两个，且摘要正文只在 `compaction/summary` 里；`CompactionResult` 只是 `ctx.compaction` 的返回值。以 §9.1 的源码核对为准。

## 9. 事实核对（v4 复核，2026-09-12，源码级）

> 复核方式：Host `Service.listService` / `Event.listEvents` / `Builtin.listBuiltins` 契约查询；dsh 安装包源码（`@deepseek-ai/dsh/node_modules/@deepseek-ai/*`）grep；运行中的忆时塔（docker `chronomem:8900`，MCP `/mcp`）实际 `tools/list` 与 `type_info`；部署 profile 文件。
> 本节的结论已回写正文（§2、§3.0、§3.1、§3.3、§3.4、§6、§7），此处保留出处，便于后续复核。

### 9.1 dsh 侧

| 结论 | 出处 | 影响的决策点 |
|---|---|---|
| 未打 scope 标签的监听器**全局准入**；打标监听器收自身及全部后代 scope 的事件，事件只向上、不向下 | `dsh-scope/lib/index.js` `scopeTarget()` 注释 | **D1 定案**：宿主级单实例可行，退路删除 |
| 动态 Cordis 插件挂在 `rootCtx` 的 `cordis-dynamic` group 下；沙箱 trap `fetch` / `require` / Node timer，数据型全局（`process` 等）为 `undefined` | `dsh-cordis-host-runner/lib/index.js`：`createSandbox()`、`NODE_API_REDIRECTS`、`requireGroup()` | 动态插件不能写塔，仅可用于采集侧验证 |
| `ctx.web.fetch` 的 `WebFetchRequest = { url: string }`，无 method / body | Host `Service.listService("web")` | 原写入候选 1 出局 |
| 压缩三事件及替换 `user/message` 的完整载荷（详见 D12） | `dsh-compaction-basic/lib/index.js`：`compactSurfaceRegion()`、`commitCompactionBody()` | **D12 事实定案**：捕获点 = `compaction/summary` |
| `session.append()` 对任意 type 都 emit `session/event`（post-commit fire-and-forget） | `dsh-session/lib/index.js` `append()` | 扩展事件（compaction/*）可订阅 |
| 事件流含 `assistant/attempt`（重试尝试） | Host `Event.listEvents` | 实现时**不得**当作 turn 边界 |
| `SessionStartSource = startup \| resume \| clear \| compact` | Host `Event.listEvents` | §3.1 open/resume 映射成立 |
| `GoalOperation` 7 种；`GoalPhase = active \| paused \| blocked \| complete`（**无 cleared**；`GoalChanged.goal` 缺失 = clear 墓碑） | Host `Event.listEvents` | §2.1 `phase` 枚举修正 |
| `SubagentRunEndInfo` 含 `lastAssistantMessage?: ContentBlock[]`、`stopReason`、`runId` | Host `Event.listEvents` | §3.1 milestone 行成立 |
| `llm.stream(GenerateOptions)` 存在；`GenerateOptions.purpose` 是封闭联合 `'compaction' \| 'session-title'` | Host `Service.listService("llm")` | L2b 可走 `llm`，但**不能**自定义 purpose |
| 部署已有本地 `.mjs` 插件先例，且 `ntfy-announce.mjs` 用全局 `fetch` 发 POST；profile 已挂 `mcp-chronomem`（`http://127.0.0.1:8900/mcp`） | `~/.dsh/profiles/web/cordis.patch.yml` 及同目录 `.mjs` | **D7 定案**；另有"复用 MCP 客户端"备选路径 |
| dsh 插件包模型：包内 `dsh.bundle.patch` 指向自己的 `cordis.patch.yml`，profile 的 `dsh.profile.bundles` 逐层套用；`dsh plugin --profile <name> add` 会自动 reconcile bundles | `dsh-better-sidebar/package.json`（`dsh.bundle.patch`）+ `dsh-app-boot` 的 bundles 解析 | **D15 定案**：本地包是官方支持的一等形态，无需发布 |

### 9.2 忆时塔侧

| 结论 | 出处 | 影响的决策点 |
|---|---|---|
| **M0 已部署并在生产验证**（2026-09-12）：重建塔容器后 `tools/list` 含 `mem/type_update`；生产冒烟 —— 同值 `levels` → 「无变化」、改值 → 拒绝并给出重建指引、类型不存在 → 拒绝、`type_info` 显示 `自动总结: true` 与 `字段描述`；数据卷未受影响（`dsh/activity` / `dsh/lesson` 均存活） | 实测 `curl :8900/mcp` 的 `tools/list` + 5 项 `type_update`/`type_info` 冒烟 | 部署方式：宿主 `cjpm build` → `~/docker/chronomem` 下 `docker compose up -d --build`（build context 即仓库；已留回滚 tag `chronomem:pre-typeupdate`） |
| `mem/type_create` **非幂等**：类型已存在即抛 `类型已存在`；`registry.updateMeta()` 有实现但**无 MCP 工具入口**，且 `updateMeta` 现状**未校验 levels** | `src/core/registry.cj` `create()` / `updateMeta()`；`src/mcp/handlers.cj` `handleTypeCreate` | 计划"M1 type_create 幂等"不成立 → **M0 已交付并部署 `mem/type_update`（禁改 levels）+ `updateMeta` 补校验**（commit `4f84ccb`） |
| `mem/query` 的 tag 过滤是**单键值**（`key=value`）；默认 20 条/页，需按提示翻页 | 运行中 `tools/list` schema | §4 注释成立；D3 去重须"按 `session=` 查 + 本地按 `turn` 过滤" |
| `MAX_APPEND_PAYLOAD_BYTES = 256KB` | `src/mcp/handlers.cj` | 4KB / 16KB 截断上限安全 |
| `levels` / `auto_summarize` / `summary_levels` / `summary_group_by`（≤2 维）齐备；容器 LLM 已配（OpenAI 兼容，`qwen3.5-9b-mtp`） | 运行中 `tools/list`；`docker inspect chronomem` | L3 自动总结前置条件满足 |
| worklog 已有 14 个 day 桶 / 3 个 week 桶 | `mem/type_info worklog` | 物化 + 自动总结链路健康 |
| **忆时塔约 1/8 的请求永久挂住**（已修复，见 §9.4）：连打 12 次 `tools/list`，2 次卡到客户端 12s 超时；放宽到 90s **仍不返回**；成功的那 10 次均 ~10ms | 2026-09-12 实测（`curl -m` 计时；容器日志无对应报错） | **根因已定位并修复**（mcp-cj 单槽位响应路由，`f30cadc`）：并发 0/8 → 8/8、顺序 5~7% 挂住 → 0 失败。此前对全计划的影响（bridge 超时重试造成重复写、L3 与所有 MCP 客户端间歇超时、集成自测偶发失败）随之解除 |
| **一次重启把 20 个被恢复的会话写成 `kind=resume`**（17 个会话 + 3 个重复），全部集中在 1 秒内 | 塔内 `mem/query tag=kind=resume` 实测 | **D17 已修**：`open` 只写一次、`resume` 延迟到该会话真的有活动才落库（未触碰的恢复会话不入塔）。那 20 条噪声已清空（清空前确认除 resume 外无任何真实条目、且当日 window 未闭合故无摘要） |

### 9.3 探针实测结论（动态 Cordis 插件 `memprb-1` + 本会话真实日志，2026-09-12）

> 方法：① 一个**纯 host 动态 Cordis 插件**（未打 scope 标签、挂在 `rootCtx` 的 `cordis-dynamic` group 下）监听 `session/event` 与生命周期事件，经动态工具 `memprobe_dump` 取回结构化结果；② `zstd -dc` 直读本会话 `~/.dsh/sessions/--home-ystyle-Projects-Cangjie--/session-<id>/session.v3.jsonl.zstd`（3 轮 / 113 条 `assistant/message` / 193 次 `tool/call` / 约 900KB）。

| 实测 | 结论 / 对计划的影响 |
|---|---|
| 未打标（root）监听器**确实收到了当前 agent 作用域**内发出的事件（含 `session.header.cwd`） | **D1 运行时证实**（不止源码推断）：全局准入成立，profile 顶层单实例即可；**D8 可行**：cwd 直接可读，无需额外查询 |
| **完成轮的最后一条 `assistant/message` 就是最终答复**：turn 1（47 步）末条 seq 274 = **4259 字**、`[reasoning,text]` 无 tool-call；turn 2（42 步）末条 seq 601 = **1879 字**、同样无 tool-call。中间步骤绝大多数 `textLen 0`，偶有 31–967 字的**过程旁白** | **§3.1 turn 规则被证实**：取"`turn/end` 前最后一条 `assistant/message`"即可；**不要**取"轮内全部 text"（会把旁白当总结）。护栏：末条无 text 时回退到最近含 text 的一条 |
| 末条回复实测 1879–4259 字 | `DSH_MEM_BRIDGE_TURN_NOTE_MAX` 默认 4000 **会截掉真实内容** → 上调 **6000**（已改 §3.5 / §2.1） |
| **`session/title` 是独立 session 事件**：`{title, messageSeqs, source}`；先落一条 fallback（首条 user 消息截断 40 字，`source.kind=fallback`），随后 LLM 标题（`source.kind=provider` + provider/model） | **计划漏洞（已补）**：`agent/session-start` 时**尚无标题**，`kind=open` 的 title 只能留空 → 新增 **`kind=title`**（§2.1） |
| **`compaction/prune`** = 工具结果裁剪 `{shadowedRange, shadowedSeqs, shadowedTokenCount}`，与语义压缩无关 | **不得**计入 `kind=compact`；忽略或另记事实 |
| **`deliverables/presented`** `{turn, callId, files}` —— `present` 工具的结构化产出清单 | L2b 的 `close.outcome` 要"产出物"，这是比从文本里猜更准的原料 → 列为可选输入 |
| 本会话 3 轮 / 900KB 内 **`compaction/*` 一次都没出现** | 压缩是**低频路径**：M2 不必对它过度投入；其载荷目前**仍只有源码证据**（`commitCompactionBody`），运行时形态**待真实压缩时验证** —— 探针 `memprb-1` 保留运行中以便捕获 |
| **忆时塔的可分发性（v4 更正）**：依赖库（mcp-cj / tsdb-cj / llm_api / cron-cj / cjxt）**均已在中心仓**，仓库里的 path 依赖只是**内部开发期便利**；发布路径 = 切 registry 版本 + cjreg / GitHub Actions 自动发布，`chronomem/docs/paper` 论文之后再整体公开。当前无鉴权（§10 已把 Bearer/OAuth 列为后续） | `chronomem/cjpm.toml`、`chronomem/docs/design.md` §10/§14 | **不构成阻塞**：bridge 可按 chronomem-only 设计；发布时序上忆时塔先行或同行 |
| `settings.installSection(owner, ns, schema, entry, hooks)` 让**纯 host 插件**把配置接进设置界面（`validate` / `setSource` / `onChange` 钩子）；`dsh-bash-local`、`dsh-permission-presets` 是无 client half 的先例 | `dsh-bash-local/lib/index.js`、`dsh-permission-presets/lib/index.js`（`dsh` 字段为 null，仅 host 半边） | **D16② 定案**：配置进 Web 设置页**无需写客户端 UI** |

### 9.4 忆时塔「请求永久挂住」的根因（2026-09-12 定位，**已确证**）

> 症状：约 7% 的**顺序**请求挂住；**并发请求 100% 挂住**（实测 10 并发 → 10/10 空响应，3 并发复现 3/3）；挂住后 90s 仍不返回，客户端超时放弃。容器内存稳定（68MB）、OS 线程 9 个（仓颉 M:N，挂住的是协程不是线程）。

**根因：`mcp-cj` 的 streamable HTTP 传输用「单槽位」承载响应，不支持并发请求，且等待循环永不放弃。**

`mcp-cj/src/transport/v2025_11_25_streamable_server.cj`：

- 状态只有 `waitingForResponse: Bool`（单个共享 bool）+ `pendingResponse: ?Array<Byte>`（单个槽位）。
- `handlePost`：① 先入队并 `recvCond.notifyAll()` → ② **之后**才置 `waitingForResponse = true` 并等待。
- `send()`：**只在 `waitingForResponse == true` 时投递**；否则若有 SSE writer 就走 SSE，**两者都没有就静默丢弃响应**。
- 等待循环 `while (pendingResponse.isNone() && !closed) { respCond.wait(timeout: 30s) }` —— 超时后**只是重新 wait**，因此任何一次响应丢失 = **永久挂住**（`{"error":"timeout"}` 分支只在 `closed` 时可达）。

两条失效路径：

1. **并发（实测 100% 失败）**：N 个连接同时在 ① 入队，消费线程（`jsonrpc` 的 `receiveLoop`，`spawn` 在独立线程）在**任何** POST 线程执行到 ② 之前就把它们全处理完 → N 个 `send()` 全部看到 `waitingForResponse == false`、`sseWriter == None` → **N 个响应全丢** → N 个线程随后进入无限等待。
2. **单请求窄窗竞态（顺序时 ~7%）**：HTTP 线程释放锁后若被调度让出，消费线程可抢在其置 ② 之前完成 `send()` → 同样丢弃。（我的探针期间还有 agent 自己的 MCP 调用/桥写入与之并发，两条路径都会命中。）

**连带影响**：

- **挂住的请求其实被执行了**（决定性实验，2026-09-12）：40 次 `mem/append` 中 38 次正常返回、**2 次挂住**；读回发现服务端**存了全部 40 条**——两条挂住的都 LANDED。即"挂住"是**纯响应投递失败**，副作用已落地。
- 因此桥的重复写得到解释与证明：桥发出 append → 服务端**执行成功**但响应丢失 → 桥超时重试 → **同一条写两遍**。故 **D18（超时绝不重试）是必需的**，不是保守选择。
- 被丢弃的响应还会让 `waitingForResponse` 残留 true，后续响应可能被**错误投递给上一个停放线程**（响应串台），进而使该请求的调用方拿到别人的结果。

**为什么历史上四次"挂住"修复都没碰到它（前因后果）**：`mcp-cj` 的"永久挂住"至少出现过三次，**修的全是触发器，从未动 `handlePost` 的请求/响应配对**——

| 修复 | 事故 | 动的地方 |
|---|---|---|
| `8a569bd`（v2.3.5） | 断连写异常杀死服务器 | `send()` 内 try/catch（SSE 写路径） |
| `18ec8b3` | 同上 + SSE 刷头 | `writer.write()` 移出锁、Accept 校验（stateless 传输） |
| `689f9fa`（v2.3.8） | SSE 长连接不回收 → CLOSE_WAIT/fd 泄漏 → OOM | `handleSSE` 心跳探测 |
| badger-cj / json-rpc（记忆 id 524） | OOM 的 `Error` 逃逸杀死 `receiveLoop` → 全挂 | 消费循环补 `catch (Error)` |

盲区有两层：

- **诊断框架盲区**：上次（id 524）的结论是"排查 MCP 挂起先区分**哪个协程死了**：只读正常+写挂=管道协程死；全挂=接收循环死"。**本例没有任何协程死亡** —— 消费循环健康、响应正常产生，只是**投递丢了**。它属于"响应投递的并发正确性"，用存活框架永远定位不到。
- **测试结构盲区**：自带 client 是**同步一问一答**（`v2025_11_25_streamable_client.cj` 的 `let resp = this.client.send(req)` 阻塞取响应），全部 e2e 都基于它 → **结构上不可能产生并发**；示例里的 `spawn` 全是 `server.serve()` / 读通知流，**没有一个"同时发两个请求"的用例**；README/docs 里也**没有任何并发约束说明**。于是"同一时刻只能有一个请求在飞"这个隐含前提**从未被写下，也从未被证伪**。
- 另注：`v2026_07_28_stateless_server.cj` 是**同一模式**（同样的 `waitingForResponse` + `pendingResponse` + 无界等待）→ 这不是"漏改一处"，而是库级的隐含假设。

**修复依据**：**生态里已有两处可照搬的正确实现**，不必重新设计——

1. `json-rpc/jsonrpc/src/client.cj`：`PendingRequest{id, response, lock, cond}` + `pendingRequests: ConcurrentHashMap<RequestId, PendingRequest>` + `waitForResponse(timeout)`，超时返回 `Result.Err("Request timeout")` 并 remove。**与 `Transport.receive/send` 的阻塞接口天然匹配**；关键顺序是**先注册 waiter 再发送**（现在 mcp-cj 正是反的 → lost wakeup）。
2. `cjxt`（`src/dom.cj` / `session.cj` / `app.cj`）：`nextDomTxId()` **服务端自造全局唯一 id**（从根上避免"多客户端都用 id=1"撞车）+ `session.pendingTx: HashMap<txId, 续体>` **按 id 的待决表**（支持多请求在飞）+ `timeout(ms, onTimeout)` 与 `dispatchDomTimeout` 的**幂等超时兜底**（命中则跑超时续体并移除；正常完成时条目已消费 → 查不到即忽略）。

顺带确认：**"长连接不回收"那条轴两边都已修完** —— `cjxt/src/app.cj` 的 WS listenLoop 注释明确写着"**与 mcp-cj SSE 长连接同款问题**"（配 `ws_conn_reclaim_test.cj` ↔ chronomem 的 `sse_conn_reclaim_test.cj`）。所以历次修复不是"漏了某一行"，而是**只覆盖了"连接生命周期"这条轴，"请求-响应配对的并发正确性"这条轴从未被纳入**。

**已落地的修法（mcp-cj `f30cadc`，v2.3.9，分支 `fix/streamable-concurrency` 已合并并删除）**：

- `pending: HashMap<id, ArrayList<PendingCall>>` —— **按 id 的 FIFO 等待队列**取代单槽位。用队列而非单值，是为了同时解决并发与**多客户端 id 撞车**（各自从 id=1 计数）：同一 id 的多个在飞请求按到达顺序配对，而消费线程严格串行处理，所以同一 id 的响应也必然按序返回。cjxt 的 `nextDomTxId` 式「服务端自造唯一 id」因 `JsonValue` 无写 API（无法改写请求体的 id）而不采用。- **注册等待槽与入队放进同一临界区**（顺序不可颠倒 —— 这是 lost wakeup 的根源）。
- 等待**有界**：`wait` 返回超时即退出，回一个带原请求 id 的显式 JSON-RPC 错误（`-32001`）；`close()` 唤醒全部在飞请求。
- 通知（无 id）现在也**入队**（旧实现直接 202 返回，`notifications/initialized` 之类永远到不了服务端）。
- `send()` 按响应 id 投递；无等待槽可投递（服务端主动通知 / `id:null` 的错误响应）才回退 SSE 或丢弃。

**前后对照（同一 chronomem 二进制，真实生产塔）**：

| 探测 | 修复前 | 修复后 |
|---|---|---|
| 并发 8（各唯一 id） | **0/8** | **8/8**（id 逐条匹配、无串台） |
| 并发 8/12（**全为 id=1**，模拟多客户端撞车） | — | **8/8、12/12** |
| 顺序 30 次 | 约 5~7% 挂住（每次 5s+） | **0 失败，0.03s** |
| 并发 40 个 `mem/append`（20 线程） | — | **40/40（0.03s），落库 40 条零重复** |

**回归测试**：`mcp-cj/src/streamable_concurrency_test.cj`（3 例：并发各 id 必须拿回自己的 id+载荷 / 并发同 id 不能丢也不能串 / 顺序回归）。**已验证该测试在旧实现下两条并发用例必然 ERROR（卡到框架超时），修复后全通过** —— 这正是当年缺的那条用例。chronomem 全套 126 测试在新传输下同样通过。

**订正（2026-07-28 stateless 传输）**：它虽有**同样的字段**（`waitingForResponse` + `pendingResponse`），但 `validatePreHeaders` 强制 `Accept` 同时包含 `application/json` 与 `text/event-stream`，而 `handlePost` 只在含 `text/event-stream` 时走**请求级 SSE** 分支 —— 因此合规客户端的可达路径一直是**按 `reqId` 配对**的（`requestStreams` + `respId`），**并未**出现 2025-11-25 那种并发 100% 挂死。其"无 SSE"同步分支对合规客户端**不可达**，已作防御性修复（去无界等待、超时返回显式错误、`close()` 唤醒全部在飞请求）；示例测试 `mcp.examples.v2026_07_28_stateless_test` 全 PASS。**残留（未改，另行评估）**：请求级 SSE 路径按客户端 id 匹配，跨客户端 id 撞车时仍可能误投递，需按连接/请求命名空间化。

### 9.5 总结 LLM 的本地推理端点特性与调参（2026-09-12，M4 顺带定位）

> 症状：一次 `mem/summarize` 任务失败，报 `Client1.1 read response timeout and the connection is closed`。它不是网络抖动，而是**推理端点特性 × 总结参数**的叠加；顺带量了这个本地端点的换模型代价，给"塔自己该用哪个模型"一个数据结论。

**端点事实**（本地 OpenAI 兼容推理端点，经 `LLM_BASE_URL` 配置）：

- 可用模型：`qwen3.5-2b` / `qwen3.5-4b` / `qwen3.5-9b` / `qwen3.5-9b-mtp` / `qwen3.8-27b` / `bonsai-27b` / `qwen3-embed`。
- **服务一次只驻留一个模型**：换模型 = 卸载 + 加载，实测 **8.7s（4b）/ 18.5s（27B）**；**命中已驻留模型时首 token 仅 0.3s**。任何一次 `qwen3-embed` 嵌入调用都会把聊天模型挤下去（embedding 与 chat 不共享驻留）。
- **`chat_template_kwargs.enable_thinking=false` 是唯一有效的关思考开关**：顶层 `enable_thinking` 字段、prompt 里加 `/no_think` 均**无效**（模型照旧思考，正文全进 `reasoning_content`）。关掉后正文才落在 `content`。

**实测（11K token 材料一次总结，冷/热）**：`2b` 27.2s / 15.7s；`4b` 61.9s / 32.4s；`9b-mtp` 135.1s / 79.3s。**prefill 占大头**，模型越大越明显；冷启动相对热的差就是换模型那 8~18s。脚本：`scripts/bench-models.py`。

**失败链条（job#1 → job#2）**：job#1 用的是**思考开 + `maxTokens=32768`**，11K 材料把思考放大成超长生成，撞上端点的 `readTimeout`（300s）→ 连接被关。改成**关思考 + `maxTokens=4096`** 后，job#2 **80s 成功**（且质量达标，验收用例 5 的 day 摘要可证）。结论：**总结这种"输入大、输出短"的任务不该开思考**，也不该给 32K 输出额度。

**落地（chronomem `5978375`，分支 `fix/summary-no-think` 已合并删除）**：`Summarizer` / `LlmSettings` 增加 `noThink` / `maxTokens` 两个旋钮，`summarize` 在 `noThink` 时注入 `extra["chat_template_kwargs"] = {"enable_thinking": false}` 并改用 `this.maxTokens`（原先硬编码 `32768`）。两个新 env（**默认可开可关、可调大小**，符合"别人用线上模型或配置更高时不该被写死"的诉求）：

| env | 默认 | 作用 |
|---|---|---|
| `CHRONOLOG_SUMMARY_NO_THINK` | `true` | 关思考；用线上模型/不需要时置 `false` |
| `CHRONOLOG_SUMMARY_MAX_TOKENS` | `4096` | 总结输出上限（原先硬编码 32768） |

**模型选型建议**：本地端点若给塔常驻总结用，**`qwen3.5-4b` 是甜点**（热 32s / 冷 62s，2b 质量偏弱、9b 及以上性价比差）；**必须固定一个模型**，别让 embedding 或别的工作流把它挤走（换一次就多付 8~18s 冷启动）。**bridge 的 L2b 收盘蒸馏不走本地端点**，它走云端 `deepseek-official/deepseek-flash` —— 因此塔的总结模型选择与 bridge 无关，互不干扰。

### 9.6 「Socket is closed.」—— 连接池死连接 + 非幂等 POST 不重试（2026-09-12/13，已修复）

> 症状：M4 收尾时补 `worklog` 当天总结，`mem/summarize` **连续 5 次全失败**，报 `ERROR: Socket is closed.`（30~70s 后失败）；窄窗口偶尔"成功"其实是**所有分组都已有总结、一次 LLM 都没调**的空转。这不是 LLM 的问题 —— 是 `llm_api` 的 HTTP 传输。

**根因链（三层，缺一不可）**：

1. **服务端**：`llama.cpp` 路由端点收到 `connection: keep-alive` 时，**响应里不带 `Connection: close`**（只回 `Keep-Alive: timeout=5, max=100`），**然后自己把连接关掉**（代理抓包：`S->C 906B` → `S->C 5B (0\r\n\r\n)` → `EOF`）。
2. **客户端库**：stdx 的 `HttpEngine1` 按 HTTP 语义把这条连接**放回连接池**（`[returnConn] return connNode to connPool`）——服务端没说 close，客户端没做存活探测。
3. **重试缺口**：下一次 POST 从池里取出这条**已死**的连接，`BufferedReader#fill` 读到 0 → `ConnectionException("Socket is closed.")`；而 `HttpEngine1#sendRequest` **只对幂等方法** `reconnectSendRequest`，POST 直接抛给调用方。

**为什么是"每隔一次必失败"**：`llm_api` 的 Provider 是**长生命周期**对象（`chronomem` 在服务启动时建一次、整个进程复用），每次调用后连接被放回池、被服务端关掉，下一次调用必踩雷、再下一次重建连接又成功。忆时塔的整窗总结要**按分组连续调多次 LLM**，于是整窗总结 100% 失败。复现（同一 Provider 连打 4 次）：`OK, ERR, OK, ERR`。

**排查弯路（值得记）**：一开始用裸 socket 抓真实响应做假端点，**复现不出来** —— 因为裸 socket 抓包时没发 `connection: keep-alive`，服务端那次就老老实实回了 `Connection: close`，客户端于是正确关连接。差异**不在响应字节，而在请求头**。教训：复刻服务端行为时要连**请求头**一起复刻，否则抓到的响应是另一条分支的产物。最终用"带日志的 TCP 代理夹在中间"一次看清了请求头、响应头与关闭时序。

**修复（`llm_api`，commit `29663ba`，合并 `9bdb3b5`）**：新增 `ResilientHttpClient`，三个 Provider（OpenAI / Anthropic / Ollama）统一使用，两条对策：

- **默认不复用连接**（`keepAlive=false`）：每个请求显式带 `Connection: close`（用户自己给了 `connection` 头则不插手）。一次 LLM 调用是秒级、一次 TCP 握手是毫秒级，代价可忽略。
- **连接级失败重试一次**（`retries=1`）：`ConnectionException` / `SocketException` 时丢弃连接池、换新连接重试；应用级错误（非 200、解析失败）不重试。

**回归测试**（`llm_api/src/provider/openai_conn_reuse_test.cj`，裸 TCP 服务端复刻"回完就关且不声明 close"）：① 连续 4 次 `chat` 全成功且用满 4 条连接（修复前 FAILED）；② 服务端收到连接后不响应即断开时，`chat` 仍成功（修复前 ERROR）。`llm_api` 74 测试全过；`chronomem` 129 测试全过。

**生产验证（2026-09-13 00:14）**：重建 chronomem 镜像并重启后 —— ① `mem/summarize {type:"worklog", 09-12 当天}` 成功（此前 5/5 失败）；② 强制多分组的窗口（09-12 19:00~22:30，`recompute=true, store=false`）**一个任务内连续 4 次 LLM 调用全部成功**（dsh-mem-bridge → mcp-cj → chronomem → cjreg，共 170s）。回滚 tag：`chronomem:pre-connreuse`。

**顺带**：诊断脚本留在 `scripts/tcp-trace-proxy.py`（带日志的 TCP 代理）与 `scripts/fake-llama-endpoint.py`（可复刻/重放端点行为的假服务端），下次查 HTTP 传输问题可直接用。

### 9.7 发版记录（2026-09-13）：json-rpc 0.7.5 / mcp-cj 2.3.9 / acp 0.2.3

按「先修 C（json-rpc 服务端主动请求配对）→ 再修 B（mcp-cj 请求级 SSE 按身份清理）→ 一起发版」的顺序执行。

**已发布**

| 包 | 版本 | 仓库/标签 | 注册表状态 |
|---|---|---|---|
| `jsonrpc` + `jsonrpc_http/_tcp/_unix/_stdio/_websocket` | 0.7.5 | gitcode `main` + tag `v0.7.5` | 6 个包 `cjpm publish success`；索引（`?organization=ystyle`）已见 0.7.5；制品端点仍 404，但 `cjpm` 能实际解析下载（acp-cj 以 `jsonrpc = "0.7.5"` 成功构建为证） |
| `mcp` | 2.3.9 | gitea `master` + tag `v2.3.9` | `cjpm publish success`；重复发布回 **409**（=服务端已登记）；但**索引与制品端点持续 404（约 20 分钟、含 `cjpm update` 后仍未出现）** |
| `acp` | 0.2.3 | atomgit `master` + tag `v0.2.3` | 发布成功，索引 + 制品（HTTP 200）均已同步 |

**下游**

- ✅ `acp-cj`：撤掉 9 处 `synchronized(clientRequestLock)` 与该字段，`jsonrpc` 依赖 0.7.4 → 0.7.5；新增回归 `agent_concurrent_reverse_requests_overlap_and_pair_by_id`（两个反向请求各 400ms，断言各自配对 + 真正重叠；加回共享锁时实测第二个请求 ~750ms，用例会失败）。**66/66 全绿**，已发 0.2.3。
- ⛔ `jisi-pavilion`（`mcp` 2.3.8 → 2.3.9）与 `atelier`（`mcp` 2.3.7 → 2.3.9）：**被注册表同步阻塞** —— `cjpm update` 后仍报 `no available version for module 'mcp' by require '2.3.9'`。两仓库均已还原，未改动。

**顺带发现的依赖约束（下一个 mcp 版本必须处理）**：`acp 0.2.3` 声明 `jsonrpc = "0.7.5"`，而 `mcp ≤ 2.3.9` 声明 `jsonrpc = "0.7.4"`；`cjpm` 按精确版本判定，因此**同一工程同时依赖 `acp 0.2.3` 与 `mcp`（任意 ≤2.3.9 版本）会报依赖冲突**（实测 atelier：`conflictions ... ystyle::jsonrpc`，仅保留 acp 0.2.3 也会冲突）。要解开，需要下一个 `mcp`（2.3.10）把 `jsonrpc` 依赖改为 `0.7.5`。

**回滚点**：镜像 tag `jisi-pavilion:pre-mcp239`（jisi 本次未重建，tag 仅为将来用）、`chronomem:pre-connreuse`；代码侧各仓库 tag 见上表。

**§9.7 补记（同日）**：`mcp 2.3.9` 的注册表同步最终完成（索引可见 + 制品 HTTP 200），此前只是同步慢（约 25 分钟），**不是**异常登记。随后完成下游：

- ✅ `jisi-pavilion`：`mcp` 2.3.8 → 2.3.9，重建生产镜像并重启 8083 容器（tag `v2.3.9` 已推 gitcode `master`）。生产验证：initialize/notifications/tools/list 握手正常、9 个工具齐全；**8 个客户端并发 `tools/list`（全部故意用 `id=7` 制造同 id 撞车）8/8 成功、0.01s**（修复前并发 100% 挂死）。回滚点 `jisi-pavilion:pre-mcp239`。
- ✅ `atelier`：`mcp` 2.3.7 → 2.3.9（355/355 全绿，已推 atomgit `master`）。**未**同时升 `acp 0.2.3`，原因见下。
- ⏳ `atelier` 的 `acp 0.2.3`：被 jsonrpc 精确版本钉死卡住 —— `acp 0.2.3` 要 `jsonrpc = "0.7.5"`，`mcp 2.3.9` 声明 `jsonrpc = "0.7.4"`，cjpm 判定冲突（实测：即使 atelier 自己写 0.7.5 也冲突）。**已本地验证解法**：下一个 `mcp` 把 jsonrpc 依赖改为**范围** `"[0.7.4, 0.8.0)"` —— 这样老消费方（chronomem/jisi/cordis-cj 仍钉 0.7.4）不受影响（chronomem 实测照常构建），同时 atelier 能吃下 `mcp + acp 0.2.3 + jsonrpc 0.7.5`（实测 355/355 全绿）。落地即可用 `mcp 2.3.10`（仅依赖声明变化，无代码改动）。

**当前各仓库依赖状态**：`mcp` 最新 2.3.9（索引+制品已同步）；`acp` 最新 0.2.3（已同步）；`jsonrpc` 最新 0.7.5（索引已同步、制品端点 404 但 cjpm 可解析）。仍钉 `jsonrpc = "0.7.4"` 的：mcp-cj、jisi-pavilion、chronomem、cordis-cj（3 个包）。

**§9.7 再补记（同日，改用 cjdep 定序）**

用户否决了「范围依赖」方案（范围会让同一份依赖在不同消费方解析出不同版本），改用**精确版本 + 按 cjdep 给出的依赖顺序发版**。`cjdep graph` / `cjdep plan -p <包>` 给出的相关链路：

```
ystyle::jsonrpc 0.7.5(已发)
  ├─→ mcp 2.3.10 ─→ atelier（registry 精确 pin，需跟进）
  │                 └→ chronomem（path 依赖，声明须同步）
  └─→ acp 0.2.3(已发) ─→ atelier
llm_api 1.1.0 ─→ atelier / chronomem（均 path 依赖）
```

据此执行（**顺序即依赖顺序，依赖先发**）：

| 序 | 包 | 版本 | 说明 | 状态 |
|---|---|---|---|---|
| 1 | `ystyle::jsonrpc`(+5 传输包) | 0.7.5 | 服务端主动请求按 id 配对 | 已发布 |
| 2 | `acp` | 0.2.3 | 撤反向调用串行锁 | 已发布 |
| 3 | `llm_api` | 1.1.0 | 连接复用修复 + 图片输入 + 消息 metadata（自 v1.0.0 起的 5 个已合并未发布提交） | 已发布（待索引同步） |
| 4 | `mcp` | 2.3.10 | 仅把 `jsonrpc` 精确声明 0.7.4 → 0.7.5，使下游能同时 pin `mcp` 与 `acp 0.2.3`；代码无改动 | 已发布（409 确认，待索引同步） |
| 5 | `chronomem` | — | 因 path 依赖 mcp，`jsonrpc` 必须同步到 0.7.5；129/129 全绿；**容器已重建部署**（回滚 tag `chronomem:pre-jsonrpc075`） | 已完成 |
| 6 | `atelier` | — | `mcp` → 2.3.10 + `acp` → 0.2.3 + `jsonrpc` → 0.7.5；本地以 path 依赖 mcp 验证 **355/355 全绿**；待 mcp 2.3.10 索引同步后改成 registry 精确版本提交 | 进行中 |

`jisi-pavilion` 停在 `mcp 2.3.9` + `jsonrpc 0.7.4`（已有全部传输修复，无 acp 需求，不必跟进 2.3.10）。

**§9.7 终版（2026-09-13，按 cjdep 拓扑顺序一次性发完）**

教训（用户指出）：**不要发一个、发现还缺一个、再回头补发同一个包**。应当先用 `cjdep` 把「这一轮要发的全部包」一次算清，按拓扑顺序（被依赖者先发）批量发完。本轮一度把 `mcp` 先发 2.3.9、又补发 2.3.10，就是没先规划全集的代价。

**最终发布集（依赖先于依赖者）**：

| 序 | 包 | 版本 | 内容 | 注册表 |
|---|---|---|---|---|
| 1 | `ystyle::jsonrpc` + `_http/_tcp/_unix/_stdio/_websocket` | 0.7.5 | 服务端主动请求按 id 配对（C） | 索引 + 制品 200（组织内模块需 `?organization=ystyle`） |
| 2 | `acp` | 0.2.3 | 撤反向调用串行锁（依赖 jsonrpc 0.7.5） | 索引 + 制品 200 |
| 3 | `llm_api` | 1.1.0 | 连接复用修复 + ImageBlock + 消息 metadata | 索引 + 制品 200 |
| 4 | `mcp` | 2.3.10 | 并发/SSE 修复（在 2.3.9）+ `jsonrpc` 精确声明 0.7.4→0.7.5 | 索引 + 制品 200 |

**消费方（同一轮内按序跟进）**：

| 序 | 仓库 | 变动 | 验证 |
|---|---|---|---|
| 5 | `chronomem` | `jsonrpc` 0.7.4→0.7.5（path 依赖 mcp 2.3.10 强制同步）；容器已重建部署（回滚 tag `chronomem:pre-jsonrpc075`） | 129/129 |
| 6 | `atelier` | `mcp` 2.3.7→2.3.10 + `acp` 0.2.2→0.2.3 + `jsonrpc` 0.7.4→0.7.5 | 355/355 |
| 7 | `jisi-pavilion` | `mcp` 2.3.8→2.3.9（已含全部传输修复；无 acp 需求，故不跟 2.3.10）；生产容器已重建 | 8 客户端并发 `tools/list` 8/8、0.01s |

**未做（明确记录，非遗漏）**：`acp-cj` 与各仓库的 `llm_api`/`mcp` 仍用 path 依赖（本地开发形态），cjdep 建议发版后转显式版本号——`chronomem`/`atelier` 按其既定约定保持 path；`atelier` 自身及其下游（liveboard / harness_* / 插件包）从未发布过，不属于本轮修复链，未发。

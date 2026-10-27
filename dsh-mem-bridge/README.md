# dsh-mem-bridge

把 dsh 会话活动**自动**落库到 [忆时塔 (chronomem)](https://atomgit.com/ystyle/chronomem) —— 无需 agent 自觉记录。

设计文档：`../docs/plans/2026-09-05-dsh-session-memory.md`（v4）。

## 它记录什么

两个类型，各自服务不同的问题：

| 类型 | levels | 装什么 |
|---|---|---|
| `dsh/activity`（默认） | `day → week` | 会话生命周期、轮次台账、压缩、目标状态机、子代理里程碑。低频运营时间线 |
| `dsh/chat`（可选） | `1h → day → week` | **全上下文工作区**里逐条记录的对话历史：真人输入、assistant 回复、工具调用 |

`dsh/activity`：

| kind | 来源 | LLM |
|---|---|---|
| `open` / `resume` | `agent/session-start` | 零 |
| `title` | session 事件 `session/title`（先 fallback、后 LLM 标题） | 零 |
| `turn` | 完成轮（`turn/end` reason=completed）的**末条** assistant 回复 | 零 |
| `compact` | `compaction/summary`（dsh 已付 LLM 账的压缩摘要） | 零 |
| `goal` | `goal/changed` 快照 | 零 |
| `milestone` | `subagent/end` 的子代理末条回复；`workflow/end` 的工作流事实骨架（`role=workflow`） | 零 |
| `error` | `agent/error` / 轮内工具错误（只记 code） | 零 |
| `close` | goal 完成后的聚合账：读**塔内**该会话的 activity 条目（D11）→ 一次蒸馏 → outcome/next/note；无模型路由或超预算时退化为**骨架收口**（`distilled=false`） | 有（可关） |
| `user` / `say` / `tool` | **写入 `dsh/chat` 而非本类型**，且仅全上下文工作区（见下节）：`user` = 真人输入的消息，`say` = 每条 assistant 回复，`tool` = 工具调用（按级别决定存多少） | 零 |

**L2b 护栏**：每会话最多 1 次 LLM 蒸馏；每日上限 `maxDaily`（默认 20）；`distill=false` 整体关闭（此时 close 仍写骨架条目）。蒸馏失败绝不阻塞、绝不重试。

### 「目标收口蒸馏」和「忆时塔自动总结」不是一回事

两个都会调用 LLM，但**切分维度不同，不能互相替代**：

| | 谁做 | 切分依据 | 触发时机 | 覆盖 |
|---|---|---|---|---|
| `auto_summarize`（塔侧） | 忆时塔后台 | **时间窗** | 窗口闭合后（过零点） | 今天 / 本周整体做了什么 |
| `distill`（本插件） | 桥调用 LLM | **目标（goal）** | 目标 `complete` 当时 | 某个目标最终做成了什么、下一步 |

一个目标可能横跨好几天，也可能同一小时里完成三个目标——按时间切和按目标切覆盖不了彼此。

**这个开关只在 goal 完成时触发**，日常问答与闲聊没有目标，所以一次都不会跑、也不产生任何调用。常用 goal 的话建议开启；不用 goal 可以关掉。

**默认永不入塔**：用户输入的消息、工具入参/出参、错误堆栈。入塔的是「预蒸馏」产物（模型自己写的末条回复、dsh 自己生成的压缩摘要）加事件自带的结构事实。

## 全上下文工作区（可选）

默认策略是「每轮只存末条回复」——写代码场景够用，但**聊天场景会丢东西**：你问了什么从来没被记录。全上下文工作区就是给这类场景开的，逐个工作区显式打开，未列出的会话行为完全不变。

配置项 `fullContextWorkspaces`（Web 面板里的**全上下文工作区**文本框），一行一个：

```
/home/ystyle/notes          # 省略级别 = names
/home/ystyle/notes/code = full
journal = none              # 只写目录名，匹配 cwd 的最后一级
```

| 级别 | 记什么 |
|---|---|
| `none` | 只存对话（`user` + `say`），完全不存工具。聊天场景用这个 |
| `names` | 加存工具名与出错标记，丢掉入参/出参 |
| `full` | 加存工具入参/出参（各自截断）。写代码场景用这个 |

匹配规则：绝对路径按前缀匹配（`/a/notes` 覆盖 `/a/notes` 与 `/a/notes/sub`，但**不**覆盖 `/a/notes-old`）；只有目录名的按最后一级精确匹配。多条命中时**最长路径优先**，所以可以「整个 notes 用 none，但 notes/code 用 full」。

### 对话历史为什么是独立类型

`dsh/activity` 与 `dsh/chat` 服务的不是一个问题，`levels` 也不该相同：

- `dsh/activity` 是**低频运营时间线**——每会话几条生命周期事件、每轮一条末条回复、goal 状态变更。`day → week` 正好。
- `dsh/chat` 是**高频对话流**——每条消息都落一条。它需要 `1h → day → week`，这样「今天下午聊了什么」可以按小时回想，而 `10min` 档对聊天频率太细（桶基本是空的）。

关键约束：**忆时塔的 `levels` 建了就不能改**（`mem/type_update` 明确拒绝）。所以两者一旦混在一个类型里，就必然有一半内容用错粒度，且无法补救。这也正是拆分的理由——只能一开始就分开。

### 类型会自动创建

桥在挂载时会确保两个类型都存在（`mem/type_create` → 若「类型已存在」→ `mem/type_update`）。所以**改了 `type` / `chatType` 不需要手动建类型**。

自愈只补 `description` / `auto_summarize` / `summary_group_by`，**不动 `levels`**：那是不可逆的，已存在的类型保持它自己的粒度链。

> 早于此版本的桥没有这段逻辑，给一个不存在的类型名会静默丢数据（每条 append 都失败并被丢弃，只有一行计数日志）。

### 为什么级别是必须的

实测一个真实会话（1265 KB）：

| 类别 | 字节 | 占比 |
|---|---:|---:|
| 工具出参 | 736 KB | 56.8% |
| 工具入参 | 334 KB | 25.7% |
| assistant 全部 | 144 KB | 11.1% |
| 注入的 user 类消息 | 77 KB | 5.9% |
| **真人输入** | **4.4 KB** | **0.34%** |

工具占 87%，而真人输入只占 0.34%。所以「全上下文」的绝大部分开销是工具，级别不是一个可有可无的旋钮。

### 注入内容不会被记录

`user/message` 事件里只有一部分是真人输入。同一会话 118 条 `user/message` 中，真人 62 条，其余 56 条是 dsh 注入的（运行时上下文、技能清单、时间上下文、工具任务通知、压缩检查点、模型选择），且**注入内容比真人输入大 17 倍**。插件只记 `source.kind === 'user'` 且 `surfaceOp === 'append'` 的条目，压缩时补发的 `replace` 副本也排除在外。

> 代价说明：全上下文工作区会把**你输入的消息原文**写进忆时塔。默认列表为空，故不配置就与旧版行为逐字节相同。

## 怎么回忆（读回写进去的东西）

桥只负责**写**；读一律走忆时塔的 `mem/*` 只读工具（零副作用，不改变任何状态）。写入的价值全在这里——会话跨天、跨上下文压缩之后，靠这些查询把"之前做过什么"捞回来。

**① 续接会话（最常用）**——按 session 拿整条时间线，是恢复上下文的首选：

```
mem/query { type: "dsh/activity", tag: "session=<dsh SessionId>" }
```

**② 看某天某项目发生了什么**——语义回顾，返回三节（轮次流水 / 生命周期与压缩 / 目标状态）。**依赖该窗口已总结**（`auto_summarize: true` 已开，日/周窗口闭合后自动产出；也可手动 `mem/summarize` 补）：

```
mem/recall { type: "dsh/activity", granularity: "day", mode: "summary", group: "<项目名>" }
```

**③ 精确下钻原始条目**——零 LLM，拿回未压缩的原文（核对细节时用）：

```
mem/recall { type: "dsh/activity", granularity: "day", mode: "exact" }
```

**③b 回看一次具体交谈**（只对全上下文工作区有数据）——`dsh/chat` 是独立类型，按小时/天/周回想：

```
mem/recall { type: "dsh/chat", granularity: "1h", mode: "exact" }      # 今天某个小时聊了什么
mem/recall { type: "dsh/chat", granularity: "day", mode: "summary" }   # 按天总结（需窗口已闭合）
mem/query  { type: "dsh/chat", tag: "session=<id>" }                   # 某个会话的完整对话流
```

**④ 按 kind 取特定流水**：

```
mem/query { type: "dsh/activity", tag: "kind=turn" }    # 轮次流水
mem/query { type: "dsh/activity", tag: "kind=goal" }    # 目标状态机（含 phase/rev）
mem/query { type: "dsh/activity", tag: "kind=close" }   # 目标收口账（含蒸馏结论）
mem/query { type: "dsh/activity", tag: "kind=error" }   # 出错记录
```

**⑤ 与人工工作日志互链**——`worklog` 是项目任务账（人工写），两者都用 `session`/`goal` tag，可交叉取回同一个会话的"自动活动"与"人工任务日志"：

```
mem/query { type: "worklog", tag: "session=<dsh SessionId>" }
```

> 时区/窗口按忆时塔的自然日历对齐（day = 本地零点、week = 周一起点）。`mem/query` 分页返回，响应头给出总页数，翻页取完即可。

## 安装

本包是标准 dsh 插件包：`package.json` 的 `dsh.bundle.patch` 指向 `cordis.patch.yml`，后者只有一行 `insert`。

```bash
# 方式一：官方 CLI（自动把包加进 profile 的 dsh.profile.bundles）
dsh plugin --profile web add dsh-mem-bridge

# 方式二：手动 —— 在 profile 的 package.json 加依赖，并把它加进 dsh.profile.bundles
# 本仓开发期从视图内联安装（路径指向本目录）：
#   "dsh-mem-bridge": "link:<path-to>/chronomem/dsh-mem-bridge"
```

profile 变更需要**重启该 profile 的 dsh 进程**才生效。

> **前置条件（重要）**：桥的"类型自愈"调用序是 `mem/type_create` →（若返回"类型已存在"）→ `mem/type_update`。
> 后者是忆时塔 `feat/type-update` 分支新增的工具；**运行中的容器镜像若早于该提交，就没有这个工具**，
> 自愈的第二条腿会失败（首次创建仍然成功）。部署方式见 chronomem `README.md` §2：
> 宿主 `cjpm build` 产出静态二进制 → `~/docker/chronomem` 下 `docker compose up -d --build`。
> 检查当前塔是否具备：`mem/list_types` 之外再看 `tools/list` 里是否有 `mem/type_update`。

## 配置

两条路都通向同一个 `Config`：

1. **Web 界面**（推荐）——侧边栏 **「插件」** 面板 → 打开本插件 → **配置**。
   表单只投影 `.volatile()` 字段，因此界面上恰好是下面标 ★ 的五项：
   **服务地址 / 认证 key / 总开关 / 蒸馏开关 / 全上下文工作区**。
   `token` 带 `secret` 角色，界面只显示"已配置/未配置"、不回传明文。
   表单**只在点保存时写入**（共享设置表单的 staged 语义），改动即时生效 ——
   volatile 字段是**活引用**，插件在每个写入点读取当前值，无需重挂载。
2. **插件行 `config` 或 `DSH_MEM_BRIDGE_*` 环境变量**——其余调优项走这里。

> ⚠️ 界面在**侧边栏「插件」面板**，不在"设置"页。设置页里的「内置插件」只有只读清单。
> 另外：`token` 是**只写**控件 —— 可以改，但界面上无法清空它（Host 用"值存在与否"
> 判断是否已配置，空串会被当作"未配置"处理）。要清空请删掉行 `config` 里的 `token`。

优先级：插件行 `config` → 环境变量 → 默认值。

| 行 config | 环境变量 | 默认 | 说明 |
|---|---|---|---|
| ★ `url` | `DSH_MEM_BRIDGE_URL` | `http://127.0.0.1:8900` | 忆时塔地址（MCP 端点为 `<url>/mcp`） |
| ★ `token` | `DSH_MEM_BRIDGE_TOKEN` | 无（视作空） | 非空则带 `Authorization: Bearer <token>`（secret；**不设 `.default('')`**，否则界面会误报"已配置"） |
| ★ `enabled` | `DSH_MEM_BRIDGE_ENABLE` | `true` | 总开关 |
| ★ `distill` | `DSH_MEM_BRIDGE_DISTILL` | `true` | 目标收口蒸馏（**仅 goal 完成时触发**，不是按时间窗总结）；`false` 时 close 只写骨架 |
| `type` | `DSH_MEM_BRIDGE_TYPE` | `dsh/activity` | 活动时间线类型（低频运营账） |
| `chatType` | `DSH_MEM_BRIDGE_CHAT_TYPE` | `dsh/chat` | 对话历史类型（全上下文工作区专用；levels `1h/day/week`） |
| `projMap` | — | `{}` | 路径前缀 → proj 覆盖表（最长前缀优先） |
| `turnNoteMax` | `DSH_MEM_BRIDGE_TURN_NOTE_MAX` | `6000` | turn 条目 note 上限（实测末条回复 1879–4259 字） |
| `compactNoteMax` | `DSH_MEM_BRIDGE_COMPACT_NOTE_MAX` | `16000` | compact 条目 note 上限 |
| `turnMinTools` | `DSH_MEM_BRIDGE_TURN_MIN_TOOLS` | `1` | 轮次计入条件一：轮内工具数 ≥ |
| `turnMinLen` | `DSH_MEM_BRIDGE_TURN_MIN_LEN` | `120` | 轮次计入条件二：末条回复 ≥ 字数；与条件一为**「或」** |
| `queueMax` | `DSH_MEM_BRIDGE_QUEUE_MAX` | `500` | 内存写入队列上限，满则丢最旧 |
| `retryMax` | `DSH_MEM_BRIDGE_RETRY_MAX` | `5` | 单条写入的最大尝试次数（含首次），用尽即丢并计数日志 |
| `retryBackoffMs` | `DSH_MEM_BRIDGE_RETRY_BACKOFF_MS` | `250` | 退避基数（毫秒，指数递增）；`0` = 不等待 |
| `distillProvider` | `DSH_MEM_BRIDGE_PROVIDER` | 空 | 蒸馏用的 provider 路由（缺省沿用宿主默认模型） |
| `distillModel` | `DSH_MEM_BRIDGE_MODEL` | 空 | 蒸馏用的模型（缺省沿用宿主默认模型） |
| `tailN` | `DSH_MEM_BRIDGE_TAIL_N` | `20` | L2b 聚合原料：取塔内该会话尾部 N 条 activity |
| `maxDaily` | `DSH_MEM_BRIDGE_MAX_DAILY` | `20` | 每日 LLM 蒸馏次数上限 |
| ★ `fullContextWorkspaces` | `DSH_MEM_BRIDGE_FULL_CONTEXT` | `[]` | 全上下文工作区列表（`[{path, level}]`；文本框里一行一个 `路径 = 级别`）。空 = 该功能不生效 |
| `sayNoteMax` | `DSH_MEM_BRIDGE_SAY_NOTE_MAX` | `20000` | 全上下文工作区里 `user`/`say` 条目的 note 上限 |
| `toolNoteMax` | `DSH_MEM_BRIDGE_TOOL_NOTE_MAX` | `2000` | `tool` 条目 note 上限（`full` 级别下入参与出参各自按此截断） |

## 开发

```bash
npm test          # 纯逻辑 + 接线 + 客户端契约单测，以及 1 个真实忆时塔集成自测（塔不可达时自动 skip）
```

集成自测只使用自己的类型 `selftest/dsh-mem-bridge`，跑完 truncate + delete，**不碰** `dsh/activity`。

分层：`lib/pure.js` 是全部可测决策（截断、末条抽取、proj 推断、条目构造、配置解析、MCP 响应解析）；`lib/index.js` 只负责事件接线与写入队列。

# dsh-mem-bridge

把 dsh 会话活动**自动**落库到 [忆时塔 (chronomem)](https://atomgit.com/ystyle/chronomem) —— 无需 agent 自觉记录。

设计文档：`../docs/plans/2026-09-05-dsh-session-memory.md`（v4）。

## 它记录什么

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

**L2b 护栏**：每会话最多 1 次 LLM 蒸馏；每日上限 `maxDaily`（默认 20）；`distill=false` 整体关闭（此时 close 仍写骨架条目）。蒸馏失败绝不阻塞、绝不重试。

**永不入塔**：消息全量原文、工具入参/出参、错误堆栈。入塔的是「预蒸馏」产物（模型自己写的末条回复、dsh 自己生成的压缩摘要）加事件自带的结构事实。

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

1. **Web 设置页**（推荐）——`设置 → 插件 → 插件配置`。表单只投影 `.volatile()` 字段，因此界面上恰好是下面标 ★ 的四项：**服务地址 / 认证 key / 总开关 / 蒸馏开关**。`token` 带 `secret` 角色，表单只显示"已设置"、不回传明文。
2. **插件行 `config` 或 `DSH_MEM_BRIDGE_*` 环境变量**——其余调优项走这里。

改动即时生效：volatile 字段是**活引用**，插件在每个写入点读取当前值，无需重挂载。

优先级：插件行 `config` → 环境变量 → 默认值。

| 行 config | 环境变量 | 默认 | 说明 |
|---|---|---|---|
| ★ `url` | `DSH_MEM_BRIDGE_URL` | `http://127.0.0.1:8900` | 忆时塔地址（MCP 端点为 `<url>/mcp`） |
| ★ `token` | `DSH_MEM_BRIDGE_TOKEN` | 空 | 非空则带 `Authorization: Bearer <token>`（secret） |
| ★ `enabled` | `DSH_MEM_BRIDGE_ENABLE` | `true` | 总开关 |
| ★ `distill` | `DSH_MEM_BRIDGE_DISTILL` | `true` | L2b 聚合蒸馏总开关；`false` 时 close 只写骨架 |
| `type` | `DSH_MEM_BRIDGE_TYPE` | `dsh/activity` | 写入的记忆类型 |
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

## 开发

```bash
npm test          # 30 个纯逻辑单测 + 1 个真实忆时塔集成自测（塔不可达时自动 skip）
```

集成自测只使用自己的类型 `selftest/dsh-mem-bridge`，跑完 truncate + delete，**不碰** `dsh/activity`。

分层：`lib/pure.js` 是全部可测决策（截断、末条抽取、proj 推断、条目构造、配置解析、MCP 响应解析）；`lib/index.js` 只负责事件接线与写入队列。

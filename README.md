# dsh-mem-bridge

把 dsh 会话活动**自动**落库到 [忆时塔 (chronomem)](https://git.mini.ystyle.top:2024/ystyle/chronomem) —— 无需 agent 自觉记录。

设计文档：`../docs/plans/2026-09-05-dsh-session-memory.md`（v4）。

## 它记录什么

| kind | 来源 | LLM |
|---|---|---|
| `open` / `resume` | `agent/session-start` | 零 |
| `title` | session 事件 `session/title`（先 fallback、后 LLM 标题） | 零 |
| `turn` | 完成轮（`turn/end` reason=completed）的**末条** assistant 回复 | 零 |
| `compact` | `compaction/summary`（dsh 已付 LLM 账的压缩摘要） | 零 |
| `goal` | `goal/changed` 快照 | 零 |
| `milestone` | `subagent/end` 的子代理末条回复 | 零 |
| `error` | `agent/error` / 轮内工具错误（只记 code） | 零 |
| `close` | goal 完成后的聚合账（✅ 计划中，尚未实现） | 有 |

**永不入塔**：消息全量原文、工具入参/出参、错误堆栈。入塔的是「预蒸馏」产物（模型自己写的末条回复、dsh 自己生成的压缩摘要）加事件自带的结构事实。

## 安装（尚未接入 profile）

本包是标准 dsh 插件包：`package.json` 的 `dsh.bundle.patch` 指向 `cordis.patch.yml`，后者只有一行 `insert`。

```bash
# 方式一：官方 CLI（自动把包加进 profile 的 dsh.profile.bundles）
dsh plugin --profile web add dsh-mem-bridge

# 方式二：手动 —— 在 profile 的 package.json 加依赖，并把它加进 dsh.profile.bundles
```

profile 变更需要**重启该 profile 的 dsh 进程**才生效。

> **前置条件（重要）**：桥的"类型自愈"调用序是 `mem/type_create` →（若返回"类型已存在"）→ `mem/type_update`。
> 后者是忆时塔 `feat/type-update` 分支新增的工具；**运行中的容器镜像若早于该提交，就没有这个工具**，
> 自愈的第二条腿会失败（首次创建仍然成功）。部署方式见 chronomem `README.md` §2：
> 宿主 `cjpm build` 产出静态二进制 → `~/docker/chronomem` 下 `docker compose up -d --build`。
> 检查当前塔是否具备：`mem/list_types` 之外再看 `tools/list` 里是否有 `mem/type_update`。

## 配置

按优先级：插件行 `config` → `DSH_MEM_BRIDGE_*` 环境变量 → 默认值。

| 行 config | 环境变量 | 默认 | 说明 |
|---|---|---|---|
| `url` | `DSH_MEM_BRIDGE_URL` | `http://127.0.0.1:8900` | 忆时塔地址（MCP 端点为 `<url>/mcp`） |
| `token` | `DSH_MEM_BRIDGE_TOKEN` | 空 | 非空则带 `Authorization: Bearer <token>` |
| `enabled` | `DSH_MEM_BRIDGE_ENABLE` | `true` | 总开关 |
| `type` | `DSH_MEM_BRIDGE_TYPE` | `dsh/activity` | 写入的记忆类型 |
| `projMap` | — | `{}` | 路径前缀 → proj 覆盖表（最长前缀优先） |
| `turnNoteMax` | `DSH_MEM_BRIDGE_TURN_NOTE_MAX` | `6000` | turn 条目 note 上限（实测末条回复 1879–4259 字） |
| `compactNoteMax` | `DSH_MEM_BRIDGE_COMPACT_NOTE_MAX` | `16000` | compact 条目 note 上限 |
| `turnMinTools` | `DSH_MEM_BRIDGE_TURN_MIN_TOOLS` | `1` | 轮次计入条件一：轮内工具数 ≥ |
| `turnMinLen` | `DSH_MEM_BRIDGE_TURN_MIN_LEN` | `120` | 轮次计入条件二：末条回复 ≥ 字数；与条件一为**「或」** |
| `queueMax` | `DSH_MEM_BRIDGE_QUEUE_MAX` | `500` | 内存写入队列上限，满则丢最旧 |
| `retryMax` | `DSH_MEM_BRIDGE_RETRY_MAX` | `5` | 单条写入的最大尝试次数（含首次），用尽即丢并计数日志 |
| `retryBackoffMs` | `DSH_MEM_BRIDGE_RETRY_BACKOFF_MS` | `250` | 退避基数（毫秒，指数递增）；`0` = 不等待 |

## 开发

```bash
npm test          # 30 个纯逻辑单测 + 1 个真实忆时塔集成自测（塔不可达时自动 skip）
```

集成自测只使用自己的类型 `selftest/dsh-mem-bridge`，跑完 truncate + delete，**不碰** `dsh/activity`。

分层：`lib/pure.js` 是全部可测决策（截断、末条抽取、proj 推断、条目构造、配置解析、MCP 响应解析）；`lib/index.js` 只负责事件接线与写入队列。

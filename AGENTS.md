# 忆时塔（chronomem）工程指南

> **定位**：分层时间记忆（回想 + 语义总结）的 MCP 服务。技术规格见 `docs/design.md`。

## 心智模型（后续 agent 必须对齐）

- **塔 = 分层**：记忆按时间堆叠，一层一个物化粒度；每类型自定义 levels（§5.1）。
- **记忆类型 = 一条 series**：`<type>` 原始条目 + `<type>.summary` 语义总结 + `meta` 注册表。
- **回想两档**：`exact` 下钻原始（零 LLM）；`summary` 语义回顾（**前提是已总结**，有 LLM 成本）。**「回想零 LLM」只对精确下钻成立**。
- **上下文恒定**：只「存 + 查」，永不主动塞回客户端上下文。

## 仓颉语言

- 语法问题使用 `cangjie_docs` 相关工具查找，不要猜 API 和语法
- `match` 的 `case` 后不能接 `{}`
- 固定结构类实现 `json.stream` 序列化接口（TypeMeta / SummaryRecord）；动态字段（payload / 工具参数）才用 jsonvalue

## 任务指南

- **不要考虑时间，不要简化算法，不要简化测试，这是自己的产品**
- 新功能先写单元测试（TDD）；有测试后再提交
- 分层：`chronomem.core`（框架）不依赖 `chronomem.mcp`；`mcp` 层负责从 env 装配（ChronomemConfig → LlmSettings）

## Git 分支流程

- 开发开 `feat/<name>` 分支，功能完成后合并回 master 并删除分支
- 每次开工前 `git pull`

## 常用命令

```bash
eval "$(cjvs env bash)" && eval "$(cjvs stdx-env bash)"
cjpm build -j 16
cjpm test -j 16 --no-progress
cjpm test --show-all-output --filter 'TestName.*'
```

## 运行

```bash
CHRONOLOG_DIR=~/.chronolog CHRONOLOG_PORT=8900 \
LLM_BASE_URL=... LLM_API_KEY=... LLM_MODEL=... \
./target/release/bin/chronomem.cli serve
```

## LSP 报错

- 源码文件：`cjpm build`
- 测试文件：`cjpm test --no-run`

## 已知坑位

- **`tsdb` 保留前缀 `__` / `s:` / `b:`**：注册表 series 用 `meta`，类型名不得以 `__` 开头或等于 `meta`。
- **`TimelineStore` 字段 `tsdb` 与方法 `tsdb()` 同名冲突**：访问器命名 `rawTsdb()`。
- **`Rune` 比较**：字符字面量在仓颉是 String，需 `UInt32(rune)` 转数值比较。
- **`@Expect` 需 Equatable**：`Option<非Equatable>` 不能直接与 None 比较，用 match。
- **默认参数**用 `name!: Type = default` 命名参数语法，调用须带 `name:` 前缀。
- **`Duration(second, nanosecond)` 第二参是 `UInt32`**：`Duration(8*3600, 0)` 编译不过，用 `Duration.hour * 8` 或 `0u32`。
- **自然窗口（§5.2）**：day/week/month 按日历对齐（`CHRONOLOG_TIMEZONE`），桶 key 用 `windowKeyOf`（非 tsdb.bucketKeyOf）；只有 10min/30min/1h/3h 才用 `ts % windowMs`。
- **cron-cj 增量缓存损坏**：`cjpm build` 报 `DataModelException: This data is not DataModelSeq` 时 `cjpm clean` 可解（badgercj 同样出现过）。
- **cron `@every` 描述符**：cron-cj 的 `addFunc` 不解析 `@every <dur>`，需走 `addCronEntry`（→ `Every()` + `addSchedule`）。
- **Docker 部署**：镜像内绑 `0.0.0.0`（`CHRONOLOG_ADDR`，否则端口映射连不上）；compose 栈数据目录 `~/docker/chronomem/data` 先建好并 chown 1000:1000 再 up（docker 自动建会 root/nobody）；`--static` 只消除 libcangjie-runtime 依赖，glibc/liburing 仍需 archlinux + `liburing` 包。
- **`--static` 仅对可执行文件生效**：库包会出现无害 warning（-Woff driver-arg 可压）。
- **`-lstdx.crypto.digest`**：stdx.net.http 链接符号，chronomem [package] link-option 已带。

## 私有项目声明

- **本项目为私有/内部项目，不发布到仓颉中心仓（禁止 `cjpm publish`）**。
- 依赖以 path 方式引用本地库（`mcp-cj` / `tsdb-cj` / `llm_api` / `cron-cj` / `cjxt` 等），另引用中心仓库（`jsonvalue` / `ystyle::jsonrpc`）。
- 中心仓库（如 `badgercj`）升级后，按需同步本仓库依赖版本即可，**不因此发布本项目**；若依赖的本地库（如 `tsdb-cj`）需发版，由其仓库自行发布，本仓库只改 path/版本引用。

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
- **`--static` 仅对可执行文件生效**：库包会出现无害 warning（-Woff driver-arg 可压）。
- **`-lstdx.crypto.digest`**：stdx.net.http 链接符号，chronomem [package] link-option 已带。

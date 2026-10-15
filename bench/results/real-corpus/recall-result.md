# 忆时塔（chronomem）· 2026-09 中旬回忆检索结果

> **唯一信息源**：忆时塔 MCP（`http://127.0.0.1:8900/mcp`），类型 `worklog` / `dsh/activity` / `dsh/lesson`。
> 未读项目文件、未联网、未使用先验知识；未写入任何条目（只读检索）。
> 时区按题面 UTC+8 日历对齐：09-13=`1789228800000`、09-14=`1789315200000`、09-15=`1789401600000`、09-16=`1789488000000`。

### Q1
答案：**2026-09-15 忆时塔第三次写路径 OOM 事故**（当日前两次同签名，本次为第三次）。
- **根因**：**不是内存泄漏，而是瞬时分配峰值顶爆默认堆上限 + 物化不幂等放大写入**。
  - 事故签名是「**空 message 异常**」：badger `WritePipeline markFailed(e.message)` → `commitOrThrow` 抛 `Exception("")`。现场表现为 17:25 起 materialize 每轮 `Job 0 failed`、`mem/append` 全失败、读正常、重启即好。
  - `MRT_REPORT` GC 日志给出硬数据：**存活量仅 30-60MB（无泄漏）**，但**瞬时分配峰值到 217-240MB**，距仓颉默认 **256MB** 上限只剩十几 MB —— 启动 / 物化 / 总结的分配峰值就是触发点。判据用的是 live bytes（30-60MB）而非 Current allocated（217-240MB，含未回收垃圾）。
  - 同时 `materialize` **不幂等**：此前每 60s 零新增也重写一份桶，写放大直接变成每分钟一次 memtable rotate/flush/compaction（事故现场 **LSM 文件号 18 小时涨 ~940**）。
  - 反向证伪：fd=10（曾 1009）、CLOSE_WAIT=0（曾 662）→ 连接泄漏方向排除。
- **两项修复**：① **写入侧**把 `materialize` 做成**幂等**——窗口内容与已落盘桶一致则不重写，上层链只在子桶集合变化时重写；② **内存侧**把 compose 里 `cjHeapSize` 由默认 **256MB 提到 1GB**（按实测留约 4 倍余量，是**扩容而不是缩**）。
- **（附带第三项，不属「两项修复」）**：诊断侧用 badgercj 1.6.20 让失败文案带出 Error 类型并标注「系统级错误」，空 message 不再吞掉 OOM 身份；并开 GC 日志 / 堆转储。

依据（09-15 原始条目原话）：
> `[09-15 20:49:55] "root cause确认…② 打开 MRT_REPORT GC 日志后取到硬数据：存活量仅 30-60MB（无泄漏），但瞬时分配峰值到 217-240MB，距仓颉默认 256MB 上限只剩十几 MB —— 启动/物化/总结的分配峰值就是触发点；③ 修复：chronomem 把 materialize 做成**幂等**（窗口内容与已落盘桶一致则不重写；上层链只在子桶集合变化时重写）——此前每 60s 零新增也重写一份桶，写放大直接变成每分钟一次 memtable rotate/flush/compaction（事故现场 LSM 文件号 18 小时涨 ~940）；部署后 LSM 文件号不再每分钟涨。④ 容量：compose 里 cjHeapSize 由默认 256MB 提到 1GB（存活量 30-60MB、峰值 240MB，256MB 无余量）。⑤ 诊断：badger-cj 1.6.20 让失败文案带出 Error 类型…⑥ 证伪连接泄漏方向：fd=10（曾 1009）、CLOSE_WAIT=0（曾 662）。"`

> `[09-15 23:15:14] {"task":"忆时塔写路径事故（第三次 OOM）修复 + 依赖收敛到 badgercj 1.6.20/jsonrpc 0.7.6", "outcome":"物化幂等修复（窗口内容未变不重写桶）+ 堆上限调到 1GB + 开 GC 日志/堆转储后，写路径恢复正常…重启后 mem/append 正常、GC 日志在写、sst 文件数 86 且不增长", "decisions":"（1）空 message 的异常一律按 OOM 处理…（2）批量/轮询类维护任务必须幂等…（3）判断内存看 live bytes（30-60MB）而不是 Current allocated（217-240MB，含未回收垃圾），256MB 上限是被回收前的峰值顶爆的，所以 cap 提到 1GB 而不是缩。"}`

路径：`mem/recall {type:"worklog", granularity:"day", mode:"exact", windowStartMs:1789401600000}`（09-15 当天 12 条，命中 20:49:55 与 23:15:14 两笔）；同窗口 `mode:"summary"` 可交叉核对。
把握：**高**（exact 两笔互证；summary 亦复述同一根因与两项修复）

### Q2
答案：cjreg 的索引等待 / 重试节奏改为 **5s → 1m → 3m → 5m → 之后每 5m**（对齐 cangjie-publish 的 1/3/5 分钟重试，另加一个 **5s 首探**给同进程私有仓用）；**默认超时 = 0，即不超时**（`pollTimeout=0`）。旧行为是「每 `pollInterval`=60s 探一次、`pollTimeout`=600s 到点放弃」，旧的出厂默认 60/600 在启动恢复时**迁移为 0**（一直等）并打日志，用户改过的不动。
- **为什么这么定**：① **等待节奏固定、不作为配置项**——「配置化只会让人调错，中心仓的快慢不是用户能控的」；② **默认不超时**——「中心仓同步几十分钟到几天是常态，超时判失败既不准确也无意义」，只留一个可选上限作保险丝（0 = 不限）；③ **收工只认三种**：就绪（查到）/ 用户停止 / 探测本身失败（400/401/403/429/5xx/网络，对齐官方返回码表），其中 401/403/429 暂停整个计划、5xx/网络只卡这一项；④ **探测必须带状态码**：旧的 `?String` 把 404 与 401/5xx 抹平成同一个 `None`，「还没同步到」与「根本没问到」行为一样、404 还会被误算成"取不到"，故新增 `IndexProbe`（状态码+正文+fatal/planFatal）+ `httpGetWithStatus` + `ProxyService.probeUpstreamIndex`，把 404（目标仓确实没有 → 继续等且对照列显「无此包」）与 401/403/429/5xx/网络（没问到 → 记「未对照」并在计划级说明里带状态码）分开。

依据：
> `[09-15 01:26:42] {"task":"cjreg 索引等待/重试规则改为 1/3/5→每5分钟且默认不超时；详情页显示推送与索引时间", "decisions":"① **等待节奏固定、不作为配置项**（5s→1m→3m→5m→每5m）：配置化只会让人调错，中心仓的快慢不是用户能控的；② **默认不超时**：中心仓同步几十分钟到几天是常态，超时判失败既不准确也无意义；留一个可选上限作保险丝（0 = 不限）；③ **收工只认三种**：就绪 / 用户停止 / 探测本身失败（400/401/403/429/5xx/网络，对齐官方返回码表）；401/403/429 暂停整个计划（与推送阶段同判据），5xx/网络只卡这一项；④ **探测必须带状态码**：`?String` 把 404 与 401/5xx 抹平成同一个 None…⑤ 时间列取「推送」与「索引生效」…⑥ 旧计划的出厂默认（60/600）启动时迁移为 0（一直等），用户改过的不动。", "outcome":"…① 旧行为核实并写清（每 pollInterval=60s 探一次、pollTimeout=600s 到点放弃；界面两个字段）；② 新节奏 5s→1m→3m→5m→每 5m（对齐 cangjie-publish 的 1/3/5 分钟重试，多一个 5s 首探给同进程私有仓），**默认不超时**（pollTimeout=0），只有查到 / 用户停止 / 探测失败才收工…"}`

路径：`mem/recall {type:"worklog", granularity:"day", mode:"exact", windowStartMs:1789401600000}`（条目 01:26:42）；同窗口 summary 的【cjreg】节亦有（表述较粗）。
把握：**高**（exact 给出节奏、默认值、理由三层）

### Q3
答案：
- **前端产品名改成「星痕的炼金工房」**（英文产品名 Atelier Starline）。共改**前端三处用户可见**旧名：`web/index.html` 浏览器标题（`Liveboard 桌面` → `星痕的炼金工房`）、`web/src/auth/Login.svelte` 与 `web/src/auth/Init.svelte` 的 `h1`（后者为「初始化星痕的炼金工房」）。文案取中文品牌名（与成品层命名一致、与 atelier-lumine 那套「荧的炼金工房」同构），**不动英文 id**。
- **有意不改**：① 类型类名 **`LiveboardWs`**（构架层 WS 客户端）；② 两个 **localStorage 键** `liveboard.session` / `liveboard.windowLayout`。
- **为什么**：沿用「名字跟着东西的性质走」的判据——**界面文案属产品（改），类型名属构架（留）**，要分开看；存储键沿用「**改名不改键**」惯例，否则**已登录用户被踢下线、窗口布局丢失**。
- 验证：前端 vitest **161/161 全绿**（先确认测试未断言品牌文案，只用到类型名与存储键）；`npm run build` 后 `dist/index.html` 标题已新、新品牌串在 bundle 中恰好 2 处（两个 h1）、旧界面文案已无、两个存储键保留。已合并推送（ab08006..dfac09e）。

依据：
> `[09-14 17:58:53] {"task":"atelier-starline 前端界面产品名改为「星痕的炼金工房」", "decisions":"文案取中文品牌名「星痕的炼金工房」（与成品层命名一致、与 atelier-lumine 那套「荧的炼金工房」同构）；不动英文 id。保留判据仍沿用"名字跟着东西的性质走"：界面文案（产品，改）与类型名 LiveboardWs（构架，留）要分开看。localStorage 键沿用改名不改键贯例。", "outcome":"把前端三处**用户可见**的旧产品名改成「星痕的炼金工房」：web/index.html 浏览器标题（Liveboard 桌面 → 星痕的炼金工房）、web/src/auth/Login.svelte 与 Init.svelte 的 h1（后者为「初始化星痕的炼金工房」）。有意不改：类型类名 LiveboardWs（构架层 WS 客户端）与两个 localStorage 键 liveboard.session / liveboard.windowLayout（改名不改键，否则已登录用户被踢下线、窗口布局丢失）。验证：前端 vitest **161/161 全绿**…"}`

路径：`mem/recall {type:"worklog", granularity:"day", mode:"exact", windowStartMs:1789315200000}`（09-14 当天，任务名直接命中）。
把握：**高**（exact 给出三处位置、两个键名与理由）

### Q4
答案：文档里最终确定的正确表述是 —— **产品大量采用的是「分层时间记忆」这个「模式」，不是直接调用忆时塔服务；忆时塔（chronomem）是这套做法的试验场**，将来是否复用其代码 / 接它的服务看实现再定。
- 原文错误表述是「本产品会大量使用忆时塔」，按用户纠正后改写；**README 与 AGENTS.md 两处同名行均已改**（措辞各按本表列名调整）。
- 判据（为什么这么说）：区分「采用某**模式**」与「调用某**服务**」—— 物化桶链 / 精确回想 / 语义总结这套做法是**构架层 `Timeline` 的能力**，忆时塔只是把它泛化成独立 MCP 服务的一个试验场。两种实现路径（**构架内自实现 / 复用 chronomem 代码 / 调它的服务**）当时尚未定。
- 同一命名的结构性表述（三名字分工）：`Atelier Starline`（产品）/ `liveboard`（构架层：`src/core`+`src/builtin`）/ `忆时塔 chronomem`（分层时间记忆 MCP 服务）。

依据：
> `[09-14 17:57:43] {"task":"校正 atelier-starline 文档：忆时塔关系表述 + 依赖表/项目结构与现状对齐", "decisions":"表述准确性的判据：区分「采用某**模式**」与「调用某**服务**」——物化桶链/精确回想/语义总结这套做法是构架层 `Timeline` 的能力，忆时塔只是把它泛化成独立 MCP 服务的一个试验场；产品要大量采用前者，两种实现路径（构架内自实现 / 复用 chronomem 代码 / 调它的服务）尚未定。", "outcome":"按用户纠正修正文档中的错误表述：原文写「本产品会大量使用忆时塔」不准确，已改为「产品大量采用的是「分层时间记忆」这个**模式**，**不是**直接调用忆时塔服务；忆时塔是这套做法的试验场，将来是否复用其代码 / 接服务看实现再定」——README 与 AGENTS.md 两处同名行均已改…已推送（f193dfd..ab08006）。"}`

> 旁证 `[09-14 17:44:52]`：命名法「名字跟着「东西的性质」走，不跟着仓库走」→ 三个名字的分工：Atelier Starline（产品）/ liveboard（构架层）/ 忆时塔 chronomem。

路径：`mem/query {type:"worklog", tag:"proj=atelier-starline"}` / `mem/recall worklog/day/exact@09-14`；`mem/recall worklog/day/summary@09-14`（group=atelier-starline）也复述了「明确产品采用的是『分层时间记忆』模式，而非直接调用服务」，但丢了「试验场 / 路径未定」这一层。
把握：**高**

### Q5
答案：**根因是总结 prompt 没有输入预算护栏，超大 compact payload 撑爆 LLM 上下文**。
- `Summarizer.buildPrompt` 把窗口内条目**完整 payload 原文**拼进 prompt（**无截断、无 token 预算**）。
- `dsh-mem-bridge` 的 `kind=compact` 条目 `note` 上限 **16000 字符**，活跃会话一天有多个 compact（09-13 窗口 4 个、09-15 窗口 3 个）→ 分组 prompt 超过 llama.cpp 端点 **32768 token** 上下文 → **400 `exceed_context_size_error`** → 任务 **failed 且不落库** → **调度器每 10 分钟重试，永远失败**（原先无限重试）。
- **实测硬证据**：手动 `mem/summarize` 09-15 窗口 job #3 报 `request (35489 tokens) exceeds 32768`。
- **对照组**：`worklog` 同窗口总结正常（payload 小）；UI（8900 控制台 `/summary` 页）与 MCP `mem/summaries` 数据源一致（都读 `<type>.summary`），**不是双实现不一致**。

依据（`dsh/lesson`，topic=summarize，写于 09-16 01:16:14）：
> `{"title":"语义总结 prompt 无预算控制：超大 compact payload 撑爆 LLM 上下文，dsh/activity 自动总结连续失败", "context":"dsh/activity 的 day 级自动总结自 09-13 起连续三天（09-13/14/15）全部失败；worklog 同窗口正常。UI（8900 Web 控制台）与 MCP mem/summaries 数据源一致（都读 <type>.summary），非双实现不一致。", "cause":"Summarizer.buildPrompt 把窗口内条目完整 payload 原文拼进 prompt（无截断/无 token 预算）；dsh-mem-bridge 的 kind=compact 条目 note 上限 16000 字符，活跃会话一天多个 compact（09-13 窗口 4 个、09-15 窗口 3 个）→ 分组 prompt 超 llama.cpp 端点 32768 token 上下文 → 400 exceed_context_size_error → 任务 failed 无落库 → 调度器每 10 分钟重试永远失败。实测：手动 mem/summarize 09-15 窗口 job #3 报 request (35489 tokens) exceeds 32768。", "fix":"（建议）Summarizer 增加输入预算管理…", "prevention":"总结路径必须有 token 预算护栏；大 payload 类型（dsh/activity 的 compact）不能全量进 prompt；调度器对反复失败的窗口应告警而非无限重试。", "ref":"chronomem summarize_runner.cj execute→failed；handlers.cj doSummarize→buildPrompt（summarizer.cj）；dsh-mem-bridge lib/pure.js compactEntry note=clipText(summaryText,16000)"}`

对应 worklog 条目：
> `[09-16 01:16:14] {"task":"审阅忆时塔设计/README 与近几天总结", "outcome":"…② 发现 dsh/activity 09-13/14/15 day 级总结全部缺失，根因确认：compact 条目 payload（note≤16000 字符）全量进总结 prompt，超 llama.cpp 32768 token 上下文 → LLM 400 → 任务 failed → 调度器无限重试；③ UI（8900 控制台 /summary 页切到 dsh/activity）实测与 MCP 数据一致，仅 09-12 窗口 6 条；worklog 同窗口总结正常（对照组）；④ 已写 dsh/lesson（topic=summarize）。"}`

修复侧印证（同一窗口后续条目）：`[09-16 04:05:29]` 定位并修复「窗口材料超过端点处理能力 → 总结永久失败 → 调度器每 10 分钟无限重试」，引入 `CHRONOLOG_SUMMARY_CONTEXT_TOKENS` 输入预算、map-reduce 按条目边界切块、退避 20min→60min 且连续 3 次放弃；随后生产**补齐三天**（09-14/09-15/09-13 落库，chunked 2/2/6 段）。

路径：`mem/query {type:"dsh/lesson", tag:"topic=summarize"}`（结构化 cause 全文，最有价值）+ `mem/recall dsh|worklog day/exact@09-16`。旁证：`mem/summaries {type:"dsh/activity"}` 印证 09-13 之前只有 09-12 窗口、三天空缺。
把握：**高**

### Q6
答案：同一份材料（**09-15 窗口 23 条 / 112,780 字节 ≈ 37.5K token**）、同一套新代码与参数（**thinking off、MAX_TOKENS 4096**）、端点空闲下做 A/B：
- **qwen3.5-4b**：✅ **done** —— **chunked 2 段 + 聚合，五节完整、无截断**。冷 prefill（`cache_prompt=false`，17,785 token）**56.0s ≈ 317 tok/s**。上下文窗口 131072。
- **qwen3.5-9b-mtp**：❌ **failed** —— **连续 3 次收缩预算后仍 `Client1.1 read response timeout`**。冷 prefill（同条件 17,785 token）**65.9s ≈ 267 tok/s**。上下文窗口 32768。
- 结论：**维持生产切 qwen3.5-4b**（保留一行 env 回退）；9b-mtp 若要用作总结模型需**同步调小 `MAX_TOKENS` 或调大 `READ_TIMEOUT`**（否则 4096 token 级摘要会撑满读超时）。
- 质量侧保留：质量对照发现 4b 在 09-12 样本上把「提议但未采纳的设计」当成已实现，但样本两边都被 700 token 截断、证据不足，待多窗口不截断复评。

依据：
> `[09-16 04:29:48] {"task":"总结模型 A/B：qwen3.5-4b vs qwen3.5-9b-mtp（09-15 窗口）", "status":"完成", "outcome":"同一份材料（09-15 窗口 23 条 / 112,780 字节 ≈ 37.5K token）、同一套新代码与参数（thinking off、MAX_TOKENS 4096）、端点空闲下做 A/B：qwen3.5-4b ✅ done（chunked 2 段 + 聚合，五节完整无截断）；qwen3.5-9b-mtp ❌ failed（连续 3 次收缩预算后仍 Client1.1 read response timeout）。另量得冷 prefill（cache_prompt=false，17,785 token）：4b 56.0s（≈317 tok/s） vs 9b-mtp 65.9s（≈267 tok/s）。", "decisions":"维持生产切 qwen3.5-4b；9b-mtp 若要用作总结模型需同步调小 MAX_TOKENS 或调大 READ_TIMEOUT（否则 4096 token 级摘要会撑满读超时）。"}`

旁证 `[09-16 04:05:29]`：`模型切 qwen3.5-4b（ctx 131072；实测 prefill 317 tok/s vs 9b-mtp 267），但保留一行 env 回退`；并给出「实测 llama-swap preset：**9b-mtp/9b=32768、4b/2b=131072**」。

路径：`mem/recall {type:"worklog", granularity:"day", mode:"exact", windowStartMs:1789488000000}`（09-16 当天条目，数字最全）。
把握：**高**

## 检索过程观察

**1) 哪些问题 exact 能答、哪些只能靠 summary？**
- **六个问题全部由 exact（原始条目）答出**，且 **exact 是唯一能给出精确数字与原话的档位**。定位手段：主要用 `mem/recall {type, granularity:"day", mode:"exact", windowStartMs}` 按天整窗拉取（09-15 仅 12 条、09-16 仅 9 条），再在结果里检索关键词；Q5 另外用了 `mem/query {type:"dsh/lesson", tag:"topic=summarize"}`。
- **summary 在这批问题上只够当「交叉核对」，不能当唯一依据**：
  - Q1 / Q2 / Q3 / Q4 的 day 级 summary 能给出主干结论（如 Q1 的「峰值逼近 256MB 上限 + 物化不幂等」「cap 256MB→1GB」，Q2 的「5s→1m→3m→5m→每 5m，默认 0」，Q4 的「采用模式而非调用服务」）。
  - **Q5 的根因只在 exact / lesson 里完整**，summary 层级无论如何都答不出这一问的机理（要总结的那三天 dsh/activity day 总结本身就是这个 bug 的受害者 —— 这是一个**自指盲区**：出故障的那条链路，恰好是唯一能"语义化"这段故障的链路）。
  - **Q6 的关键数字（56.0s / 317 tok/s、65.9s / 267 tok/s、MAX_TOKENS 4096、17,785 token）summary 里完全没有**。

**2) summary 有没有答得含糊 / 漏细节？举例子**
- **数字与参数蒸发**：Q6 的 prefill 秒数与 tok/s、`cache_prompt=false`、材料规模（23 条 / 112,780 字节）在 09-16 summary 里全不见，只剩「**qwen3.5-4b 在预填充速度（317 tok/s）和稳定性上优于 qwen3.5-9b-mtp**」——**9b 的 267 tok/s 被丢掉**，且把 9b 的失败形态（read timeout）含糊成「稳定性」问题。
- **理由被压成动作**：Q2 的 summary 写「移除了不合理的默认超时限制」，而原始决策的理由是「中心仓同步几十分钟到几天是常态，超时判失败既不准确也无意义」——**"为什么这么定"这一层在摘要里丢失**。
- **自我矛盾（幻觉）**：09-15 summary 的【workspace】节把 **gjson 1.2.2 同时列进「必须发布」与「禁止发布」**（"禁止发布：crc 1.0.1, snappy 1.0.2（源码零差异，仅版本号不同），gjson 1.2.2（若指源码零差异版本）"）。exact 里其实很清楚：gjson 1.2.2 与 1.2.1 源码零差异属空版本，**但被已发布的 bstorm 1.4.9 声明，故必须发**（悬空依赖只能靠它追上）；crc/snappy 才是不发的空版本。
- **丢一半修复**：09-15 summary 说 OOM 根因是「瞬时分配峰值（~240MB）逼近默认堆上限（256MB），且物化任务缺乏幂等性导致 LSM 文件无意义增长」，**丢了「不是泄漏」这一关键判据与 live bytes 30-60MB 的对照**，也把修复叙述软化成"缺乏幂等性"。
- **错别字**：09-15 summary 把 `chronomem` 拼成 **`cronomem`**（同一 summary 首行）；exact 侧也有一处把项目名写成「忘时塔」——**两边都不是零噪声的**。
- **粒度合并导致边界模糊**：09-15 summary 把 20:49 的「阶段完成」（三项修复）与 23:15 的「完成」（依赖收敛）合成一段，未区分「两项修复」与「诊断侧第三项」的边界。
- **Q3/Q4 的精确字面在 summary 里被压缩**：三处改动位置、两个存储键名、被改的原文句，在 summary 里只剩「修正 README、AGENTS.md 中关于『调用忆时塔』的表述」——**方向对、可复现性不足**。

**3) 检索顺畅吗？需要反复试探吗？**
- **顺畅，基本不需要反复试探**：`mem/list_types` 一次拿到全部类型与条目量；按「类型 + 天窗口」逐日 exact 下钻即可，09-15 一天 12 条、09-14 一天 ~20 条、09-16 一天 9 条，规模很小，关键词检索即命中。Q1/Q2 甚至在第一屏（09-15 首次 exact 返回的前 6KB）就出现了。
- **需要留意的点**：
  - **问题跨天**：「9 月中旬」实际横跨 09-13、09-14、09-15、**09-16**（Q5/Q6 都在 09-16 凌晨），必须先扫四天才能找齐 —— 属问题本身跨天，不是检索不顺。
  - **dsh/activity 的 day summary 清单会"骗人"**：`mem/summaries` 默认 `limit` 只回 10 条，用小 limit 看会以为 09-13 之后一律空缺；拉到 `limit:200` 才看到 09-16 03:47/03:53/04:04 三条补算记录（`chunked 2/2/6 段`，正是 Q5 修复后 recompute 的产物）。**判断"缺没缺"必须把 limit 拉够**。
  - **group/proj 名会漂移**：09-14 同一天的条目 proj 有 `liveboard`、`atelier`、`atelier-starline`、`atelier-yggdrasil` 多个取值（仓改名当天），按 `group` 过滤容易漏，按天全量拉更稳。
  - **同一天常有多笔账**：09-15 的 OOM 有 20:49 与 23:15 两笔（后一笔夹在"依赖收敛"任务里），只看一笔会漏掉修复的完整口径。
  - **`mem/summaries` 输出很长**（60 条约 96KB），逐日 `recall` 比拉全清单更省。
  - 时区对齐无误：按题面毫秒基准取窗口未出现错位。

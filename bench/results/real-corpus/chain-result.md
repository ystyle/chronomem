# 链式召回测试（真实语料）

- 数据源：忆时塔 `http://127.0.0.1:8900/mcp`，类型 `worklog`（480 条原始条目、38 个 day 桶、8 个 week 桶）
- 窗口毫秒值一律取自 CHAIN-TASK.md 表格，未自行换算
- 判定口径：**core（核心词，标识事实身份）+ detail（细节词，数字/专名/机制名）**
  - `intact` = 核心词与细节词全中
  - `partial` = 核心词命中、细节词有缺
  - `absent` = 该层摘要**存在**但核心词全不中
  - `missing` = 该层**根本没有摘要**（返回「该时段尚无语义摘要」）
- 三层均为实测：`raw` = 2026-09-2x/10-0x 当日 `mode=exact` 原始条目；`day` = 同日 `granularity=day, mode=summary`；`week` = 该日所属自然周 `granularity=week, mode=summary`

---

## 2026-09-21（属 09-21~09-27 周窗口）

| 事实 | 特征词 | raw | day | week |
|---|---|---|---|---|
| PTC 沙箱白名单可被 `(apply f '())` 绕过（泄漏 SECRET-LEAKED），根因特殊形式先于 funcChecker 返回 → 改干净 Environment 不注册 | SECRET-LEAKED / funcChecker / 干净 Environment | intact | **absent** | **absent** |
| 移除行式 REPL 死代码（601 行 + 9 条专属用例），交互入口统一为 tui 子命令 | REPL / 601 / tui | intact | intact | partial（601、tui 均丢） |
| MCP 客户端 Parse error 真根因 = 换行分帧（不是 HTTP 错误体） | Parse error / 换行分帧 | intact | intact | **absent**（周摘要只剩 2.3.13 版本号） |
| mcp 2.3.12 制品清单收口：43 文件 3.7MB → 35 文件 234KB | 制品 / 3.7MB / 234KB | intact | intact | intact |
| json-rpc 修 in-flight 记录泄漏（send 抛异常不移除 pendingRequests），新增 inFlightCount | in-flight / pendingRequests / inFlightCount | intact | partial（pendingRequests 丢） | partial（pendingRequests 丢） |

## 2026-09-22（属 09-21~09-27 周窗口）

| 事实 | 特征词 | raw | day | week |
|---|---|---|---|---|
| 工具超时按只读 30s / 有副作用 300s 分流；写类超时=假失败（outcome UNKNOWN）；新增 ToolBudgetPolicy 三态预算 | 假失败 / 300s / ToolBudgetPolicy | intact | intact | **absent**（周摘要完全没提工具超时） |
| 预演号口径：= 待发中心仓版本 +1；同号被钉住/缓存过则换号；被取代版本标「不发中心仓」 | 预演号 / 不发中心仓 / 缓存 | intact | intact | **absent**（周摘要只有"钉住/缓存"两词作旁证，规则本身已丢） |
| jsonrpc 链 8 包预演版本：六包 0.7.7 + acp 0.2.5 + mcp 2.3.14 | 0.7.7 / 2.3.14 / 0.2.5 | intact | intact | intact |
| cjreg 空态插图全黑根因：23 处引用未定义 CSS 变量 `--el-fill-color-N` → 改用 `--el-empty-fill-color-*` | 空态 / 23 处 / empty-fill-color | intact | partial | partial（23 处与变量名都丢） |
| cjreg CI 断言 `success=6/6` 已过期 → 改为解析 detail 的 key=value | 断言 / success=6/6 / detail | intact | intact | partial（success=6/6 丢） |

## 2026-09-23（属 09-21~09-27 周窗口）

| 事实 | 特征词 | raw | day | week |
|---|---|---|---|---|
| cordis-cj P15：新增 cordis_xisp 成员，lambda 经表达式树调用；20 新用例 / 全量 142 通过；commit 72e5ea7 | cordis_xisp / 表达式树 / 72e5ea7 / 142 | intact | intact | intact |
| xisp 0.4.1 发版：制品由 244 文件收口到 101；cordis_core 零差异不发 | xisp 0.4.1 / 244 / 101 / cordis_core | intact | partial | partial（244/101/cordis_core 全丢） |
| 新建 cjpm-ws 工具（check/sync/bump，14 单测）；cangjie-publish 技能外发 atomgit 公开仓 id 10951651 | cjpm-ws / 10951651 / 技能外发 | intact | partial | partial（仓 id 丢） |
| cjxt Empty 插图改由脚本从 Element Plus `img-empty.vue` 生成（4 处偏差），Chrome 逐字节一致，commit 0d24b46 | img-empty.vue / 逐字节 / 0d24b46 | intact | intact | intact |
| 全工作区盘点 76 个 cjpm 项目：约 20 仓未推送、12 仓未提交、6 个非 git 目录 | 非 git 目录 / 76 / 20 个仓 / 12 仓 | intact | partial | partial（76、20 仓、12 仓全丢） |

## 2026-09-27（属 09-21~09-27 周窗口）

| 事实 | 特征词 | raw | day | week |
|---|---|---|---|---|
| llm_api 1.3.0：新增 ImageFileBlock(fileId)；Anthropic 自动补 `anthropic-beta: files-api-2025-04-14`；Ollama 明确抛错；视觉闸门改 isImageBlock | ImageFileBlock / files-api-2025-04-14 / isImageBlock | intact | partial | partial（beta 头与 isImageBlock 全丢） |
| xisp 工作区化：阶段1 拆 5 成员（xisp_terminal/xisp_repl/xisp_cli/xisp_examples），阶段2 加 xisp_bc | xisp_terminal / xisp_examples / xisp_bc | intact | partial | partial（xisp_bc 丢） |
| 各成员 cjpm.toml 必须补 `organization = ystyle`，缺了会被当外部 registry 依赖而 404 | organization / 404 | intact | partial | partial（404 丢） |

## 2026-09-29（属 09-29~10-01 周窗口）

| 事实 | 特征词 | raw | day | week |
|---|---|---|---|---|
| 忆时塔物化丢条目：09-12 窗口实际 48 条、物化桶只 28 条（丢 20 条 resume 事件），根因恢复策略只补缺桶 → 改内容指纹判据 | 桶内容指纹 / 48 / 28 / 20 条 | intact | partial | partial（全部具体数字与判据名丢失） |
| exact 回想串窗：09-25 空窗口 query=0 却返回 09-24 的 6 条 → bucketAt 增 allowFallback | 严格匹配目标窗口 / 09-25 / 09-24 / allowFallback | intact | partial | partial（日期与参数名全丢） |
| 摘要层三缺陷修复（条数上限 50 / 粒度重叠 / 递归未实现）：周摘要恢复 12 条，压缩比 5.1x | 条数上限 / 粒度重叠 / 5.1x | intact | partial | partial（5.1x 与"12 条"丢） |
| HarnessBench 接入：llm_api 流式响应体不关 → 连接池上限 10 → Too many connections；workDir 相对路径致信任表失效，新增 ATELIER_TRUST_DIR | 连接泄漏 / 信任表 / Too many connections / ATELIER_TRUST_DIR | intact | partial | **absent**（周摘要只剩 HarnessBench 一词，泄漏与信任表两条因果全丢） |
| 单任务评测实测：native 6 轮 / 8.4s / $0.076 / 18,951 tokens；ptc 7 轮 / 8.8s / $0.084 / 20,823 tokens | 8.4s / 20,823 / 18,951 / $0.076 | intact | **absent** | **absent** |

## 2026-10-01（属 09-29~10-01 周窗口）

| 事实 | 特征词 | raw | day | week |
|---|---|---|---|---|
| @C 导出被 `cjc --no-sub-pkg` 吞掉符号（cjpm 默认带该参数）；post-build 钩子可补产 12 个 C 符号 | --no-sub-pkg / 12 个 C 符号 / post-build | intact | intact | intact |
| atelier-lumine 交叉构建出 Windows 可执行文件 atelier_lumine.exe（PE32+，39.8MB），commit 7fdd086 | atelier_lumine.exe / 39.8MB / PE32+ / 7fdd086 | intact | intact | intact |
| 新增 cangjie-doc-sync 技能（doc_sync_audit.py）；--since 裸日期自动补 00:00 防时区漏检 | cangjie-doc-sync / doc_sync_audit.py / --since | intact | intact | intact |
| godot-poc：必须 cjld.shared.lds + static 守卫保证运行时只初始化一次；修正认知——GDExtension 可用 ScriptLanguageExtension 注册完整脚本语言 | cjld.shared.lds / ScriptLanguageExtension / 热重载 | intact | intact | intact |
| atelier AG-UI：新开 /ag-ui/agent 端点 + toolCallId；测试 690/690 全绿；llm_api 1.3.6 与 atelier 0.1.7 已私有仓预演 | AG-UI / /ag-ui/agent / 690 / 1.3.6 | intact | intact | **absent**（周摘要只收了其余 4 条，AG-UI 整条不见） |

## 2026-10-08（属 10-05~10-11 周窗口）

| 事实 | 特征词 | raw | day | week |
|---|---|---|---|---|
| pdfcpu 缺口分析：非测试 148,816 行；中心仓 739 个包里 PDF 相关 0、字体类 0；stdx zlib 无容器需自补 Adler-32；unifont 为 GPL 不可进制品 | Adler-32 / 148,816 / 739 / unifont | intact | partial | partial（148,816 与 739 丢） |
| cjreg 回源 OOM：仓颉 1.2.0 无效（128 MiB 仍 OOM，VmHWM 283 MiB）；linderHttp 无效（同一个 stdx 缓冲流）；锁定 Range 分块回源 | Range / 128 MiB / 283 / linderHttp | intact | partial | partial（128 MiB 与 283 丢） |

## 2026-10-10（属 10-05~10-11 周窗口）

| 事实 | 特征词 | raw | day | week |
|---|---|---|---|---|
| cjreg 决赛迭代 5：行覆盖率 39.3% → 92.0%（87 文件 / 11245 行），用例 179 → 934 | 覆盖率 / 39.3% / 92.0% / 934 / 11245 | intact | partial | partial（934、11245 丢） |
| 4 处 UI 行为缺口判为真缺陷：plan_create 排序拿 pkgLabel（含 @version）当主键 → 退化成字典序（alpha@1.10.0 < alpha@1.9.0）；另 users bump / orgs refresh / refetchDocId | UI 行为缺口 / pkgLabel / refetchDocId / candidatePkgs | intact | partial | partial（pkgLabel、refetchDocId、candidatePkgs 全丢） |
| Go BadgerDB 基准对照参数：skl 仅 3 个 Benchmark、key 实为 16B（非 8B）、无 50×N 事务基准；定 5000x/-count=10/-cpu=16 | Benchmark / 16B / 5000x / -count=10 | intact | partial | partial（16B 丢） |
| 忆时塔只读核查：worklog 431 条（day 桶 33）、dsh/activity 949 条；position-paper.zh.md 第 31 行动机表述中英不一致 | position-paper.zh.md / 431 / 949 | intact | partial | partial（431、949 丢） |
| atelier AG-UI：ExternalRequest 新增 request 承载原始提问，server 侧 agUiResponseSchema 映射 AG-UI 1.0；测试 895→903 | agUiResponseSchema / 903 / ExternalRequest | intact | intact | intact |

> `missing` 说明：本测试的 8 个日期上 day 与 week 摘要**全部存在**，`missing` 计数为 0。
> 另测了同周内的相邻日期以确认边界：2026-09-24 有 day 摘要、09-25/09-26 无（`missing`），说明「缺摘要」确实存在、只是不落在这 8 天上——本表中 `absent` 一律是「摘要存在但没提」，不是没生成。

---

## 汇总

| 层 | intact | partial | absent | missing | 可辨（intact+partial） |
|---|---|---|---|---|---|
| raw | 35 | 0 | 0 | 0 | **35/35** |
| day 摘要 | 15 | 18 | 2 | 0 | **33/35**（absent 2） |
| week 摘要 | 9 | 19 | 7 | 0 | **28/35**（absent 7） |

- raw 可辨：**35/35**
- day 摘要可辨：**33/35**（absent: 2，missing: 0）
- week 摘要可辨：**28/35**（absent: 7，missing: 0）

逐层收缩：`intact` 从 raw 35 → day 15 → week 9；`absent` 从 0 → 2 → 7。
即 day 层已丢掉约 6% 的事实，week 层丢掉 20%；而"完整可辨"的比例掉得更快（100% → 43% → 26%）。

---

## 观察

### 1. 哪类信息最先在链上丢失？

按"该层差一点就 intact、且丢失的都是同一类词"来归纳，丢失顺序是：

**① 数字与量化结果最先死（最快、最彻底）。**
`intact→partial` 的 18 条 day 层判例里，丢失项几乎清一色是数字：244/101（制品文件数）、10951651（仓 id）、12 仓、148,816 行 / 739 包、128 MiB / 283 MiB、934 / 11245、431 / 949。day 摘要保留的是事件的"动作"（"制品清单收口"、"覆盖率提升"、"缺口分析"），把"多少"抹掉。week 层进一步连"有数字这件事"都不再提示。
最典型：09-23 的制品收口 `244 → 101` 在 day 与 week **双双丢失**，只剩"xisp 0.4.1 发版"。也就是说，"发版了"活着，"发版时制品从多少收到多少"死了——数字是链上最脆的一环。

**② 版本号/标识符是二等脆弱。** 保留了主版本（0.4.1、0.7.7、2.3.14、1.3.0 都在），丢掉的是**被取代/被跳过的号**——比如"2.3.13 因已被钉住故跳 2.3.14"里的因果，以及 `success=6/6`、`pendingRequests`、`16B`、`423` 这类具体字面量。

**③ 机制名/参数名随之丢失。** `--el-empty-fill-color-*`、`allowFallback`、`ATELIER_TRUST_DIR`、`refetchDocId`、`pkgLabel`、`isImageBlock`、`xisp_bc`、`--since` 这一批在 day 层已掉一半、week 层基本清零。留下的只有"修了个 CSS 变量缺陷""修了个回想缺陷"这种无参数的结果描述。

**④ 因果链比结论先死。** 09-29 的"流式响应体不关 → 连接池上限 10 → Too many connections"在 day 层已压成 `HarnessBench` 一个词（partial），week 层直接 `absent`。相反，"做了评测接入"这个**动作**留下来了。同样 09-22 的"写类超时是假失败，因为执行不会停、结果可能已落盘"→ day 完整，week **absent**：一条"为什么不能重试"的核心判断，一周后完全消失。

**⑤ 最不容易丢的是"专名 + 明确产出物"。** 跨 day/week 都 intact 的 9 条，几乎都是"专有名词 + 可点名产物"：`cordis_xisp + 72e5ea7`、`img-empty.vue + 0d24b46`、`--no-sub-pkg + 12 个 C 符号`、`atelier_lumine.exe + 39.8MB + PE32+`、`cjld.shared.lds + ScriptLanguageExtension`、`agUiResponseSchema + ExternalRequest`。**有名字的东西比有数字的东西活得久，数字比因果活得久。**

### 2. week 摘要是否退化成"泛泛而谈"？——是，两例

**例 1（整条事实消失）：09-22「工具超时假失败」→ week 完全 absent。**
day 摘要完整写着："将写类工具超时定义为'假失败'（结果可能已落盘），避免模型重复重试；引入三态预算机制（Default/Unbounded/Limit）"。
同一周（09-21~09-27）的 week 摘要里，`假失败` / `300s` / `ToolBudgetPolicy` / `超时` **一个都搜不到**（各 0 次）。该周 atelier 段落只有三条决策（xisp 依赖收口等），与工具超时毫无关系；全周唯一沾边的只是"解决构建及测试偶发失败问题"这类泛语。一条会导致"一次写入变两次"的操作性判断，一周后不可召回。

**例 2（有名字、没内容）：09-29「连接泄漏」→ week 只剩一个词。**
day 摘要："llm_api 流式/非流式从不关闭响应体 → stdx 每主机连接池上限 10，第 11 次 LLM 调用抛 Too many connections"。week 摘要里 `HarnessBench` 出现 1 次，而 `连接泄漏`、`信任表`、`Too many connections`、`ATELIER_TRUST_DIR` **全为 0 次**（`泄漏` 一词在整个 week B 里也是 0 次）。**名词留下了，名词下面那件事没了**——这正是"泛泛而谈"的机制：week 层优先保留实体名，牺牲谓词与因果。

反例也要记：10-01 的 4 条反而在 week 层全 intact（`--no-sub-pkg`、`atelier_lumine.exe`、`doc_sync_audit.py`、`cjld.shared.lds`）。说明 week 摘要是**选摘**而非均匀退化——被选中的事实可以接近无损，落选的事实则完全不可见（那一周 atelier 的 AG-UI 整条 `absent`）。

### 3. day → week 的压缩比（字符数）

| 周窗口 | 覆盖日 | week 摘要字符 | 该周各 day 摘要字符和 | day→week 压缩比 |
|---|---|---|---|---|
| 2026-09-21 ~ 09-27 | 7 天（其中 09-25/09-26 **missing**） | 9,659 | 14,695 | **1.52×** |
| 2026-09-28 ~ 10-04 | 7 天（10-03/10-04 missing） | 11,330 | 18,547 | **1.64×** |
| 2026-10-05 ~ 10-11 | 7 天（10-05/10-07 missing） | 15,796 | 17,520 | **1.11×** |

**week 只把 day 压掉约 1.1~1.6 倍——远小于 day 对 raw 的 3.8 倍。**
作为对照，同一批 8 天的 `raw → day`：原始 98,844 字符 → 日摘要 26,015 字符 = **3.80×**。

这里有个反直觉结论：**week 摘要不是"更抽象"，而是"更长但不重叠"**——它不是把 7 天浓缩，而是换了个切分口径（按 `proj` 分组横切，每组各写一份，且只写被选中的事）。所以 week 层的损失不是"概括导致的糊化"，而是"选摘导致的整条缺失"：10-05~10-11 周里 atelier 的 AG-UI 整条消失、09-22 的工具超时整条消失，但同一周 09-23 的 `cordis_xisp/72e5ea7`、10-01 的 4 条却逐字保留。同一层摘要内部，事实的存活率在 0% 与 100% 之间跳——它是**选择性的**，不是均匀衰减的。

需要澄清一点方向性：我没有发现 week 层"无中生有"地引入 day 层没有的信息（抽查的 `0.1.4`、`planRounds`、`0.333` 都能在**同周某个 day 摘要**里找到出处，只是那些天不在本表的 8 天里）。所以本测试只支持单向结论：**week 是 day 的子集式选摘，丢失是不可逆的，反向不成立。**

### 4. 一个必须记下的口径风险

有 1 条 `absent` 值得警惕：09-29「物化丢条目 48 vs 28」在 day 层是 `partial`——因为 day 摘要写的是"从'桶存在即跳过'改为'桶内容指纹校验'"，**机制名在、具体数字（48/28/20 条）不在**。若只按关键词数数字，这条会被误判成 `absent`；但按"事实是否可辨认"它是 `partial`。**这正是 `absent` 与 `missing` 之外、第三个容易混淆的边界：数字丢失 ≠ 事实丢失。** 反之，09-22「预演号口径」数字全无、只剩"钉住/缓存"两个旁证词，判 `absent` 才是对的——区别在于**核心断言（那条规则本身）还能不能重建**。

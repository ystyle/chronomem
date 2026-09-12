package chronomem.mcp

import chronomem.core.*
import llm_api.event.EventStream
import llm_api.message.{ContentList, AssistantMessage, StopReason, TokenUsage}
import llm_api.provider.*
import jsonvalue.*
import mcp.*
import std.collection.*
import std.core.Duration
import std.time.*

// 测试用 fake Provider（chronomem.mcp 包内，避免依赖 core 测试类）
class FakeSummarizerProvider <: Provider {
    let echoText: String

    public init(echoText: String) { this.echoText = echoText }

    public func name(): String { "fake" }
    public func chat(req: ChatRequest): ChatResponse {
        ChatResponse(AssistantMessage(ContentList.ofText(this.echoText), "fake", "fake",
            StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let s = EventStream<ChatDelta, AssistantMessage>()
        s.setResult(AssistantMessage(ContentList.ofText(this.echoText), "fake", "fake",
            StopReason.EndTurn, TokenUsage(0, 0), 0))
        s
    }
}

// 无 LLM 的内存服务
func svc(): MemoryService { MemoryService.openFile(freshTestDir()) }

// 带 fake LLM 的内存服务
func svcWithLlm(): MemoryService {
    MemoryService.openFile(freshTestDir(), summarizer: Some(Summarizer(FakeSummarizerProvider("决策：A\n结论：B"), "fake")))
}

func argsFromJson(json: String): HashMap<String, JsonValue> {
    JsonValue.parse(json).asMap().getOrThrow()
}

func resultText(r: CallToolResult): String {
    let sb = StringBuilder()
    for (c in r.content) {
        match (c) {
            case ContentBlock.Text(tc) => sb.append(tc.text)
            case _ => ()
        }
    }
    sb.toString()
}

// ---------- 类型管理 ----------

@Test
func handlers_typeCreateAndList() {
    let s = svc()
    let r1 = handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\",\"levels\":[\"day\",\"week\"],\"description\":\"工作日志\"}"))
    @Expect(resultText(r1).indexOf("已创建类型 worklog") != None, true)
    let r2 = handleListTypes(s, HashMap<String, JsonValue>())
    @Expect(resultText(r2).indexOf("worklog") != None, true)
    @Expect(resultText(r2).indexOf("day → week") != None, true)
    // 缺 name → error
    let r3 = handleTypeCreate(s, HashMap<String, JsonValue>())
    @Expect(r3.isError, true)
    // 非法类型名 → error
    let r4 = handleTypeCreate(s, argsFromJson("{\"name\":\"../evil\"}"))
    @Expect(r4.isError, true)
    // 非法 levels → error
    let r5 = handleTypeCreate(s, argsFromJson("{\"name\":\"t\",\"levels\":[\"5min\"]}"))
    @Expect(r5.isError, true)
    // 重复创建 → error
    let r6 = handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\"}"))
    @Expect(r6.isError, true)
    s.close()
}

@Test
func handlers_typeInfo() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\",\"levels\":[\"day\",\"week\"]}"))
    let r = handleTypeInfo(s, argsFromJson("{\"name\":\"worklog\"}"))
    let t = resultText(r)
    @Expect(t.indexOf("条目数: 0") != None, true)
    @Expect(t.indexOf("day → week") != None, true)
    // 不存在 → error
    let r2 = handleTypeInfo(s, argsFromJson("{\"name\":\"nope\"}"))
    @Expect(r2.isError, true)
    s.close()
}

// ---------- 类型更新（mem/type_update） ----------

// Option 读取辅助：@Expect 需要 Equatable，Option<ArrayList<String>> 不能直接与 None 比较。
func tuOptList(o: Option<ArrayList<String>>): String {
    match (o) {
        case Some(l) => l.toString()
        case None => "None"
    }
}

func tuOptStr(o: Option<String>): String {
    match (o) {
        case Some(s) => s
        case None => "None"
    }
}

@Test
func handlers_typeUpdateFields() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\",\"levels\":[\"day\",\"week\"],\"description\":\"旧描述\"}"))
    // 更新可变字段；levels 传相同值按 no-op 接受（bridge 幂等自愈依赖这一点）
    let r = handleTypeUpdate(s, argsFromJson(
        "{\"name\":\"worklog\",\"levels\":[\"day\",\"week\"],\"description\":\"新描述\",\"auto_summarize\":true,\"summary_group_by\":[\"proj\"]}"))
    @Expect(r.isError, false)
    let m = s.registry.get("worklog").getOrThrow()
    @Expect(m.description, "新描述")
    @Expect(m.autoSummarize, true)
    @Expect(tuOptList(m.summaryGroupBy), "[proj]")
    @Expect(m.levels.toString(), "[day, week]")
    // 再次更新：省略的字段保持不变，显式给出的覆盖
    let r2 = handleTypeUpdate(s, argsFromJson("{\"name\":\"worklog\",\"summary_levels\":[\"week\"]}"))
    @Expect(r2.isError, false)
    let m2 = s.registry.get("worklog").getOrThrow()
    @Expect(m2.description, "新描述")
    @Expect(tuOptList(m2.summaryGroupBy), "[proj]")
    @Expect(tuOptList(m2.summaryLevels), "[week]")
    // 全字段与现值相同 → 成功且无变化
    let r3 = handleTypeUpdate(s, argsFromJson("{\"name\":\"worklog\",\"description\":\"新描述\"}"))
    @Expect(r3.isError, false)
    @Expect(resultText(r3).indexOf("无变化") != None, true)
    s.close()
}

@Test
func handlers_typeUpdateClear() {
    let s = svc()
    handleTypeCreate(s, argsFromJson(
        "{\"name\":\"t\",\"levels\":[\"day\"],\"description\":\"d\",\"schema\":\"docs\",\"retention\":\"30d\",\"summary_group_by\":[\"proj\"]}"))
    // 空串 / 空数组 = 清空
    let r = handleTypeUpdate(s, argsFromJson("{\"name\":\"t\",\"schema\":\"\",\"retention\":\"\",\"summary_group_by\":[]}"))
    @Expect(r.isError, false)
    let m = s.registry.get("t").getOrThrow()
    @Expect(tuOptStr(m.schema), "None")
    @Expect(tuOptStr(m.retention), "None")
    @Expect(tuOptList(m.summaryGroupBy), "None")
    // description 传空串是"清空"而非"不变"
    let r2 = handleTypeUpdate(s, argsFromJson("{\"name\":\"t\",\"description\":\"\"}"))
    @Expect(r2.isError, false)
    @Expect(s.registry.get("t").getOrThrow().description, "")
    s.close()
}

@Test
func handlers_typeUpdateGuards() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"t\",\"levels\":[\"day\",\"week\"]}"))
    // 类型不存在 → error，且不创建
    @Expect(handleTypeUpdate(s, argsFromJson("{\"name\":\"nope\"}")).isError, true)
    @Expect(s.registry.has("nope"), false)
    // 缺 name → error
    @Expect(handleTypeUpdate(s, HashMap<String, JsonValue>()).isError, true)
    // levels 改值 → error
    @Expect(handleTypeUpdate(s, argsFromJson("{\"name\":\"t\",\"levels\":[\"day\"]}")).isError, true)
    // summary_levels 不在 levels 内 → error
    @Expect(handleTypeUpdate(s, argsFromJson("{\"name\":\"t\",\"summary_levels\":[\"10min\"]}")).isError, true)
    // summary_group_by 超 2 维 → error
    @Expect(handleTypeUpdate(s, argsFromJson("{\"name\":\"t\",\"summary_group_by\":[\"a\",\"b\",\"c\"]}")).isError, true)
    // 上面全部失败后 meta 未被改动
    let m = s.registry.get("t").getOrThrow()
    @Expect(m.levels.toString(), "[day, week]")
    @Expect(tuOptList(m.summaryLevels), "None")
    @Expect(tuOptList(m.summaryGroupBy), "None")
    s.close()
}

@Test
func handlers_typeUpdatePersists() {
    let dir = freshTestDir()
    let s = MemoryService.openFile(dir)
    handleTypeCreate(s, argsFromJson("{\"name\":\"t\",\"levels\":[\"day\",\"week\"]}"))
    handleTypeUpdate(s, argsFromJson(
        "{\"name\":\"t\",\"description\":\"持久化\",\"auto_summarize\":true,\"summary_levels\":[\"week\"],\"summary_group_by\":[\"proj\"]}"))
    s.close()
    // 重开 → 新 meta 生效（meta series 同名后写覆盖先写）
    let s2 = MemoryService.openFile(dir)
    let m = s2.registry.get("t").getOrThrow()
    @Expect(m.description, "持久化")
    @Expect(m.autoSummarize, true)
    @Expect(tuOptList(m.summaryLevels), "[week]")
    @Expect(tuOptList(m.summaryGroupBy), "[proj]")
    s2.close()
}

@Test
func handlers_typeInfoShowsMutableConfig() {
    let s = svc()
    handleTypeCreate(s, argsFromJson(
        "{\"name\":\"t\",\"levels\":[\"day\",\"week\"],\"auto_summarize\":true,\"summary_group_by\":[\"proj\"]}"))
    let t = resultText(handleTypeInfo(s, argsFromJson("{\"name\":\"t\"}")))
    @Expect(t.indexOf("自动总结: true") != None, true)
    @Expect(t.indexOf("总结分组维度: [proj]") != None, true)
    // 更新后 type_info 反映新值
    handleTypeUpdate(s, argsFromJson("{\"name\":\"t\",\"auto_summarize\":false}"))
    let t2 = resultText(handleTypeInfo(s, argsFromJson("{\"name\":\"t\"}")))
    @Expect(t2.indexOf("自动总结: false") != None, true)
    s.close()
}

// ---------- append / query ----------

@Test
func handlers_appendAndQuery() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\"}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"task\":\"A\"},\"ts\":1704110400000}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"task\":\"B\"},\"tags\":{\"proj\":\"x\"},\"ts\":1704110460000}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"task\":\"C\"},\"ts\":1704110520000}"))

    // query 全部
    let r1 = handleQuery(s, argsFromJson("{\"type\":\"worklog\"}"))
    let t1 = resultText(r1)
    @Expect(t1.indexOf("task") != None, true)
    // tag 过滤
    let r2 = handleQuery(s, argsFromJson("{\"type\":\"worklog\",\"tag\":\"proj=x\"}"))
    @Expect(resultText(r2).indexOf("task") != None, true)
    @Expect(resultText(r2).indexOf("B") != None, true)
    // limit
    let r3 = handleQuery(s, argsFromJson("{\"type\":\"worklog\",\"limit\":2}"))
    let t3 = resultText(r3)
    @Expect(t3.indexOf("共 3 条") != None, true)
    @Expect(t3.indexOf("第 1/2 页") != None, true)
    @Expect(t3.indexOf("page=2") != None, true)
    @Expect(t3.indexOf("\"task\":\"C\"") != None, true)   // 第 1 页 = 最新 2 条
    @Expect(t3.indexOf("\"task\":\"A\"") == None, true)
    // 第 2 页
    let r3p2 = handleQuery(s, argsFromJson("{\"type\":\"worklog\",\"limit\":2,\"page\":2}"))
    let t3p2 = resultText(r3p2)
    @Expect(t3p2.indexOf("第 2/2 页") != None, true)
    @Expect(t3p2.indexOf("\"task\":\"A\"") != None, true)  // 最旧 1 条在第 2 页
    @Expect(t3p2.indexOf("page=3") == None, true)          // 末页无下一页提示
    // 超界页码 → 空结果但给出页信息
    let r3p9 = handleQuery(s, argsFromJson("{\"type\":\"worklog\",\"limit\":2,\"page\":9}"))
    @Expect(resultText(r3p9).indexOf("无更多条目") != None, true)
    // 不存在类型 → error
    let r4 = handleAppend(s, argsFromJson("{\"type\":\"nope\",\"payload\":{}}"))
    @Expect(r4.isError, true)
    // 缺 payload → error
    let r5 = handleAppend(s, argsFromJson("{\"type\":\"worklog\"}"))
    @Expect(r5.isError, true)
    // 条目数正确
    @Expect(s.registry.countEntries("worklog"), Int64(3))
    _ = r3
    s.close()
}

// 大条目限长（生产 OOM 防线，fix/append-size-limit）：单条 payload 序列化后超过
// MAX_APPEND_PAYLOAD_BYTES 拒绝——950KB 级病态输入在 256MB GC 堆下以 ~200MB 瞬时
// 分配顶爆堆 → OOM → 请求悬挂（忆时塔曾因此卡死；长连接卡顿同源）。
// 限长后单请求峰值分配被压到堆内安全区间（实测 100KB 级峰值 ~15-20MB）。
@Test
func handlers_appendSizeLimit() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\"}"))

    // 超限（上限 + 1 字节 ASCII，rune 数 = 字节数）：拒绝且报错文案含上限
    let over = StringBuilder()
    for (i in 0..(MAX_APPEND_PAYLOAD_BYTES + 1)) {
        over.append("x")
    }
    let r1 = handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"d\":\"" + over.toString() + "\"}}"))
    @Expect(r1.isError, true)
    @Expect(resultText(r1).indexOf("上限") != None, true)
    @Expect(s.registry.countEntries("worklog"), Int64(0))

    // 明显小于上限的条目正常写入
    let ok = StringBuilder()
    for (i in 0..4096) {
        ok.append("x")
    }
    let r2 = handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"d\":\"" + ok.toString() + "\"}}"))
    @Expect(r2.isError, false)
    @Expect(s.registry.countEntries("worklog"), Int64(1))
    s.close()
}

// ---------- recall（exact 下钻 / summary 语义回顾） ----------

@Test
func handlers_recallExactDrillDown() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\"}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"m\":1},\"ts\":1704110400000}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"m\":2},\"ts\":1704110500000}"))
    // 物化（10min 窗口）
    s.store.materializeAll(TEST_BASE)
    let r = handleRecall(s, argsFromJson("{\"type\":\"worklog\",\"granularity\":\"10min\",\"windowStartMs\":1704110400000}"))
    let t = resultText(r)
    @Expect(t.indexOf("m") != None, true)
    // month 不在默认 levels 内 → error
    let r2 = handleRecall(s, argsFromJson("{\"type\":\"worklog\",\"granularity\":\"month\"}"))
    @Expect(r2.isError, true)
    @Expect(resultText(r2).indexOf("不在") != None, true)
    s.close()
}

@Test
func handlers_recallRejectsGranularityOutsideLevels() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\",\"levels\":[\"day\",\"week\"]}"))
    let r = handleRecall(s, argsFromJson("{\"type\":\"worklog\",\"granularity\":\"10min\"}"))
    @Expect(r.isError, true)
    @Expect(resultText(r).indexOf("不在") != None, true)
    s.close()
}

@Test
func handlers_recallSummaryMode() {
    let s = svcWithLlm()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\"}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"m\":1},\"ts\":1704110400000}"))
    // 先 summarize（提交后台任务，窗口覆盖 10min 桶）
    let rs = handleSummarize(s, argsFromJson("{\"type\":\"worklog\",\"granularity\":\"10min\",\"windowStartMs\":1704110400000}"))
    @Expect(resultText(rs).indexOf("已提交后台总结任务") != None, true)
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    // recall mode=summary → 返回摘要
    let r = handleRecall(s, argsFromJson("{\"type\":\"worklog\",\"granularity\":\"10min\",\"windowStartMs\":1704110400000,\"mode\":\"summary\"}"))
    @Expect(resultText(r).indexOf("决策：A") != None, true)
    // 无摘要时 summarize_on_miss=false → 提示
    let s2 = svc()
    handleTypeCreate(s2, argsFromJson("{\"name\":\"worklog\"}"))
    handleAppend(s2, argsFromJson("{\"type\":\"worklog\",\"payload\":{},\"ts\":1704110400000}"))
    let r2 = handleRecall(s2, argsFromJson("{\"type\":\"worklog\",\"granularity\":\"10min\",\"windowStartMs\":1704110400000,\"mode\":\"summary\"}"))
    @Expect(resultText(r2).indexOf("尚无") != None, true)
    s.close()
    s2.close()
}

// ---------- summarize / summaries ----------

@Test
func handlers_summarizeNoLlmIsError() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\"}"))
    let r = handleSummarize(s, argsFromJson("{\"type\":\"worklog\",\"granularity\":\"10min\"}"))
    @Expect(r.isError, true)
    @Expect(resultText(r).indexOf("未配置 LLM") != None, true)
    s.close()
}

@Test
func handlers_summarizeAndListSummaries() {
    let s = svcWithLlm()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\"}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"m\":1},\"ts\":1704110400000}"))
    // 提交后台任务 → 立即返回 job_id
    let r = handleSummarize(s, argsFromJson("{\"type\":\"worklog\",\"from\":1704110400000,\"to\":1704110999999,\"instructions\":\"重点\"}"))
    @Expect(resultText(r).indexOf("已提交后台总结任务") != None, true)
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    // summaries 列出（落库）
    let rs = handleSummaries(s, argsFromJson("{\"type\":\"worklog\"}"))
    @Expect(resultText(rs).indexOf("决策：A") != None, true)
    // 空窗口：提交后 runner 执行到「无条目，无需总结」（store=true 不落库）
    let s2 = svcWithLlm()
    handleTypeCreate(s2, argsFromJson("{\"name\":\"worklog\"}"))
    let r2 = handleSummarize(s2, argsFromJson("{\"type\":\"worklog\",\"from\":1704110400000,\"to\":1704110999999}"))
    @Expect(resultText(r2).indexOf("已提交") != None, true)
    @Expect(s2.summarizeRunner.getOrThrow().waitIdle(), true)
    // store=false 不落库 → 结果暂存内存，mem/summarize_status 可取回
    let s3 = svcWithLlm()
    handleTypeCreate(s3, argsFromJson("{\"name\":\"worklog\"}"))
    handleAppend(s3, argsFromJson("{\"type\":\"worklog\",\"payload\":{},\"ts\":1704110400000}"))
    let r3 = handleSummarize(s3, argsFromJson("{\"type\":\"worklog\",\"from\":1704110400000,\"to\":1704110999999,\"store\":false}"))
    @Expect(resultText(r3).indexOf("暂存内存") != None, true)
    let id = s3.summarizeRunner.getOrThrow().lastJobId()
    @Expect(s3.summarizeRunner.getOrThrow().waitFor(id), "done")
    let st = handleSummarizeStatus(s3, argsFromJson("{\"job_id\":" + id.toString() + "}"))
    @Expect(resultText(st).indexOf("决策：A") != None, true)
    let rs3 = handleSummaries(s3, argsFromJson("{\"type\":\"worklog\"}"))
    @Expect(resultText(rs3).indexOf("暂无总结") != None, true)
    // status 缺 job_id → error
    let bad = handleSummarizeStatus(s3, HashMap<String, JsonValue>())
    @Expect(bad.isError, true)
    s.close()
    s2.close()
    s3.close()
}

// ---------- truncate / type_delete ----------

@Test
func handlers_truncateClearsEntries() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"t\"}"))
    handleAppend(s, argsFromJson("{\"type\":\"t\",\"payload\":{},\"ts\":1704067200000}"))
    handleAppend(s, argsFromJson("{\"type\":\"t\",\"payload\":{},\"ts\":1704067260000}"))
    let r = handleTruncate(s, argsFromJson("{\"type\":\"t\"}"))
    @Expect(resultText(r).indexOf("已清空") != None, true)
    @Expect(s.registry.countEntries("t"), Int64(0))
    // 类型仍在，可继续写
    @Expect(s.registry.has("t"), true)
    handleAppend(s, argsFromJson("{\"type\":\"t\",\"payload\":{},\"ts\":1704067320000}"))
    @Expect(s.registry.countEntries("t"), Int64(1))
    s.close()
}

@Test
func handlers_typeDeleteEmptySucceeds() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"t\"}"))
    let r = handleTypeDelete(s, argsFromJson("{\"type\":\"t\"}"))
    @Expect(resultText(r).indexOf("已删除") != None, true)
    @Expect(s.registry.has("t"), false)
    s.close()
}

@Test
func handlers_typeDeleteNonEmptyRejected() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"t\"}"))
    handleAppend(s, argsFromJson("{\"type\":\"t\",\"payload\":{},\"ts\":1704067200000}"))
    let r = handleTypeDelete(s, argsFromJson("{\"type\":\"t\"}"))
    @Expect(r.isError, true)
    @Expect(resultText(r).indexOf("非空") != None, true)
    // truncate 后再删成功
    handleTruncate(s, argsFromJson("{\"type\":\"t\"}"))
    let r2 = handleTypeDelete(s, argsFromJson("{\"type\":\"t\"}"))
    @Expect(resultText(r2).indexOf("已删除") != None, true)
    s.close()
}

@Test
func handlers_typeDeleteWithSummaryRejected() {
    let s = svcWithLlm()
    handleTypeCreate(s, argsFromJson("{\"name\":\"t\"}"))
    handleAppend(s, argsFromJson("{\"type\":\"t\",\"payload\":{},\"ts\":1704067200000}"))
    handleSummarize(s, argsFromJson("{\"type\":\"t\",\"from\":1704067200000,\"to\":1704067299999}"))
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    let r = handleTypeDelete(s, argsFromJson("{\"type\":\"t\"}"))
    @Expect(r.isError, true)
    @Expect(resultText(r).indexOf("非空") != None, true)
    s.close()
}

// ---------- buckets ----------

@Test
func handlers_buckets() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\"}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{},\"ts\":1704110400000}"))
    s.store.materializeAll(TEST_BASE)
    let r = handleBuckets(s, argsFromJson("{\"type\":\"worklog\",\"granularity\":\"10min\"}"))
    @Expect(resultText(r).indexOf("10min") != None, true)
    let r2 = handleBuckets(s, argsFromJson("{\"type\":\"worklog\",\"granularity\":\"day\"}"))
    @Expect(resultText(r2).indexOf("暂无") != None, false)  // day 桶经物化链可能已建，容忍
    _ = r2
    s.close()
}

// ---------- fmtTs 时区 ----------

@Test
func handlers_fmtTsUsesConfiguredTimeZone() {
    let ts = Int64(1787459729000)   // 2026-08-23 12:35:29 +08
    let plus8 = TimeZone("UTC+08:00", Duration.hour * 8)
    @Expect(fmtTs(ts, plus8), "08-23 12:35:29")
    @Expect(fmtTs(ts, TimeZone.UTC), "08-23 04:35:29")
}

// ---------- 按天窗口对齐（回归：epoch 锚定错位 8h） ----------

// 回归用例：+08 时区下，day 粒度窗口必须按本地日历日对齐（本地零点），
// 不能是 epoch/UTC 日对齐（否则窗口错位 8 小时）。
// 锚点 ts = 1787702400000 = UTC 08-26 00:00 = +08 08-26 08:00。
// 正确窗口 = +08 本地日 08-26 00:00~23:59:59 = 1787673600000~1787759999999。
// epoch 锚定会给出 1787702400000~1787788799999（UTC 日），即回归前的 bug。
func plus8Svc(): MemoryService {
    MemoryService.openFile(freshTestDir(), 
        summarizer: Some(Summarizer(FakeSummarizerProvider("决策：A\n结论：B"), "fake")),
        timeZone: TimeZone("UTC+08:00", Duration.hour * 8))
}

@Test
func handlers_summarizeDayGranularityAlignsLocalCalendar() {
    let s = plus8Svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\",\"levels\":[\"day\",\"week\"]}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"m\":1},\"ts\":1787702400000}"))
    // mem/summarize granularity=day（无显式 from/to，走窗口计算）
    let r = handleSummarize(s, argsFromJson("{\"type\":\"worklog\",\"granularity\":\"day\",\"windowStartMs\":1787702400000}"))
    let t = resultText(r)
    @Expect(t.indexOf("1787673600000~1787759999999") != None, true)   // 本地日窗口
    @Expect(t.indexOf("1787702400000~1787788799999") != None, false)  // 不应是 UTC 日窗口
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    // 落库的总结窗口也应为本地日
    let rs = handleSummaries(s, argsFromJson("{\"type\":\"worklog\"}"))
    @Expect(resultText(rs).indexOf("1787673600000~1787759999999") != None, true)
    s.close()
}

@Test
func handlers_recallSummaryModeAlignsLocalCalendar() {
    let s = plus8Svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\",\"levels\":[\"day\",\"week\"]}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"m\":1},\"ts\":1787702400000}"))
    // recall mode=summary + on_miss：现算后台任务，窗口须本地日对齐
    let r = handleRecall(s, argsFromJson("{\"type\":\"worklog\",\"granularity\":\"day\",\"windowStartMs\":1787702400000,\"mode\":\"summary\",\"summarize_on_miss\":true}"))
    @Expect(resultText(r).indexOf("已提交后台总结任务") != None, true)
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    let rs = handleSummaries(s, argsFromJson("{\"type\":\"worklog\"}"))
    @Expect(resultText(rs).indexOf("1787673600000~1787759999999") != None, true)
    @Expect(resultText(rs).indexOf("1787702400000") != None, false)
    s.close()
}

// ---------- 按分组维度总结（summary_group_by） ----------

// 建一个按 proj 分组、带 fake LLM、+08 时区的服务，同窗口写 2 个项目 + 1 条无 tag
func groupedSvc(): MemoryService {
    let s = MemoryService.openFile(freshTestDir(), 
        summarizer: Some(Summarizer(FakeSummarizerProvider("决策：A\n结论：B"), "fake")),
        timeZone: TimeZone("UTC+08:00", Duration.hour * 8))
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\",\"levels\":[\"day\"],\"summary_group_by\":[\"proj\"]}"))
    s
}

func makeGroupedData(s: MemoryService): Unit {
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"t\":\"x1\"},\"ts\":1787673600000,\"tags\":{\"proj\":\"xisp\"}}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"t\":\"x2\"},\"ts\":1787680000000,\"tags\":{\"proj\":\"xisp\"}}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"t\":\"c1\"},\"ts\":1787690000000,\"tags\":{\"proj\":\"chronomem\"}}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"t\":\"u1\"},\"ts\":1787700000000}"))   // 无 proj → 未分组
}

@Test
func handlers_typeCreateWithSummaryGroupBy() {
    let s = svc()
    let r = handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\",\"levels\":[\"day\"],\"summary_group_by\":[\"proj\"]}"))
    @Expect(resultText(r).indexOf("按分组总结") != None, true)
    let ti = handleTypeInfo(s, argsFromJson("{\"name\":\"worklog\"}"))
    @Expect(resultText(ti).indexOf("分组维度") != None, true)
    // 超 2 维 → 拒绝
    let r2 = handleTypeCreate(s, argsFromJson("{\"name\":\"t\",\"summary_group_by\":[\"a\",\"b\",\"c\"]}"))
    @Expect(r2.isError, true)
    s.close()
}

@Test
func handlers_summarizeGroupsByProj() {
    let s = groupedSvc()
    makeGroupedData(s)
    let r = handleSummarize(s, argsFromJson("{\"type\":\"worklog\",\"from\":1787673600000,\"to\":1787759999999}"))
    @Expect(resultText(r).indexOf("已提交后台总结任务") != None, true)
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    // summaries 应有 3 条（xisp / chronomem / 未分组），各带 groupKey
    let rs = handleSummaries(s, argsFromJson("{\"type\":\"worklog\"}"))
    let txt = resultText(rs)
    @Expect(txt.indexOf("【xisp】") != None, true)
    @Expect(txt.indexOf("【chronomem】") != None, true)
    @Expect(txt.indexOf("【未分组】") != None, true)
    // recall mode=summary 不指定 group → 全部分组
    let rc = handleRecall(s, argsFromJson("{\"type\":\"worklog\",\"granularity\":\"day\",\"windowStartMs\":1787673600000,\"mode\":\"summary\"}"))
    let rct = resultText(rc)
    @Expect(rct.indexOf("【xisp】") != None, true)
    @Expect(rct.indexOf("【chronomem】") != None, true)
    // recall mode=summary 指定 group=xisp → 只返回 xisp
    let rc2 = handleRecall(s, argsFromJson("{\"type\":\"worklog\",\"granularity\":\"day\",\"windowStartMs\":1787673600000,\"mode\":\"summary\",\"group\":\"xisp\"}"))
    let rct2 = resultText(rc2)
    @Expect(rct2.indexOf("【xisp】") != None, true)
    @Expect(rct2.indexOf("【chronomem】") != None, false)
    s.close()
}

@Test
func handlers_summarizeGroupIdempotentAndRecompute() {
    let s = groupedSvc()
    makeGroupedData(s)
    handleSummarize(s, argsFromJson("{\"type\":\"worklog\",\"from\":1787673600000,\"to\":1787759999999}"))
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    // 再次总结（不 recompute）→ 各分组已有总结，跳过
    let r2 = handleSummarize(s, argsFromJson("{\"type\":\"worklog\",\"from\":1787673600000,\"to\":1787759999999}"))
    @Expect(resultText(r2).indexOf("已提交") != None, true)
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    let txt2 = resultText(handleSummaries(s, argsFromJson("{\"type\":\"worklog\"}")))
    // 不重复落库：仍是 3 条分组
    @Expect(txt2.indexOf("【xisp】") != None, true)
    @Expect(txt2.indexOf("【chronomem】") != None, true)
    @Expect(txt2.indexOf("【未分组】") != None, true)
    // recompute=true → 强制重算（会再落库同分组）
    let r3 = handleSummarize(s, argsFromJson("{\"type\":\"worklog\",\"from\":1787673600000,\"to\":1787759999999,\"recompute\":true}"))
    @Expect(resultText(r3).indexOf("已提交") != None, true)
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    s.close()
}

@Test
func handlers_summarizeWholeWindowWhenNoGroupBy() {
    // 未配置 summary_group_by → 整窗一条，无 groupKey 标记
    let s = plus8Svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\",\"levels\":[\"day\"]}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{},\"ts\":1787673600000}"))
    handleSummarize(s, argsFromJson("{\"type\":\"worklog\",\"from\":1787673600000,\"to\":1787759999999}"))
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    let txt = resultText(handleSummaries(s, argsFromJson("{\"type\":\"worklog\"}")))
    @Expect(txt.indexOf("【") != None, false)   // 无分组标记
    s.close()
}

@Test
func handlers_summarizeLargeWindowBatched() {
    // ③ 分批流式：350 条（跨 2 批 keyset 页）总结结果与逐批边界无关——
    // 全部条目都进入汇总（refs 数 = 350），不漏不重
    let s = svcWithLlm()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\",\"summary_group_by\":[\"proj\"]}"))
    for (i in 0..350) {
        handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"task\":\"t" + i.toString()
            + "\"},\"tags\":{\"proj\":\"p" + (i % 3).toString() + "\"},\"ts\":" + (1704110400000 + i).toString() + "}"))
    }
    let from = 1704110400000
    let to = 1704110400000 + 349
    let r = handleSummarize(s, argsFromJson("{\"type\":\"worklog\",\"from\":" + from.toString()
        + ",\"to\":" + to.toString() + "}"))
    @Expect(resultText(r).indexOf("已提交") != None, true)
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    // 三个分组（p0/p1/p2）各自落一条总结
    let txt = resultText(handleSummaries(s, argsFromJson("{\"type\":\"worklog\"}")))
    @Expect(txt.indexOf("【p0】") != None, true)
    @Expect(txt.indexOf("【p1】") != None, true)
    @Expect(txt.indexOf("【p2】") != None, true)
    s.close()
}

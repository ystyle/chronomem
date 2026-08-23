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
func svc(): MemoryService { MemoryService.openInMemory() }

// 带 fake LLM 的内存服务
func svcWithLlm(): MemoryService {
    MemoryService.openInMemory(summarizer: Some(Summarizer(FakeSummarizerProvider("决策：A\n结论：B"), "fake")))
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
    // 不存在类型 → error
    let r4 = handleAppend(s, argsFromJson("{\"type\":\"nope\",\"payload\":{}}"))
    @Expect(r4.isError, true)
    // 缺 payload → error
    let r5 = handleAppend(s, argsFromJson("{\"type\":\"worklog\"}"))
    @Expect(r5.isError, true)
    // 条目数正确
    @Expect(s.registry.countEntries("worklog"), Int64(3))
    _ = r3
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
}

@Test
func handlers_recallRejectsGranularityOutsideLevels() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\",\"levels\":[\"day\",\"week\"]}"))
    let r = handleRecall(s, argsFromJson("{\"type\":\"worklog\",\"granularity\":\"10min\"}"))
    @Expect(r.isError, true)
    @Expect(resultText(r).indexOf("不在") != None, true)
}

@Test
func handlers_recallSummaryMode() {
    let s = svcWithLlm()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\"}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"m\":1},\"ts\":1704110400000}"))
    // 先 summarize（窗口覆盖 10min 桶）
    let rs = handleSummarize(s, argsFromJson("{\"type\":\"worklog\",\"granularity\":\"10min\",\"windowStartMs\":1704110400000}"))
    @Expect(resultText(rs).indexOf("决策：A") != None, true)
    // recall mode=summary → 返回摘要
    let r = handleRecall(s, argsFromJson("{\"type\":\"worklog\",\"granularity\":\"10min\",\"windowStartMs\":1704110400000,\"mode\":\"summary\"}"))
    @Expect(resultText(r).indexOf("决策：A") != None, true)
    // 无摘要时 summarize_on_miss=false → 提示
    let s2 = svc()
    handleTypeCreate(s2, argsFromJson("{\"name\":\"worklog\"}"))
    handleAppend(s2, argsFromJson("{\"type\":\"worklog\",\"payload\":{},\"ts\":1704110400000}"))
    let r2 = handleRecall(s2, argsFromJson("{\"type\":\"worklog\",\"granularity\":\"10min\",\"windowStartMs\":1704110400000,\"mode\":\"summary\"}"))
    @Expect(resultText(r2).indexOf("尚无") != None, true)
}

// ---------- summarize / summaries ----------

@Test
func handlers_summarizeNoLlmIsError() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\"}"))
    let r = handleSummarize(s, argsFromJson("{\"type\":\"worklog\",\"granularity\":\"10min\"}"))
    @Expect(r.isError, true)
    @Expect(resultText(r).indexOf("未配置 LLM") != None, true)
}

@Test
func handlers_summarizeAndListSummaries() {
    let s = svcWithLlm()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\"}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"m\":1},\"ts\":1704110400000}"))
    let r = handleSummarize(s, argsFromJson("{\"type\":\"worklog\",\"from\":1704110400000,\"to\":1704110999999,\"instructions\":\"重点\"}"))
    @Expect(resultText(r).indexOf("决策：A") != None, true)
    // summaries 列出
    let rs = handleSummaries(s, argsFromJson("{\"type\":\"worklog\"}"))
    @Expect(resultText(rs).indexOf("决策：A") != None, true)
    // 空窗口无需总结
    let s2 = svcWithLlm()
    handleTypeCreate(s2, argsFromJson("{\"name\":\"worklog\"}"))
    let r2 = handleSummarize(s2, argsFromJson("{\"type\":\"worklog\",\"from\":1704110400000,\"to\":1704110999999}"))
    @Expect(resultText(r2).indexOf("无条目") != None, true)
    // store=false 不落库
    let s3 = svcWithLlm()
    handleTypeCreate(s3, argsFromJson("{\"name\":\"worklog\"}"))
    handleAppend(s3, argsFromJson("{\"type\":\"worklog\",\"payload\":{},\"ts\":1704110400000}"))
    let r3 = handleSummarize(s3, argsFromJson("{\"type\":\"worklog\",\"from\":1704110400000,\"to\":1704110999999,\"store\":false}"))
    @Expect(resultText(r3).indexOf("未落库") != None, true)
    let rs3 = handleSummaries(s3, argsFromJson("{\"type\":\"worklog\"}"))
    @Expect(resultText(rs3).indexOf("暂无总结") != None, true)
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
}

@Test
func handlers_typeDeleteEmptySucceeds() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"t\"}"))
    let r = handleTypeDelete(s, argsFromJson("{\"type\":\"t\"}"))
    @Expect(resultText(r).indexOf("已删除") != None, true)
    @Expect(s.registry.has("t"), false)
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
}

@Test
func handlers_typeDeleteWithSummaryRejected() {
    let s = svcWithLlm()
    handleTypeCreate(s, argsFromJson("{\"name\":\"t\"}"))
    handleAppend(s, argsFromJson("{\"type\":\"t\",\"payload\":{},\"ts\":1704067200000}"))
    handleSummarize(s, argsFromJson("{\"type\":\"t\",\"from\":1704067200000,\"to\":1704067299999}"))
    let r = handleTypeDelete(s, argsFromJson("{\"type\":\"t\"}"))
    @Expect(r.isError, true)
    @Expect(resultText(r).indexOf("非空") != None, true)
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
}

// ---------- fmtTs 时区 ----------

@Test
func handlers_fmtTsUsesConfiguredTimeZone() {
    let ts = Int64(1787459729000)   // 2026-08-23 12:35:29 +08
    let plus8 = TimeZone("UTC+08:00", Duration.hour * 8)
    @Expect(fmtTs(ts, plus8), "08-23 12:35:29")
    @Expect(fmtTs(ts, TimeZone.UTC), "08-23 04:35:29")
}

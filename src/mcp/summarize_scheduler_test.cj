package chronomem.mcp

import chronomem.core.*
import jsonvalue.*
import llm_api.event.EventStream
import llm_api.message.*
import llm_api.provider.*
import std.collection.*
import std.time.*

// 定时自动语义总结（§7.3）测试：opt-in、已闭合+沉降、幂等、每轮上限、目标粒度缺省。
// 用 UTC 时区 + 注入 now 保证确定性。

func schedSvc(): MemoryService {
    MemoryService.openFile(freshTestDir(), 
        summarizer: Some(Summarizer(FakeSummarizerProvider("决策：A\n结论：B"), "fake")),
        timeZone: TimeZone.UTC)
}

func msOfUTC(y: Int64, mo: Int64, d: Int64, h: Int64, mi: Int64): Int64 {
    DateTime.of(year: y, month: mo, dayOfMonth: d, hour: h, minute: mi, timeZone: TimeZone.UTC)
        .toUnixTimeStamp().toMilliseconds()
}

// 2024-01-01 00:00 UTC 起的某天窗口
let DAY_START = Int64(1704067200000)
let DAY_END = Int64(1704153599999)

func makeDayType(svc: MemoryService, name: String, auto: Bool): Unit {
    let args = argsFromJson("{\"name\":\"" + name + "\",\"levels\":[\"day\"],\"auto_summarize\":" + (if (auto) { "true" } else { "false" }) + "}")
    handleTypeCreate(svc, args)
}

func makeDefaultType(svc: MemoryService, name: String): Unit {
    // 默认 levels + auto_summarize=true → summaryLevels 缺省最粗 2 档
    let args = argsFromJson("{\"name\":\"" + name + "\",\"auto_summarize\":true}")
    handleTypeCreate(svc, args)
}

@Test
func scheduler_defaultOff() {
    let s = schedSvc()
    makeDayType(s, "a", false)
    handleAppend(s, argsFromJson("{\"type\":\"a\",\"payload\":{},\"ts\":1704067200000}"))
    let sch = SummarizeScheduler(s, 5, 60000)
    let n = sch.runOnce(DAY_END + 60000 + 1000)
    @Expect(n, Int64(0))
    s.close()
}

@Test
func scheduler_summarizesClosedSettledWindow() {
    let s = schedSvc()
    makeDayType(s, "log", true)
    handleAppend(s, argsFromJson("{\"type\":\"log\",\"payload\":{\"m\":1},\"ts\":1704067200000}"))
    handleAppend(s, argsFromJson("{\"type\":\"log\",\"payload\":{\"m\":2},\"ts\":1704100000000}"))
    let sch = SummarizeScheduler(s, 5, 60000)
    // now = 次日 00:00 + settle(60s) + 1s → 前一天已闭合且沉降
    let n = sch.runOnce(DAY_END + 60000 + 1000)
    @Expect(n, Int64(1))
    // 后台任务完成（fake LLM 立即返回）→ 摘要已落库
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    let sums = handleSummaries(s, argsFromJson("{\"type\":\"log\"}"))
    @Expect(resultText(sums).indexOf("决策：A") != None, true)
    s.close()
}

@Test
func scheduler_idempotent() {
    let s = schedSvc()
    makeDayType(s, "log", true)
    handleAppend(s, argsFromJson("{\"type\":\"log\",\"payload\":{},\"ts\":1704067200000}"))
    let sch = SummarizeScheduler(s, 5, 60000)
    let now = DAY_END + 60000 + 1000
    @Expect(sch.runOnce(now), Int64(1))
    // 已总结 → 不再重复
    @Expect(sch.runOnce(now), Int64(0))
    s.close()
}

@Test
func scheduler_notSettledYet() {
    let s = schedSvc()
    makeDayType(s, "log", true)
    handleAppend(s, argsFromJson("{\"type\":\"log\",\"payload\":{},\"ts\":1704067200000}"))
    let sch = SummarizeScheduler(s, 5, 60000)
    // now = 次日 00:00 + settle - 1 → 沉降未满
    let n = sch.runOnce(DAY_END + 59999)
    @Expect(n, Int64(0))
    s.close()
}

@Test
func scheduler_cappedPerRun() {
    let s = schedSvc()
    makeDayType(s, "a", true)
    makeDayType(s, "b", true)
    handleAppend(s, argsFromJson("{\"type\":\"a\",\"payload\":{},\"ts\":1704067200000}"))
    handleAppend(s, argsFromJson("{\"type\":\"b\",\"payload\":{},\"ts\":1704067200000}"))
    let sch = SummarizeScheduler(s, 1, 60000)   // 每轮上限 1
    let n = sch.runOnce(DAY_END + 60000 + 1000)
    @Expect(n, Int64(1))
    s.close()
}

@Test
func scheduler_defaultTargetLevelsCoarsestTwo() {
    let s = schedSvc()
    makeDefaultType(s, "log")
    // 默认 levels = 10min/30min/1h/day/week → 最粗 2 档 = day/week
    match (s.registry.get("log")) {
        case Some(m) =>
            let sch = SummarizeScheduler(s, 5, 60000)
            let levels = sch.summaryLevelsOf(m)
            @Expect(levels.size, Int64(2))
            @Expect(levels[0], "day")
            @Expect(levels[1], "week")
        case None => @Fail("类型不存在")
    }
    s.close()
}

@Test
func scheduler_noLlmDoesNothing() {
    let s = MemoryService.openFile(freshTestDir(), timeZone: TimeZone.UTC)   // 无 LLM
    makeDayType(s, "a", true)
    handleAppend(s, argsFromJson("{\"type\":\"a\",\"payload\":{},\"ts\":1704067200000}"))
    let sch = SummarizeScheduler(s, 5, 60000)
    let n = sch.runOnce(DAY_END + 60000 + 1000)
    @Expect(n, Int64(0))
    s.close()
}

@Test
func scheduler_rejectsBadSummaryLevels() {
    let s = schedSvc()
    let r = handleTypeCreate(s, argsFromJson("{\"name\":\"x\",\"levels\":[\"day\"],\"auto_summarize\":true,\"summary_levels\":[\"week\"]}"))
    @Expect(r.isError, true)
    s.close()
}

@Test
func scheduler_groupedTypeSummarizesEachProjOnce() {
    let s = schedSvc()
    // 按 proj 分组 + auto_summarize
    let r = handleTypeCreate(s, argsFromJson("{\"name\":\"log\",\"levels\":[\"day\"],\"auto_summarize\":true,\"summary_group_by\":[\"proj\"]}"))
    @Expect(r.isError, false)
    handleAppend(s, argsFromJson("{\"type\":\"log\",\"payload\":{},\"ts\":1704067200000,\"tags\":{\"proj\":\"a\"}}"))
    handleAppend(s, argsFromJson("{\"type\":\"log\",\"payload\":{},\"ts\":1704100000000,\"tags\":{\"proj\":\"b\"}}"))
    handleAppend(s, argsFromJson("{\"type\":\"log\",\"payload\":{},\"ts\":1704110000000}"))   // 无 proj → 未分组
    let sch = SummarizeScheduler(s, 5, 60000)
    let n = sch.runOnce(DAY_END + 60000 + 1000)
    @Expect(n, Int64(1))   // 一个窗口 → 一次提交（内部按分组分桶）
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    let txt = resultText(handleSummaries(s, argsFromJson("{\"type\":\"log\"}")))
    @Expect(txt.indexOf("【a】") != None, true)
    @Expect(txt.indexOf("【b】") != None, true)
    @Expect(txt.indexOf("【未分组】") != None, true)
    // 幂等：全部已总结 → 不再提交
    @Expect(sch.runOnce(DAY_END + 60000 + 1000), Int64(0))
    s.close()
}

@Test
func scheduler_groupedTypeIdempotentPerGroup() {
    let s = schedSvc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"log\",\"levels\":[\"day\"],\"auto_summarize\":true,\"summary_group_by\":[\"proj\"]}"))
    handleAppend(s, argsFromJson("{\"type\":\"log\",\"payload\":{},\"ts\":1704067200000,\"tags\":{\"proj\":\"a\"}}"))
    let sch = SummarizeScheduler(s, 5, 60000)
    let now = DAY_END + 60000 + 1000
    @Expect(sch.runOnce(now), Int64(1))
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    // 已有 a 的总结；新增 b 的条目后，应只补 b
    handleAppend(s, argsFromJson("{\"type\":\"log\",\"payload\":{},\"ts\":1704110000000,\"tags\":{\"proj\":\"b\"}}"))
    @Expect(sch.runOnce(now), Int64(1))   // 还有未总结的分组 b
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    let txt = resultText(handleSummaries(s, argsFromJson("{\"type\":\"log\"}")))
    @Expect(txt.indexOf("【a】") != None, true)
    @Expect(txt.indexOf("【b】") != None, true)
    // 全部已总结 → 幂等
    @Expect(sch.runOnce(now), Int64(0))
    s.close()
}

// ---------- 有限重试 / 退避 / 放弃（fix/summarize-budget）----------
// 背景：输入超端点上下文的窗口 summary 永远失败、永远不落库 → 幂等判据始终为假
// → 每 10 分钟重试一次直到永远（09-13 起持续到发现时）。这里钉住"止住白烧"的行为。

// 总是失败的 Provider（复刻端点超限文案；真实故障下也是这一类"重试不会成功"的失败）
class AlwaysFailSummarizerProvider <: Provider {
    var calls = Int64(0)

    public func name(): String { "failing" }
    public func chat(req: ChatRequest): ChatResponse {
        this.calls += 1
        throw Exception("request (99999 tokens) exceeds the available context size (32768 tokens)")
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let s = EventStream<ChatDelta, AssistantMessage>()
        s.setResult(AssistantMessage(ContentList.ofText("x"), "fake", "fake",
            StopReason.EndTurn, TokenUsage(0, 0), 0))
        s
    }
}

// 前 failTimes 次失败、之后成功：验证成功会清掉重试账
class FlakySummarizerProvider <: Provider {
    let failTimes: Int64
    var calls = Int64(0)

    public init(failTimes: Int64) { this.failTimes = failTimes }

    public func name(): String { "flaky" }
    public func chat(req: ChatRequest): ChatResponse {
        this.calls += 1
        if (this.calls <= this.failTimes) {
            throw Exception("request (99999 tokens) exceeds the available context size (32768 tokens)")
        }
        ChatResponse(AssistantMessage(ContentList.ofText("决策：A\n结论：B"), "fake", "fake",
            StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let s = EventStream<ChatDelta, AssistantMessage>()
        s.setResult(AssistantMessage(ContentList.ofText("决策：A\n结论：B"), "fake", "fake",
            StopReason.EndTurn, TokenUsage(0, 0), 0))
        s
    }
}

func schedSvcWith(prov: Provider): MemoryService {
    MemoryService.openFile(freshTestDir(), summarizer: Some(Summarizer(prov, "fake")),
        timeZone: TimeZone.UTC)
}

@Test
func scheduler_backsOffThenGivesUp() {
    let prov = AlwaysFailSummarizerProvider()
    let s = schedSvcWith(prov)
    makeDayType(s, "log", true)
    handleAppend(s, argsFromJson("{\"type\":\"log\",\"payload\":{},\"ts\":1704067200000}"))
    let sch = SummarizeScheduler(s, 5, 60000, maxAttempts: 3)
    let t0 = DAY_END + 60000 + 1000

    // 第 1 次：立即提交（首轮不等待）
    @Expect(sch.runOnce(t0), Int64(1))
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    @Expect(sch.attemptsOf("log", DAY_START), Int64(1))

    // +10 分钟（下一个 cron 轮）：退避 20 分钟未到 → 不提交（这里就是"每 10 分钟白烧"被止住的地方）
    @Expect(sch.runOnce(t0 + 10 * 60 * 1000), Int64(0))
    // +21 分钟：允许第 2 次
    @Expect(sch.runOnce(t0 + 21 * 60 * 1000), Int64(1))
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    @Expect(sch.attemptsOf("log", DAY_START), Int64(2))

    // +21+61 分钟：第 3 次
    let t2 = t0 + 21 * 60 * 1000 + 61 * 60 * 1000
    @Expect(sch.runOnce(t2), Int64(1))
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)

    // 再往后：连续失败到上限 → 放弃自动重试，留下可见记录，不再发起调用
    @Expect(sch.runOnce(t2 + 10 * 60 * 1000), Int64(0))
    @Expect(sch.runOnce(t2 + 24 * 60 * 60 * 1000), Int64(0))
    @Expect(sch.abandonedReport().size, Int64(1))
    @Expect(prov.calls, Int64(3))
    s.close()
}

@Test
func scheduler_successClearsRetryState() {
    // 第 1 次失败，第 2 次成功
    let prov = FlakySummarizerProvider(1)
    let s = schedSvcWith(prov)
    makeDayType(s, "log", true)
    handleAppend(s, argsFromJson("{\"type\":\"log\",\"payload\":{},\"ts\":1704067200000}"))
    let sch = SummarizeScheduler(s, 5, 60000, maxAttempts: 3)
    let t0 = DAY_END + 60000 + 1000

    @Expect(sch.runOnce(t0), Int64(1))
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    @Expect(sch.attemptsOf("log", DAY_START), Int64(1))

    // 退避后第 2 次提交并成功落库
    @Expect(sch.runOnce(t0 + 21 * 60 * 1000), Int64(1))
    @Expect(s.summarizeRunner.getOrThrow().waitIdle(), true)
    let txt = resultText(handleSummaries(s, argsFromJson("{\"type\":\"log\"}")))
    @Expect(txt.indexOf("决策：A") != None, true)

    // 窗口已总结 → 幂等跳过，并把该窗口的重试账清零（不再算作"失败窗口"）
    @Expect(sch.runOnce(t0 + 42 * 60 * 1000), Int64(0))
    @Expect(sch.attemptsOf("log", DAY_START), Int64(0))
    @Expect(sch.abandonedReport().size, Int64(0))
    s.close()
}

@Test
func scheduler_backoffLadder() {
    @Expect(backoffMs(0), Int64(0))
    @Expect(backoffMs(1), Int64(20 * 60 * 1000))
    @Expect(backoffMs(2), Int64(60 * 60 * 1000))
    @Expect(backoffMs(9), Int64(60 * 60 * 1000))
}

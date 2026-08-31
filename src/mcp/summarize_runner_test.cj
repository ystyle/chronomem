package chronomem.mcp

import chronomem.core.*
import llm_api.event.EventStream
import llm_api.message.{ContentList, AssistantMessage, StopReason, TokenUsage}
import llm_api.provider.*
import jsonvalue.*
import std.collection.*
import std.core.Duration

// 后台总结执行器（SummarizeJobRunner）单测：
// submit 立即返回、异步落库/暂存、串行、失败态、并发下 waitIdle。

// 抛异常的 Provider：模拟 LLM 调用失败
class FailingSummarizerProvider <: Provider {
    public func name(): String { "failing" }
    public func chat(req: ChatRequest): ChatResponse {
        throw Exception("llm boom")
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let s = EventStream<ChatDelta, AssistantMessage>()
        s.setError(Exception("llm boom"))
        s
    }
}

@Test
func runner_submitReturnsIdAndAsyncStores() {
    let s = svcWithLlm()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\"}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"m\":1},\"ts\":1704110400000}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"m\":2},\"ts\":1704111000000}"))
    let runner = s.summarizeRunner.getOrThrow()
    let id1 = runner.submit("worklog", 1704110400000, 1704110999999, "", true)
    let id2 = runner.submit("worklog", 1704111000000, 1704111599999, "", false)
    // 两个 id 递增
    @Expect(id2 > id1, true)
    // 等待完成
    @Expect(runner.waitFor(id1), "done")
    @Expect(runner.waitFor(id2), "done")
    // store=true 落库
    let sums = handleSummaries(s, argsFromJson("{\"type\":\"worklog\"}"))
    @Expect(resultText(sums).indexOf("决策：A") != None, true)
    // store=false 结果暂存
    @Expect(runner.status(id2), "done")
    match (runner.getResult(id2)) {
        case Some(text) => @Expect(text.indexOf("决策：A") != None, true)
        case None => @Fail("store=false 结果未暂存")
    }
    s.close()
}

@Test
func runner_serialExecutionOrder() {
    let s = svcWithLlm()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\"}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{},\"ts\":1704110400000}"))
    let runner = s.summarizeRunner.getOrThrow()
    let a = runner.submit("worklog", 1704110400000, 1704110999999, "A", true)
    let b = runner.submit("worklog", 1704111000000, 1704111599999, "B", true)
    let c = runner.submit("worklog", 1704111600000, 1704112199999, "C", true)
    @Expect(a < b && b < c, true)
    @Expect(runner.waitIdle(), true)
    @Expect(runner.status(a), "done")
    @Expect(runner.status(b), "done")
    @Expect(runner.status(c), "done")
    // 三窗口摘要都落库（同类型多总结记录）
    let sums = handleSummaries(s, argsFromJson("{\"type\":\"worklog\"}"))
    @Expect(resultText(sums).indexOf("决策：A") != None, true)
    s.close()
}

@Test
func runner_failingLlmMarksFailed() {
    let s = MemoryService.openFile(freshTestDir(), 
        summarizer: Some(Summarizer(FailingSummarizerProvider(), "failing")))
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\"}"))
    handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{},\"ts\":1704110400000}"))
    let runner = s.summarizeRunner.getOrThrow()
    let id = runner.submit("worklog", 1704110400000, 1704110999999, "", false)
    @Expect(runner.waitFor(id), "failed")
    // 失败不影响其他功能：append 仍可用
    let r = handleAppend(s, argsFromJson("{\"type\":\"worklog\",\"payload\":{\"m\":2},\"ts\":1704110500000}"))
    @Expect(r.isError, false)
    s.close()
}

@Test
func runner_unknownIdStatus() {
    let s = svcWithLlm()
    let runner = s.summarizeRunner.getOrThrow()
    @Expect(runner.status(999999), "unknown")
    @Expect(runner.getResult(999999).isNone(), true)
    s.close()
}

@Test
func runner_noLlmStillSubmitsButFails() {
    // 无 LLM 的 svc：runner 存在，但任务执行时 doSummarize 返回「未配置 LLM」→ failed
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"worklog\"}"))
    let runner = s.summarizeRunner.getOrThrow()
    let id = runner.submit("worklog", 1704110400000, 1704110999999, "", false)
    @Expect(runner.waitFor(id), "failed")
    @Expect(runner.status(id), "failed")
    s.close()
}

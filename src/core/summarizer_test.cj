package chronomem.core

import llm_api.event.EventStream
import llm_api.message.*
import llm_api.provider.*
import jsonvalue.*
import std.collection.*

// 测试用 fake Provider：chat 返回 echo 文本
class FakeProvider <: Provider {
    let echoText: String

    public init(echoText: String) { this.echoText = echoText }

    public func name(): String { "fake" }
    public func chat(req: ChatRequest): ChatResponse {
        ChatResponse(AssistantMessage(ContentList.ofText(this.echoText), "fake-model", "fake",
            StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let s = EventStream<ChatDelta, AssistantMessage>()
        s.setResult(AssistantMessage(ContentList.ofText(this.echoText), "fake-model", "fake",
            StopReason.EndTurn, TokenUsage(0, 0), 0))
        s
    }
}

// 测试用 capturing Provider：记录最后一次请求，返回固定文本
class CapturingProvider <: Provider {
    var lastRequest: ChatRequest

    public init() {
        this.lastRequest = ChatRequest("", ArrayList<Message>(), 0.0, 0, None, ArrayList<OpenAITool>())
    }

    public func name(): String { "capture" }
    public func chat(req: ChatRequest): ChatResponse {
        this.lastRequest = req
        ChatResponse(AssistantMessage(ContentList.ofText("OK"), "", "fake", StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let s = EventStream<ChatDelta, AssistantMessage>()
        s.setResult(AssistantMessage(ContentList.ofText("OK"), "", "fake", StopReason.EndTurn, TokenUsage(0, 0), 0))
        s
    }
}

func promptOf(msgs: ArrayList<Message>): String {
    var prompt = ""
    for (m in msgs) {
        match (m) {
            case um: UserMessage =>
                for (b in um.content.blocks()) {
                    match (b) {
                        case ContentBlock.TextBlock(t) => prompt = prompt + t
                        case _ => ()
                    }
                }
            case _ => ()
        }
    }
    prompt
}

@Test
func summarizer_buildsSummaryRecord() {
    let sum = Summarizer(FakeProvider("决策：A\n结论：B"), "fake-model")
    let entries = ArrayList<EntryText>()
    entries.add(EntryText(Int64(1), "do X"))
    entries.add(EntryText(Int64(2), "fix Y"))
    let rec = sum.summarize(Int64(0), Int64(100), entries, "重点")
    @Expect(rec.text, "决策：A\n结论：B")
    @Expect(rec.model, "fake-model")
    @Expect(rec.windowFrom, Int64(0))
    @Expect(rec.windowTo, Int64(100))
    @Expect(rec.refs.size, Int64(2))
    @Expect(rec.refs[0], Int64(1))
    @Expect(rec.instructions, "重点")
}

@Test
func summarizer_promptIncludesStructureAndEntries() {
    let fake = CapturingProvider()
    let sum = Summarizer(fake, "m")
    let entries = ArrayList<EntryText>()
    entries.add(EntryText(Int64(1), "do X"))
    entries.add(EntryText(Int64(7), "fix Y"))
    sum.summarize(Int64(0), Int64(100), entries, "重点")
    let prompt = promptOf(fake.lastRequest.messages)
    @Expect(prompt.indexOf("决策：") != None, true)
    @Expect(prompt.indexOf("结论：") != None, true)
    @Expect(prompt.indexOf("待办：") != None, true)
    @Expect(prompt.indexOf("状态变更：") != None, true)
    @Expect(prompt.indexOf("do X") != None, true)
    @Expect(prompt.indexOf("[7] fix Y") != None, true)
    @Expect(prompt.indexOf("重点") != None, true)
}

@Test
func summarizer_fromSettings() {
    // 未配置 → None
    let bad = LlmSettings("", "k", "", "openai")
    match (Summarizer.fromSettings(bad)) {
        case None => ()
        case Some(_) => @Fail("未配置 LLM 时应为 None")
    }
    // 配置 → Some
    let ok = LlmSettings("http://127.0.0.1:9/v1", "k", "m", "openai")
    match (Summarizer.fromSettings(ok)) {
        case Some(s) => @Expect(s.modelName(), "m")
        case None => @Fail("fromSettings 应为 Some")
    }
}

// 关思考：透传 chat_template_kwargs.enable_thinking=false。
// 动机（生产实测）：qwen3.5 这类推理模型默认先把输出预算花在 reasoning_content 上，
// 大窗口下正文可能为空、或整体超过 llm_api 的 300s readTimeout（day 窗口总结直接失败）。
@Test
func summarizer_passesDisableThinking() {
    let fake = CapturingProvider()
    let sum = Summarizer(fake, "m") // 默认 noThink=true, maxTokens=4096
    let entries = ArrayList<EntryText>()
    entries.add(EntryText(TEST_BASE, "do X"))
    let _ = sum.summarize(TEST_BASE, TEST_BASE + 60000, entries, "重点")

    @Expect(fake.lastRequest.maxTokens, Int64(4096))
    match (fake.lastRequest.extra.get("chat_template_kwargs")) {
        case Some(JsonValue.Map(m)) =>
            match (m.get("enable_thinking")) {
                case Some(JsonValue.Boolean(b)) => @Expect(b, false)
                case Some(other) => @Fail("enable_thinking 应为 Bool(false)，实际 " + other.toString())
                case None => @Fail("enable_thinking 缺失")
            }
        case Some(_) => @Fail("chat_template_kwargs 应为对象")
        case None => @Fail("chat_template_kwargs 未透传")
    }
}

// 可关：云端/严格 OpenAI 端点不接受该字段时置 noThink=false；maxTokens 也可放宽
@Test
func summarizer_noThinkOffLeavesExtraEmpty() {
    let fake = CapturingProvider()
    let sum = Summarizer(fake, "m", noThink: false, maxTokens: 8192)
    let entries = ArrayList<EntryText>()
    entries.add(EntryText(TEST_BASE, "do X"))
    let _ = sum.summarize(TEST_BASE, TEST_BASE + 60000, entries, "重点")

    @Expect(fake.lastRequest.maxTokens, Int64(8192))
    @Expect(fake.lastRequest.extra.size, Int64(0))
}

// LlmSettings 的两个旋钮可从 mcp 层传入（env 装配路径），默认值即生产口径
@Test
func summarizer_settingsCarryTuningKnobs() {
    let custom = LlmSettings("http://x/v1", "k", "m", "openai", noThink: false, maxTokens: 2048)
    @Expect(custom.noThink, false)
    @Expect(custom.maxTokens, Int64(2048))
    let def = LlmSettings("http://x/v1", "k", "m", "openai")
    @Expect(def.noThink, true)
    @Expect(def.maxTokens, Int64(4096))
}

// ---------- 输入预算（fix/summarize-budget）----------
// 背景（生产实测）：dsh/activity 09-15 窗口整天材料 82264 字符 ≈ 37563 token，
// 而端点给 qwen3.5-9b-mtp 的 ctx 只有 32768 → LLM 返回
// `request (35489 tokens) exceeds the available context size (32768 tokens)`
// → 总结任务 failed → 调度器每 10 分钟重试一次、永远失败（09-13 起）。

// 记录全部请求的 Provider：切块/聚合路径的断言依据
class RecordingProvider <: Provider {
    let reply: String
    let requests: ArrayList<ChatRequest>

    public init(reply: String) {
        this.reply = reply
        this.requests = ArrayList<ChatRequest>()
    }

    public func name(): String { "recording" }
    public func chat(req: ChatRequest): ChatResponse {
        this.requests.add(req)
        ChatResponse(AssistantMessage(ContentList.ofText(this.reply), "fake-model", "fake",
            StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let s = EventStream<ChatDelta, AssistantMessage>()
        s.setResult(AssistantMessage(ContentList.ofText(this.reply), "fake-model", "fake",
            StopReason.EndTurn, TokenUsage(0, 0), 0))
        s
    }
    public func promptAt(i: Int64): String { promptOf(this.requests[i].messages) }
}

// prompt 超过阈值就抛端点超限错误（复刻 llama.cpp 的 400 文案）：验证运行时降级
class OverflowProvider <: Provider {
    let maxPromptBytes: Int64
    var calls = Int64(0)

    public init(maxPromptBytes: Int64) { this.maxPromptBytes = maxPromptBytes }

    public func name(): String { "overflow" }
    public func chat(req: ChatRequest): ChatResponse {
        this.calls += 1
        if (promptOf(req.messages).size > this.maxPromptBytes) {
            throw Exception("request (99999 tokens) exceeds the available context size (32768 tokens)")
        }
        ChatResponse(AssistantMessage(ContentList.ofText("中间摘要"), "fake-model", "fake",
            StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let s = EventStream<ChatDelta, AssistantMessage>()
        s.setResult(AssistantMessage(ContentList.ofText("中间摘要"), "fake-model", "fake",
            StopReason.EndTurn, TokenUsage(0, 0), 0))
        s
    }
}

// 非超限错误（网络/鉴权等）：必须原样上抛，不能被预算逻辑吞掉
class BoomProvider <: Provider {
    public func name(): String { "boom" }
    public func chat(req: ChatRequest): ChatResponse {
        throw Exception("connection refused")
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let s = EventStream<ChatDelta, AssistantMessage>()
        s.setResult(AssistantMessage(ContentList.ofText("x"), "fake-model", "fake",
            StopReason.EndTurn, TokenUsage(0, 0), 0))
        s
    }
}

// 前 N 次（按 prompt 大小判断）抛指定文案的错误、之后成功：验证不同文案都走"缩小重试"
class CaseOverflowProvider <: Provider {
    let msg: String
    let maxPromptBytes: Int64
    var calls = Int64(0)

    public init(msg: String, maxPromptBytes!: Int64 = Int64(6000)) {
        this.msg = msg
        this.maxPromptBytes = maxPromptBytes
    }

    public func name(): String { "case-overflow" }
    public func chat(req: ChatRequest): ChatResponse {
        this.calls += 1
        if (promptOf(req.messages).size > this.maxPromptBytes) {
            throw Exception(this.msg)
        }
        ChatResponse(AssistantMessage(ContentList.ofText("中间摘要"), "fake-model", "fake",
            StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let s = EventStream<ChatDelta, AssistantMessage>()
        s.setResult(AssistantMessage(ContentList.ofText("中间摘要"), "fake-model", "fake",
            StopReason.EndTurn, TokenUsage(0, 0), 0))
        s
    }
}

func filler(bytes: Int64, tag: String): String {
    let sb = StringBuilder()
    sb.append(tag)
    var i = Int64(0)
    while (i < bytes) {
        sb.append("x")
        i += 1
    }
    sb.toString()
}

func occurrences(hay: String, needle: String): Int64 {
    hay.split(needle).size - 1
}

// 估算单位 = UTF-8 字节（String.size），byte/token 常量按此口径标定（实测 3.01，取 2 保守）
@Test
func summarizer_sizeUnitIsUtf8Bytes() {
    @Expect("仓颉".size, Int64(6))
    @Expect("abc".size, Int64(3))
}

@Test
func summarizer_budgetMath() {
    let fake = CapturingProvider()
    let sum = Summarizer(fake, "m", maxTokens: 4096, contextTokens: 32768, safetyTokens: 1024,
        bytesPerToken: 2)
    @Expect(sum.promptBudgetTokens(), Int64(27648))
    @Expect(sum.promptBudgetBytes(), Int64(55296))
    @Expect(sum.estimateTokens(Int64(0)), Int64(0))
    @Expect(sum.estimateTokens(Int64(2000)), Int64(1001))
    // 上下文很小也不会算出 0/负预算（有下限）
    let tiny = Summarizer(fake, "m", maxTokens: 4096, contextTokens: 4096, safetyTokens: 1024,
        bytesPerToken: 2)
    @Expect(tiny.promptBudgetTokens(), Int64(1024))
}

// 装得下 → 一次直连（保持原行为：调用数不因引入预算而增加）
@Test
func summarizer_directWhenWithinBudget() {
    let rec = RecordingProvider("决策：A\n结论：B")
    let sum = Summarizer(rec, "m")
    let entries = ArrayList<EntryText>()
    entries.add(EntryText(Int64(1), "do X"))
    entries.add(EntryText(Int64(2), "fix Y"))
    let r = sum.summarize(Int64(0), Int64(100), entries, "")
    @Expect(rec.requests.size, Int64(1))
    @Expect(r.strategy, "direct")
    @Expect(r.chunks, Int64(1))
    @Expect(r.clippedEntries, Int64(0))
    @Expect(r.text, "决策：A\n结论：B")
}

// 装不下 → 按条目边界切块（每块先出中间摘要）+ 末尾一次聚合；
// 每条材料恰好进一个块（不能重复计入，也不能丢）
@Test
func summarizer_chunksWhenOverBudget() {
    let rec = RecordingProvider("中间摘要")
    // 预算：ctx 8192 − 输出 1024 − 余量 1024 = 6144 token → ×2 = 12288 字节 − 模板 2048 = 10240
    let sum = Summarizer(rec, "m", maxTokens: 1024, contextTokens: 8192, safetyTokens: 1024,
        bytesPerToken: 2)
    let entries = ArrayList<EntryText>()
    for (i in 0..6) {
        entries.add(EntryText(Int64(i), filler(3000, "E" + i.toString() + "-")))
    }
    let r = sum.summarize(Int64(0), Int64(100), entries, "")
    // 每条 3000 字节 → 每块 3 条（9000 ≤ 10240）→ 2 块 + 1 次聚合 = 3 次调用
    @Expect(rec.requests.size, Int64(3))
    @Expect(r.strategy, "chunked")
    @Expect(r.chunks, Int64(2))
    @Expect(r.clippedEntries, Int64(0))
    // 块内共出现 6 条材料，各一次
    let chunkText = rec.promptAt(0) + rec.promptAt(1)
    for (i in 0..6) {
        @Expect(occurrences(chunkText, "E" + i.toString() + "-"), Int64(1))
    }
    // 最后一次是聚合（输入是各段中间摘要）
    @Expect(rec.promptAt(2).indexOf("分段中间摘要") != None, true)
}

// 单条就超块预算 → 截断（保头保尾 + 显式标记），且块数被调用上限约束
@Test
func summarizer_clipsOversizedEntryAndRespectsMaxCalls() {
    let rec = RecordingProvider("中间摘要")
    let sum = Summarizer(rec, "m", maxTokens: 1024, contextTokens: 8192, safetyTokens: 1024,
        bytesPerToken: 2, maxCalls: 4)
    let entries = ArrayList<EntryText>()
    for (i in 0..20) {
        entries.add(EntryText(Int64(i), filler(4000, "E" + i.toString() + "-")))
    }
    let r = sum.summarize(Int64(0), Int64(100), entries, "")
    // 调用上限 4 = 最多 3 块 + 1 次聚合
    @Expect(rec.requests.size <= Int64(4), true)
    @Expect(r.chunks <= Int64(3), true)
    // 20 条 × 4000 字节装进 3 块必须截断
    @Expect(r.clippedEntries > Int64(0), true)
    @Expect(r.text, "中间摘要")
}

// 估算失准的运行时兜底：端点真报超限 → 预算减半重试，任务不失败
@Test
func summarizer_fallsBackWhenEndpointRejectsPrompt() {
    // 阈值取得比首轮预算更小：首轮必然被拒，收缩预算后切块才成功
    let prov = OverflowProvider(Int64(6000))
    let sum = Summarizer(prov, "m", maxTokens: 1024, contextTokens: 8192, safetyTokens: 1024,
        bytesPerToken: 2)
    let entries = ArrayList<EntryText>()
    for (i in 0..8) {
        entries.add(EntryText(Int64(i), filler(2000, "E" + i.toString() + "-")))
    }
    let r = sum.summarize(Int64(0), Int64(100), entries, "")
    @Expect(prov.calls > Int64(1), true)   // 至少发生过一次"被拒 → 收缩重试"
    @Expect(r.text, "中间摘要")
}

// 非超限错误原样上抛（预算逻辑不得吞掉网络/鉴权错误）
@Test
func summarizer_propagatesNonContextErrors() {
    let sum = Summarizer(BoomProvider(), "m")
    let entries = ArrayList<EntryText>()
    entries.add(EntryText(Int64(1), "do X"))
    var thrown = false
    try {
        let _ = sum.summarize(Int64(0), Int64(100), entries, "")
    } catch (e: Exception) {
        thrown = e.message.indexOf("connection refused") != None
    }
    @Expect(thrown, true)
}

// 生成口径落库：direct / chunked 与预算参数都写进 SummaryRecord（事后可判断摘要怎么来的）
@Test
func summarizer_recordsGenerationStrategy() {
    let rec = RecordingProvider("中间摘要")
    let sum = Summarizer(rec, "m", maxTokens: 1024, contextTokens: 8192, safetyTokens: 1024,
        bytesPerToken: 2)
    let entries = ArrayList<EntryText>()
    for (i in 0..6) {
        entries.add(EntryText(Int64(i), filler(3000, "E" + i.toString() + "-")))
    }
    let r = sum.summarize(Int64(0), Int64(100), entries, "")
    @Expect(r.strategy, "chunked")
    @Expect(r.chunks, Int64(2))
    @Expect(r.inputTokens > Int64(0), true)
    @Expect(r.clippedEntries, Int64(0))
}

// ---------- 单次调用上限 + 真实错误文案（fix/summarize-timeout）----------
// 实测：4b 的 ctx=131072，但 llm_api 读超时只有 300s；一个 205K 字节的块（≈68K token real）
// prefill 就撞了超时。上下文预算必须再叠一层"单次调用预算"。
@Test
func summarizer_callBudgetCapsChunkSize() {
    let rec = RecordingProvider("中间摘要")
    // 上下文很大（131072）但单次调用只允许 4096 token → 2×4096 = 8192 字节/块（−2048 模板）
    let sum = Summarizer(rec, "m", maxTokens: 1024, contextTokens: 131072, safetyTokens: 1024,
        bytesPerToken: 2, callTokens: 4096)
    let entries = ArrayList<EntryText>()
    for (i in 0..4) {
        entries.add(EntryText(Int64(i), filler(2000, "E" + i.toString() + "-")))
    }
    let r = sum.summarize(Int64(0), Int64(100), entries, "")
    @Expect(r.strategy, "chunked")
    @Expect(r.chunks > Int64(1), true)
    @Expect(rec.requests.size, r.chunks + 1)
}

// 真实文案一：llama-server 路由模式的 500 `Context size has been exceeded.`（大写 S）
@Test
func summarizer_detectsCapitalizedContextError() {
    let prov = CaseOverflowProvider("Context size has been exceeded.")
    let sum = Summarizer(prov, "m", maxTokens: 1024, contextTokens: 8192, safetyTokens: 1024,
        bytesPerToken: 2)
    let entries = ArrayList<EntryText>()
    for (i in 0..8) {
        entries.add(EntryText(Int64(i), filler(2000, "E" + i.toString() + "-")))
    }
    let r = sum.summarize(Int64(0), Int64(100), entries, "")
    @Expect(prov.calls > Int64(1), true)
    @Expect(r.text, "中间摘要")
}

// 真实文案二：大 prompt 的 prefill 超过 llm_api 读超时（不是上下文超限，但同样"该切小"）
@Test
func summarizer_retriesOnReadTimeout() {
    let prov = CaseOverflowProvider("Client1.1 read response timeout and the connection is closed.")
    let sum = Summarizer(prov, "m", maxTokens: 1024, contextTokens: 8192, safetyTokens: 1024,
        bytesPerToken: 2)
    let entries = ArrayList<EntryText>()
    for (i in 0..8) {
        entries.add(EntryText(Int64(i), filler(2000, "E" + i.toString() + "-")))
    }
    let r = sum.summarize(Int64(0), Int64(100), entries, "")
    @Expect(prov.calls > Int64(1), true)
    @Expect(r.text, "中间摘要")
}

// 与上下文无关的错误（鉴权/网络）不触发收缩重试
@Test
func summarizer_authErrorIsNotRetried() {
    // 阈值取小 → 任何 prompt 都触发该错误；与上下文无关，必须原样上抛且不重试
    let prov = CaseOverflowProvider("OpenAI API error [401]: invalid api key", maxPromptBytes: Int64(64))
    let sum = Summarizer(prov, "m", maxTokens: 1024, contextTokens: 8192, safetyTokens: 1024,
        bytesPerToken: 2, callTokens: 4096)
    let entries = ArrayList<EntryText>()
    entries.add(EntryText(Int64(1), filler(2000, "E1-")))
    var thrown = false
    try {
        let _ = sum.summarize(Int64(0), Int64(100), entries, "")
    } catch (e: Exception) {
        thrown = e.message.indexOf("401") != None
    }
    @Expect(thrown, true)
    @Expect(prov.calls, Int64(1))
}

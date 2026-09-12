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

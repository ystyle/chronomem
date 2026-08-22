package chronomem.core

import llm_api.message.*
import llm_api.provider.*
import std.collection.*

// LLM 配置（core 自包含，不依赖 mcp 层；mcp 层负责从 env 装配成 LlmSettings）
public struct LlmSettings {
    public let baseUrl: String
    public let apiKey: String
    public let model: String
    public let provider: String   // openai / anthropic / ollama

    public init(baseUrl: String, apiKey: String, model: String, provider: String) {
        this.baseUrl = baseUrl
        this.apiKey = apiKey
        this.model = model
        this.provider = provider
    }

    // 语义总结可用性：未配置 baseURL/model 时不可用（其余工具不依赖 LLM）
    public func valid(): Bool { this.baseUrl != "" && this.model != "" }
}

// 待总结条目（ts + 文本；refs 落 SummaryRecord 用）
public struct EntryText {
    public let ts: Int64
    public let text: String

    public init(ts: Int64, text: String) {
        this.ts = ts
        this.text = text
    }
}

// 语义总结器：把窗口条目/低层总结提炼为结构化摘要（决策/结论/待办/状态变更/关键词），
// 生成 SummaryRecord。复用 llm_api Provider（OpenAI 兼容端点），见 design.md §7。
public class Summarizer {
    private let provider: Provider
    private let model: String

    public init(provider: Provider, model: String) {
        this.provider = provider
        this.model = model
    }

    public func modelName(): String { this.model }

    // 从配置构造（未配置 baseUrl/model 时返回 None → 调用方报「未配置 LLM」）
    public static func fromSettings(s: LlmSettings): Option<Summarizer> {
        if (!s.valid()) { return None }
        let prov: Provider = match (s.provider) {
            case "anthropic" => AnthropicProvider("chronomem", s.baseUrl, s.apiKey)
            case "ollama" => OllamaProvider("chronomem", s.baseUrl)
            case _ => OpenAIProvider("chronomem", s.baseUrl, s.apiKey)
        }
        Some(Summarizer(prov, s.model))
    }

    // 总结窗口：entries（ts + 文本）→ 结构化摘要 → SummaryRecord（refs = 条目 ts）
    // model 可选覆盖（缺省用配置模型）
    public func summarize(windowFrom: Int64, windowTo: Int64,
        entries: ArrayList<EntryText>, instructions: String,
        model!: Option<String> = None): SummaryRecord {
        let useModel = match (model) {
            case Some(m) => m
            case None => this.model
        }
        let prompt = buildPrompt(windowFrom, windowTo, entries, instructions)
        let msgs = ArrayList<Message>()
        msgs.add(UserMessage(ContentList.ofText(prompt), nowMs()))
        let req = ChatRequest(useModel, msgs, 0.2, 2000, None, ArrayList<OpenAITool>())
        let resp = this.provider.chat(req)
        let refs = ArrayList<Int64>()
        for (e in entries) { refs.add(e.ts) }
        SummaryRecord(nowMs(), windowFrom, windowTo, useModel, refs, instructions, messageText(resp.message))
    }
}

func buildPrompt(windowFrom: Int64, windowTo: Int64, entries: ArrayList<EntryText>, instructions: String): String {
    let sb = StringBuilder()
    sb.append("你是忆时塔（chronomem）的语义总结器。请把以下时间窗口内的时序记录提炼成结构化摘要。\n")
    sb.append("时间窗口: " + windowFrom.toString() + " ~ " + windowTo.toString() + "\n")
    if (instructions != "") {
        sb.append("额外要求: " + instructions + "\n")
    }
    sb.append("请严格按以下章节输出（每节一行或列表）：\n")
    sb.append("决策：\n结论：\n待办：\n状态变更：\n关键词：\n")
    sb.append("--- 记录 ---\n")
    for (e in entries) {
        sb.append("[" + e.ts.toString() + "] " + e.text + "\n")
    }
    sb.toString()
}

// AssistantMessage → 纯文本（拼 TextBlock）
func messageText(m: AssistantMessage): String {
    let sb = StringBuilder()
    for (b in m.content.blocks()) {
        match (b) {
            case ContentBlock.TextBlock(t) => sb.append(t)
            case _ => ()
        }
    }
    sb.toString()
}

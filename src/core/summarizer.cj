package chronomem.core

import llm_api.message.*
import llm_api.provider.*
import jsonvalue.*
import std.collection.*

// 总结请求的默认口径（可被 CHRONOLOG_SUMMARY_NO_THINK / CHRONOLOG_SUMMARY_MAX_TOKENS 覆盖）
public let DEFAULT_SUMMARY_NO_THINK = true
public let DEFAULT_SUMMARY_MAX_TOKENS = Int64(4096)

// LLM 配置（core 自包含，不依赖 mcp 层；mcp 层负责从 env 装配成 LlmSettings）
public struct LlmSettings {
    public let baseUrl: String
    public let apiKey: String
    public let model: String
    public let provider: String   // openai / anthropic / ollama
    // 总结请求的两个旋钮：
    //  - noThink：关掉推理模型的"思考"（透传 chat_template_kwargs.enable_thinking=false）。
    //    qwen3.5 这类模型默认会先把输出预算花在 reasoning_content 上——大窗口下正文可能为空，
    //    或整体超过 llm_api 的 300s readTimeout（生产实测：day 窗口总结任务直接失败）。
    //  - maxTokens：输出上限。总结用不到 3 万 token；原先的 32768 只是给"思考"留了放大器。
    public let noThink: Bool
    public let maxTokens: Int64

    public init(baseUrl: String, apiKey: String, model: String, provider: String,
        noThink!: Bool = DEFAULT_SUMMARY_NO_THINK, maxTokens!: Int64 = DEFAULT_SUMMARY_MAX_TOKENS) {
        this.baseUrl = baseUrl
        this.apiKey = apiKey
        this.model = model
        this.provider = provider
        this.noThink = noThink
        this.maxTokens = maxTokens
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
    private let noThink: Bool
    private let maxTokens: Int64

    public init(provider: Provider, model: String, noThink!: Bool = DEFAULT_SUMMARY_NO_THINK,
        maxTokens!: Int64 = DEFAULT_SUMMARY_MAX_TOKENS) {
        this.provider = provider
        this.model = model
        this.noThink = noThink
        this.maxTokens = maxTokens
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
        Some(Summarizer(prov, s.model, noThink: s.noThink, maxTokens: s.maxTokens))
    }

    // 总结窗口：entries（ts + 文本）→ 结构化摘要 → SummaryRecord（refs = 条目 ts）
    // model 可选覆盖（缺省用配置模型）；groupKey 可选（该条总结的分组值，用于按项目/维度分组总结）
    public func summarize(windowFrom: Int64, windowTo: Int64,
        entries: ArrayList<EntryText>, instructions: String,
        model!: Option<String> = None, groupKey!: Option<String> = None): SummaryRecord {
        let useModel = match (model) {
            case Some(m) => m
            case None => this.model
        }
        let prompt = buildPrompt(windowFrom, windowTo, entries, instructions, groupKey: groupKey)
        let msgs = ArrayList<Message>()
        msgs.add(UserMessage(ContentList.ofText(prompt), nowMs()))
        // 关思考：把 chat_template_kwargs.enable_thinking=false 透传给 OpenAI 兼容端点
        // （llm_api 的 ChatRequest.extra 会并入请求体顶层）。实测同一问题：开思考 4.2s 且
        // 预算可能被 reasoning 吃光导致正文为空；关思考 0.9s 且有正文。
        let extra = HashMap<String, JsonValue>()
        if (this.noThink) {
            let kwargs = HashMap<String, JsonValue>()
            kwargs["enable_thinking"] = JsonValue.Boolean(false)
            extra["chat_template_kwargs"] = JsonValue.Map(kwargs)
        }
        let req = ChatRequest(useModel, msgs, 0.2, this.maxTokens, None, ArrayList<OpenAITool>(), extra)
        let resp = this.provider.chat(req)
        let refs = ArrayList<Int64>()
        for (e in entries) { refs.add(e.ts) }
        SummaryRecord(nowMs(), windowFrom, windowTo, useModel, refs, instructions, messageText(resp.message), groupKey: groupKey)
    }
}

func buildPrompt(windowFrom: Int64, windowTo: Int64, entries: ArrayList<EntryText>, instructions: String,
    groupKey!: Option<String> = None): String {
    let sb = StringBuilder()
    sb.append("你是忆时塔（chronomem）的语义总结器。请把以下时间窗口内的时序记录提炼成结构化摘要。\n")
    sb.append("时间窗口: " + windowFrom.toString() + " ~ " + windowTo.toString() + "\n")
    match (groupKey) {
        case Some(g) => sb.append("本次总结仅针对分组【" + g + "】（其余分组请忽略）\n")
        case None => ()
    }
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

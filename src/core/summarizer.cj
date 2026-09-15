package chronomem.core

import llm_api.message.*
import llm_api.provider.*
import jsonvalue.*
import std.collection.*

// 总结请求的默认口径（可被 CHRONOLOG_SUMMARY_NO_THINK / CHRONOLOG_SUMMARY_MAX_TOKENS 覆盖）
public let DEFAULT_SUMMARY_NO_THINK = true
public let DEFAULT_SUMMARY_MAX_TOKENS = Int64(4096)

// 总结输入预算的默认口径（端点上下文的客户端侧防线）：
//  - contextTokens：端点给该模型分配的上下文（llama.cpp/llama-swap 的 --ctx-size）。
//    实测：qwen3.5-9b-mtp = 32768、qwen3.5-4b / 2b = 131072。客户端不知道这个数，
//    窗口材料一超就会被端点整单拒绝（`exceeds the available context size`）——
//    自动总结于是每 10 分钟重试一次、永远失败。故必须可配 + 有预算。
//  - safetyTokens：输出之外的余量（模板、行前缀、估算误差）。
//  - bytesPerToken：UTF-8 字节/token 的**保守**估值（实测 09-15 窗口 3.01，取 2 留 33% 余量；
//    估值偏小 = 低估容量 = 提前切块，安全方向）。
//  - maxCalls：单个总结任务的 LLM 调用上限（切块数 + 聚合 1 次），防病态输入把调用数放大。
public let DEFAULT_SUMMARY_CONTEXT_TOKENS = Int64(32768)
public let DEFAULT_SUMMARY_SAFETY_TOKENS = Int64(1024)
public let DEFAULT_SUMMARY_BYTES_PER_TOKEN = Int64(2)
public let DEFAULT_SUMMARY_MAX_CALLS = Int64(8)

// 中间段摘要的输出上限：比最终摘要（maxTokens）小，保证聚合阶段的输入自己也装得下预算
let PART_SUMMARY_MAX_TOKENS = Int64(1024)
// 预算下限 / prompt 模板预留 / 截断标记预留
let MIN_PROMPT_TOKENS = Int64(1024)
let PROMPT_OVERHEAD_BYTES = Int64(2048)
let CLIP_MARKER_RESERVE_BYTES = Int64(96)
// 端点报超限时的预算收缩次数（估算失准的运行时兜底）
let BUDGET_SHRINK_LEVELS = 3

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
    // 输入预算（见上方 DEFAULT_SUMMARY_* 说明）
    public let contextTokens: Int64
    public let safetyTokens: Int64
    public let bytesPerToken: Int64
    public let maxCalls: Int64

    public init(baseUrl: String, apiKey: String, model: String, provider: String,
        noThink!: Bool = DEFAULT_SUMMARY_NO_THINK, maxTokens!: Int64 = DEFAULT_SUMMARY_MAX_TOKENS,
        contextTokens!: Int64 = DEFAULT_SUMMARY_CONTEXT_TOKENS,
        safetyTokens!: Int64 = DEFAULT_SUMMARY_SAFETY_TOKENS,
        bytesPerToken!: Int64 = DEFAULT_SUMMARY_BYTES_PER_TOKEN,
        maxCalls!: Int64 = DEFAULT_SUMMARY_MAX_CALLS) {
        this.baseUrl = baseUrl
        this.apiKey = apiKey
        this.model = model
        this.provider = provider
        this.noThink = noThink
        this.maxTokens = maxTokens
        this.contextTokens = contextTokens
        this.safetyTokens = safetyTokens
        this.bytesPerToken = bytesPerToken
        this.maxCalls = maxCalls
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

// 切块计划：一次装得下 → 单块直连；装不下 → 多块 map + 一次聚合
struct ChunkPlan {
    let chunks: ArrayList<ArrayList<EntryText>>
    let clipped: Int64        // 被截断的条目数
    let estTokens: Int64      // 最大一块（直连 = 整份）的输入 token 估算
    let plannedCalls: Int64

    init(chunks: ArrayList<ArrayList<EntryText>>, clipped: Int64, estTokens: Int64, plannedCalls: Int64) {
        this.chunks = chunks
        this.clipped = clipped
        this.estTokens = estTokens
        this.plannedCalls = plannedCalls
    }
}

// 语义总结器：把窗口条目/低层总结提炼为结构化摘要（决策/结论/待办/状态变更/关键词），
// 生成 SummaryRecord。复用 llm_api Provider（OpenAI 兼容端点），见 design.md §7。
//
// 输入预算（fix/summarize-budget）：端点上下文是有限资源，而窗口材料随会话活跃度增长
// （dsh 压缩摘要单条上限 16000 字符，一天多次压缩即可把整天材料推到 3 万 token 以上）。
// 策略：能一次就一次；装不下按**条目边界**切块，各自出中间摘要，再聚合为最终摘要；
// 单条即超预算时截断（保头保尾 + 显式标记）；端点仍报超限时按预算减半重试（估算失准兜底）。
public class Summarizer {
    private let provider: Provider
    private let model: String
    private let noThink: Bool
    private let maxTokens: Int64
    private let contextTokens: Int64
    private let safetyTokens: Int64
    private let bytesPerToken: Int64
    private let maxCalls: Int64

    public init(provider: Provider, model: String, noThink!: Bool = DEFAULT_SUMMARY_NO_THINK,
        maxTokens!: Int64 = DEFAULT_SUMMARY_MAX_TOKENS,
        contextTokens!: Int64 = DEFAULT_SUMMARY_CONTEXT_TOKENS,
        safetyTokens!: Int64 = DEFAULT_SUMMARY_SAFETY_TOKENS,
        bytesPerToken!: Int64 = DEFAULT_SUMMARY_BYTES_PER_TOKEN,
        maxCalls!: Int64 = DEFAULT_SUMMARY_MAX_CALLS) {
        this.provider = provider
        this.model = model
        this.noThink = noThink
        this.maxTokens = maxTokens
        this.contextTokens = contextTokens
        this.safetyTokens = safetyTokens
        this.bytesPerToken = bytesPerToken
        this.maxCalls = maxCalls
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
        Some(Summarizer(prov, s.model, noThink: s.noThink, maxTokens: s.maxTokens,
            contextTokens: s.contextTokens, safetyTokens: s.safetyTokens,
            bytesPerToken: s.bytesPerToken, maxCalls: s.maxCalls))
    }

    // 提示词可用的 token 预算（端点上下文 − 输出 − 余量，不小于下限）
    public func promptBudgetTokens(): Int64 {
        atLeast(this.contextTokens - this.maxTokens - this.safetyTokens, MIN_PROMPT_TOKENS)
    }

    // 提示词可用的字节预算（按保守的字节/token 换算）
    public func promptBudgetBytes(): Int64 {
        this.promptBudgetTokens() * this.bytesPerToken
    }

    // token 估算（服务端不吐 tokenizer 时的客户端口径；实测值见 DEFAULT_SUMMARY_BYTES_PER_TOKEN）
    public func estimateTokens(bytes: Int64): Int64 {
        if (bytes <= 0) { return Int64(0) }
        bytes / this.bytesPerToken + 1
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
        // 预算阶梯：先用配置预算；端点仍报超限（说明估算偏乐观）则预算减半重试
        var budget = this.promptBudgetBytes() - PROMPT_OVERHEAD_BYTES
        var level = 0
        var lastMsg = ""
        var lastShape = ""
        while (level < BUDGET_SHRINK_LEVELS) {
            let plan = planChunks(entries, budget, this.maxCalls, this.bytesPerToken)
            let shape = plan.chunks.size.toString() + "/" + plan.clipped.toString()
            // 预算减半后切块方案没变（小输入、无截断）→ 再打一次是同一份 prompt，纯浪费
            if (level > 0 && shape == lastShape) {
                throw Exception("总结输入超出端点上下文（收缩预算后切块方案未变，停止重试）：" + lastMsg)
            }
            lastShape = shape
            try {
                return this.runPlan(windowFrom, windowTo, entries, instructions, useModel, groupKey, plan)
            } catch (e: Exception) {
                if (!isContextOverflow(e.message)) { throw e }
                lastMsg = e.message
                budget = atLeast(budget / 2, MIN_PROMPT_TOKENS * this.bytesPerToken)
                level += 1
            }
        }
        throw Exception("总结输入超出端点上下文（预算已收缩 " + BUDGET_SHRINK_LEVELS.toString()
            + " 次仍失败）：" + lastMsg)
    }

    // 执行切块计划：单块直连；多块先各自出中间摘要，再聚合成最终摘要
    private func runPlan(windowFrom: Int64, windowTo: Int64, allEntries: ArrayList<EntryText>,
        instructions: String, useModel: String, groupKey: Option<String>, plan: ChunkPlan): SummaryRecord {
        let refs = ArrayList<Int64>()
        for (e in allEntries) { refs.add(e.ts) }
        if (plan.chunks.size <= 1) {
            let only = if (plan.chunks.size == 0) { ArrayList<EntryText>() } else { plan.chunks[0] }
            let text = this.callModel(useModel,
                buildPrompt(windowFrom, windowTo, only, instructions, groupKey: groupKey), this.maxTokens)
            let strategy = if (plan.clipped > 0) { "direct+clip" } else { "direct" }
            return SummaryRecord(nowMs(), windowFrom, windowTo, useModel, refs, instructions, text,
                groupKey: groupKey, strategy: strategy, chunks: 1, inputTokens: plan.estTokens,
                clippedEntries: plan.clipped)
        }
        // map：逐块中间摘要（输出上限收紧，保证聚合阶段自己也装得下）
        let parts = ArrayList<String>()
        var idx = Int64(0)
        for (c in plan.chunks) {
            idx += 1
            let p = this.callModel(useModel,
                buildChunkPrompt(windowFrom, windowTo, c, instructions, groupKey, idx, plan.chunks.size),
                minInt64(this.maxTokens, PART_SUMMARY_MAX_TOKENS))
            parts.add(p)
        }
        // reduce：把各段中间摘要合并成一份最终摘要（同样要过预算，超了按段截断）
        let fitted = fitParts(parts, this.promptBudgetBytes() - PROMPT_OVERHEAD_BYTES)
        let text = this.callModel(useModel,
            buildReducePrompt(windowFrom, windowTo, fitted, instructions, groupKey), this.maxTokens)
        return SummaryRecord(nowMs(), windowFrom, windowTo, useModel, refs, instructions, text,
            groupKey: groupKey, strategy: "chunked", chunks: plan.chunks.size,
            inputTokens: plan.estTokens, clippedEntries: plan.clipped)
    }

    // 单次 LLM 调用（关思考透传 + 输出上限）
    private func callModel(useModel: String, prompt: String, maxTok: Int64): String {
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
        let req = ChatRequest(useModel, msgs, 0.2, maxTok, None, ArrayList<OpenAITool>(), extra)
        let resp = this.provider.chat(req)
        messageText(resp.message)
    }
}

// 端点超限报错识别（llama.cpp：`request (N tokens) exceeds the available context size (M tokens)`；
// 各家网关文案不同，这里覆盖常见几种）
func isContextOverflow(msg: String): Bool {
    if (msg.indexOf("exceeds the available context size") != None) { return true }
    if (msg.indexOf("exceeds context") != None) { return true }
    if (msg.indexOf("context size") != None) { return true }
    if (msg.indexOf("context length") != None) { return true }
    if (msg.indexOf("context_length_exceeded") != None) { return true }
    false
}

// 按预算切块：贪心按条目顺序装块（只在条目边界切）。
// 块数上限：预算装不下全部材料时，用"截断单条"把总量压进 maxChunks 块——
// 做法是按「每组最多 groupSize 条」反推单条上限（截得越短，一块能装的条数越多，块数越少）。
// 注意不能用"收紧单块预算"来收敛块数：那只会让每块装得更少、块数更多。
func planChunks(entries: ArrayList<EntryText>, budgetBytes: Int64, maxChunks: Int64,
    bytesPerToken: Int64): ChunkPlan {
    let maxAllowed = atLeast(maxChunks, Int64(2)) - 1   // 留一次给聚合
    let per = atLeast(budgetBytes, Int64(1024))
    var plan = greedyChunks(entries, per, bytesPerToken, Int64(-1))
    var rounds = 0
    let n = atLeast(Int64(entries.size), Int64(1))
    while (plan.chunks.size > maxAllowed && rounds < 5) {
        let groupSize = (n + maxAllowed - 1) / maxAllowed
        let shrink = Int64(rounds + 1)
        let perEntry = atLeast(per / atLeast(groupSize * shrink, Int64(1)), Int64(64))
        plan = greedyChunks(entries, per, bytesPerToken, perEntry)
        rounds += 1
    }
    plan
}

// 贪心装块：单条超预算 → 截断（保头保尾 + 标记）后单独成块
func greedyChunks(entries: ArrayList<EntryText>, perChunkBytes: Int64, bytesPerToken: Int64,
    perEntryCap: Int64): ChunkPlan {
    let chunks = ArrayList<ArrayList<EntryText>>()
    if (entries.size == 0) {
        chunks.add(ArrayList<EntryText>())
        return ChunkPlan(chunks, 0, PROMPT_OVERHEAD_BYTES / atLeast(bytesPerToken, Int64(1)) + 1, 1)
    }
    var cur = ArrayList<EntryText>()
    var curBytes = Int64(0)
    var clipped = Int64(0)
    var maxChunkBytes = Int64(0)
    for (e in entries) {
        var limit = perChunkBytes
        if (perEntryCap > 0 && perEntryCap < limit) { limit = perEntryCap }
        let (text, wasClipped) = clipEntryText(e.text, limit)
        if (wasClipped) { clipped += 1 }
        let len = text.size
        if (cur.size > 0 && curBytes + len > perChunkBytes) {
            chunks.add(cur)
            if (curBytes > maxChunkBytes) { maxChunkBytes = curBytes }
            cur = ArrayList<EntryText>()
            curBytes = 0
        }
        cur.add(EntryText(e.ts, text))
        curBytes += len
    }
    if (cur.size > 0) {
        chunks.add(cur)
        if (curBytes > maxChunkBytes) { maxChunkBytes = curBytes }
    }
    let est = (maxChunkBytes + PROMPT_OVERHEAD_BYTES) / atLeast(bytesPerToken, Int64(1)) + 1
    let calls = if (chunks.size <= 1) { Int64(1) } else { chunks.size + 1 }
    ChunkPlan(chunks, clipped, est, calls)
}

// 单条截断：保头保尾 + 显式标记（按 Rune 走，绝不切坏 UTF-8；结果 ≤ maxBytes）
func clipEntryText(text: String, maxBytes: Int64): (String, Bool) {
    if (text.size <= maxBytes) { return (text, false) }
    let budget = atLeast(maxBytes - CLIP_MARKER_RESERVE_BYTES, Int64(64))
    let runes = text.toRuneArray()
    let headBudget = budget / 2
    let tailBudget = budget - headBudget
    let head = ArrayList<Rune>()
    var usedHead = Int64(0)
    var i = Int64(0)
    while (i < runes.size) {
        let n = utf8Size(runes[i])
        if (usedHead + n > headBudget) { break }
        head.add(runes[i])
        usedHead += n
        i += 1
    }
    let tailRev = ArrayList<Rune>()
    var usedTail = Int64(0)
    var j = runes.size - 1
    while (j >= i) {
        let n = utf8Size(runes[j])
        if (usedTail + n > tailBudget) { break }
        tailRev.add(runes[j])
        usedTail += n
        j -= 1
    }
    let tail = ArrayList<Rune>()
    var k = tailRev.size - 1
    while (k >= 0) {
        tail.add(tailRev[k])
        k -= 1
    }
    let dropped = text.size - usedHead - usedTail
    let marker = "…[已截断 " + dropped.toString() + " 字节]…"
    (String(head.toArray()) + marker + String(tail.toArray()), true)
}

// Rune 的 UTF-8 字节数
func utf8Size(r: Rune): Int64 {
    let c = UInt32(r)
    if (c < 0x80) { return Int64(1) }
    if (c < 0x800) { return Int64(2) }
    if (c < 0x10000) { return Int64(3) }
    Int64(4)
}

// 聚合阶段的输入保护：各段摘要合计超过字节预算时按段均分后截断
func fitParts(parts: ArrayList<String>, budgetBytes: Int64): ArrayList<String> {
    var total = Int64(0)
    for (p in parts) { total += p.size }
    if (total <= budgetBytes) { return parts }
    let per = atLeast(budgetBytes / atLeast(Int64(parts.size), Int64(1)), Int64(256))
    let out = ArrayList<String>()
    for (p in parts) {
        let (t, _) = clipEntryText(p, per)
        out.add(t)
    }
    out
}

func buildPrompt(windowFrom: Int64, windowTo: Int64, entries: ArrayList<EntryText>, instructions: String,
    groupKey!: Option<String> = None): String {
    let sb = promptHeader(windowFrom, windowTo, instructions, groupKey)
    for (e in entries) {
        sb.append("[" + e.ts.toString() + "] " + e.text + "\n")
    }
    sb.toString()
}

// 中间段摘要的 prompt：说明这是分段材料、输出用于后续汇总
func buildChunkPrompt(windowFrom: Int64, windowTo: Int64, entries: ArrayList<EntryText>, instructions: String,
    groupKey: Option<String>, part: Int64, parts: Int64): String {
    let sb = promptHeader(windowFrom, windowTo, instructions, groupKey)
    sb.append("本次材料较长，已按长度切成 " + parts.toString() + " 段，这是【第 " + part.toString()
        + " 段】。请只依据本段材料输出中间摘要（保留事实、标识符、结论与待办，不要臆测其它段的内容）。\n")
    for (e in entries) {
        sb.append("[" + e.ts.toString() + "] " + e.text + "\n")
    }
    sb.toString()
}

// 聚合 prompt：把各段中间摘要合并成最终摘要
func buildReducePrompt(windowFrom: Int64, windowTo: Int64, parts: ArrayList<String>, instructions: String,
    groupKey: Option<String>): String {
    let sb = promptHeader(windowFrom, windowTo, instructions, groupKey)
    sb.append("以下是同一时间窗口的分段中间摘要，请合并成一份最终摘要（去重、按主题归并，不要提及分段）。\n")
    var i = Int64(0)
    for (p in parts) {
        i += 1
        sb.append("--- 第 " + i.toString() + " 段中间摘要 ---\n" + p + "\n")
    }
    sb.toString()
}

func promptHeader(windowFrom: Int64, windowTo: Int64, instructions: String,
    groupKey: Option<String>): StringBuilder {
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
    sb
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

func atLeast(v: Int64, floor: Int64): Int64 {
    if (v < floor) { return floor }
    v
}

func minInt64(a: Int64, b: Int64): Int64 {
    if (a < b) { return a }
    b
}

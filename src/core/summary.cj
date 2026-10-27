package chronomem.core

import std.collection.*
import stdx.encoding.json.stream.*

// 语义总结记录（固定结构，json.stream 序列化）。
// 存于 <type>.summary series；refs = 被总结的条目 ts（原始条目 或 更低层总结）。
// 语义总结是物化的第三种模式，也是「语义回顾」（recall mode=summary）的内容来源与前提
// （design.md §7）：可递归对总结再总结，实现「分季财报式」语义压缩。
// groupKey：该条总结对应的分组值（如按 proj 分组时 = 项目名；None = 未按分组维度总结 / 未分组）。
public struct SummaryRecord <: JsonSerializable & JsonDeserializable<SummaryRecord> {
    public let ts: Int64
    public let windowFrom: Int64
    public let windowTo: Int64
    public let model: String
    public let refs: ArrayList<Int64>
    public let instructions: String
    public let text: String
    public let groupKey: Option<String>
    // 生成口径（fix/summarize-budget）：direct = 一次直连；direct+clip = 直连但有单条被截断；
    // chunked = 超预算按条目边界切块后聚合。chunks = 实际块数（直连=1）。
    // inputTokens = 客户端估算的输入 token（估算口径见 Summarizer.estimateTokens）。
    public let strategy: String
    public let chunks: Int64
    public let inputTokens: Int64
    public let clippedEntries: Int64

    public init(ts: Int64, windowFrom: Int64, windowTo: Int64,
        model: String, refs: ArrayList<Int64>, instructions: String, text: String,
        groupKey!: Option<String> = None, strategy!: String = "direct", chunks!: Int64 = 1,
        inputTokens!: Int64 = 0, clippedEntries!: Int64 = 0) {
        this.ts = ts
        this.windowFrom = windowFrom
        this.windowTo = windowTo
        this.model = model
        this.refs = refs
        this.instructions = instructions
        this.text = text
        this.groupKey = groupKey
        this.strategy = strategy
        this.chunks = chunks
        this.inputTokens = inputTokens
        this.clippedEntries = clippedEntries
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("ts").writeValue(this.ts)
        w.writeName("windowFrom").writeValue(this.windowFrom)
        w.writeName("windowTo").writeValue(this.windowTo)
        w.writeName("model").writeValue(this.model)
        w.writeName("refs").writeValue(this.refs)
        w.writeName("instructions").writeValue(this.instructions)
        w.writeName("text").writeValue(this.text)
        w.writeName("groupKey").writeValue(this.groupKey)
        w.writeName("strategy").writeValue(this.strategy)
        w.writeName("chunks").writeValue(this.chunks)
        w.writeName("inputTokens").writeValue(this.inputTokens)
        w.writeName("clippedEntries").writeValue(this.clippedEntries)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): SummaryRecord {
        var ts = Int64(0)
        var windowFrom = Int64(0)
        var windowTo = Int64(0)
        var model = ""
        var refs = ArrayList<Int64>()
        var instructions = ""
        var text = ""
        var groupKey: Option<String> = None
        var strategy = "direct"
        var chunks = Int64(1)
        var inputTokens = Int64(0)
        var clippedEntries = Int64(0)
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "ts" => ts = r.readValue<Int64>()
                case "windowFrom" => windowFrom = r.readValue<Int64>()
                case "windowTo" => windowTo = r.readValue<Int64>()
                case "model" => model = r.readValue<String>()
                case "refs" => refs = r.readValue<ArrayList<Int64>>()
                case "instructions" => instructions = r.readValue<String>()
                case "text" => text = r.readValue<String>()
                case "groupKey" => groupKey = r.readValue<Option<String>>()
                case "strategy" => strategy = r.readValue<String>()
                case "chunks" => chunks = r.readValue<Int64>()
                case "inputTokens" => inputTokens = r.readValue<Int64>()
                case "clippedEntries" => clippedEntries = r.readValue<Int64>()
                case _ => r.skip()
            }
        }
        r.endObject()
        SummaryRecord(ts, windowFrom, windowTo, model, refs, instructions, text, groupKey: groupKey,
            strategy: strategy, chunks: chunks, inputTokens: inputTokens, clippedEntries: clippedEntries)
    }
}

// ---------- 分组的展示口径 ----------
//
// 语义总结的 groupKey 有两个特殊值，它们的「给人看的名字」必须只有一处定义：
// 写入侧（summarize）与读取侧（UI 的窗口摘要、分组过滤下拉）若各拼一份字面量，
// 过滤条件就会因为少一个前缀字符而恒空 —— 屏幕上显示着【未分组】却永远查不到它。
//
// 未分组 = 条目缺少任一分组维度 tag。存的是一个含 NUL 的哨兵串：真实的 tag 值
// 不可能包含 NUL，所以它不会与任何真实分组重名，也不会被误当成某个项目。

/** 未分组（条目缺分组维度 tag）的 groupKey 哨兵值。 */
public let UNGROUPED_GROUP_KEY = "\u{0000}未分组"

/** groupKey → 展示名：None = 整窗总结（类型未配分组维度）；哨兵 = 未分组；否则原值。 */
public func summaryGroupLabel(key: Option<String>): String {
    match (key) {
        case None => "整窗"
        case Some(v) => if (v == UNGROUPED_GROUP_KEY) { "未分组" } else { v }
    }
}

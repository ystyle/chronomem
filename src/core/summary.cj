package chronomem.core

import std.collection.*
import stdx.encoding.json.stream.*

// 语义总结记录（固定结构，json.stream 序列化）。
// 存于 <type>.summary series；refs = 被总结的条目 ts（原始条目 或 更低层总结）。
// 语义总结是物化的第三种模式，也是「语义回顾」（recall mode=summary）的内容来源与前提
// （design.md §7）：可递归对总结再总结，实现「分季财报式」语义压缩。
// Phase 2 的 Summarizer 生成；本文件先定义数据结构。
public struct SummaryRecord <: JsonSerializable & JsonDeserializable<SummaryRecord> {
    public let ts: Int64
    public let windowFrom: Int64
    public let windowTo: Int64
    public let model: String
    public let refs: ArrayList<Int64>
    public let instructions: String
    public let text: String

    public init(ts: Int64, windowFrom: Int64, windowTo: Int64,
        model: String, refs: ArrayList<Int64>, instructions: String, text: String) {
        this.ts = ts
        this.windowFrom = windowFrom
        this.windowTo = windowTo
        this.model = model
        this.refs = refs
        this.instructions = instructions
        this.text = text
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
                case _ => r.skip()
            }
        }
        r.endObject()
        SummaryRecord(ts, windowFrom, windowTo, model, refs, instructions, text)
    }
}

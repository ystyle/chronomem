package chronomem.core

import tsdb.*
import std.collection.*
import stdx.encoding.json.stream.*

// 记忆类型元数据（固定结构，json.stream 序列化；schema/retention 可空）。
// 落库于 tsdb `__meta` series（tag=name 定位），重启时重建注册表。
public struct TypeMeta <: JsonSerializable & JsonDeserializable<TypeMeta> {
    public let name: String                 // 类型名（白名单 [A-Za-z0-9_/-]，如 worklog、proj/decisions）
    public let description: String
    public let schema: Option<String>       // 可选字段描述（JSON 字符串；宽松模式，仅作文档/LLM 提示）
    public let levels: ArrayList<String>    // 粒度链（§5.1）
    public let retention: Option<String>    // 可选保留期（如 "30d"，后续接入 tsdb setRetention）
    public let createdAt: Int64

    public init(name: String, description: String, schema: Option<String>,
        levels: ArrayList<String>, retention: Option<String>, createdAt: Int64) {
        this.name = name
        this.description = description
        this.schema = schema
        this.levels = levels
        this.retention = retention
        this.createdAt = createdAt
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("name").writeValue(this.name)
        w.writeName("description").writeValue(this.description)
        w.writeName("schema").writeValue(this.schema)
        w.writeName("levels").writeValue(this.levels)
        w.writeName("retention").writeValue(this.retention)
        w.writeName("createdAt").writeValue(this.createdAt)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): TypeMeta {
        var name = ""
        var description = ""
        var schema: Option<String> = None
        var levels = ArrayList<String>()
        var retention: Option<String> = None
        var createdAt = Int64(0)
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "name" => name = r.readValue<String>()
                case "description" => description = r.readValue<String>()
                case "schema" => schema = r.readValue<Option<String>>()
                case "levels" => levels = r.readValue<ArrayList<String>>()
                case "retention" => retention = r.readValue<Option<String>>()
                case "createdAt" => createdAt = r.readValue<Int64>()
                case _ => r.skip()
            }
        }
        r.endObject()
        TypeMeta(name, description, schema, levels, retention, createdAt)
    }
}

// 记忆类型注册表：管理 <type> 与 <type>.summary 两个 series 的注册 + __meta 持久化。
// 类型名白名单校验（防路径穿越，同 liveboard）、粒度链校验（§5.1）。
public class MemoryTypeRegistry {
    private let store: TimelineStore
    private let types = HashMap<String, TypeMeta>()

    public static let META_SERIES = "meta"

    public init(store: TimelineStore) {
        this.store = store
        this.load()
    }

    // 从 __meta series 恢复类型注册表（重启恢复；同名后写覆盖先写）
    private func load(): Unit {
        let points = this.store.rawTsdb().query(MemoryTypeRegistry.META_SERIES).find()
        for (p in points) {
            let meta = fromJsonString<TypeMeta>(p.payload)
            this.types[meta.name] = meta
        }
    }

    // 创建记忆类型：校验 → 注册两个 series → 持久化 __meta。
    public func create(meta: TypeMeta): Unit {
        MemoryTypeRegistry.validateTypeName(meta.name)
        Timeline.validateLevels(meta.levels)
        if (this.types.contains(meta.name)) {
            throw Exception("类型已存在: " + meta.name)
        }
        // 注册 series（主 series + summary series，同 levels）
        this.store.timeline(meta.name, "记忆类型 " + meta.name, meta.levels)
        this.store.timeline(MemoryTypeRegistry.summarySeriesOf(meta.name), "总结 " + meta.name, meta.levels)
        // 持久化 meta（tag=name 定位）
        let tags = HashMap<String, String>()
        tags["name"] = meta.name
        this.store.rawTsdb().append(MemoryTypeRegistry.META_SERIES, meta.createdAt,
            toJsonString(meta), tags)
        this.types[meta.name] = meta
    }

    public func get(name: String): Option<TypeMeta> { this.types.get(name) }
    public func has(name: String): Bool { this.types.contains(name) }

    public func list(): ArrayList<TypeMeta> {
        let l = ArrayList<TypeMeta>()
        for ((_, m) in this.types) { l.add(m) }
        l
    }

    // 某类型主 series 句柄
    public func timelineOf(name: String): Option<Timeline> {
        match (this.types.get(name)) {
            case Some(m) => Some(this.store.timeline(name, "记忆类型 " + name, m.levels))
            case None => None
        }
    }

    // 某类型语义总结 series 句柄
    public func summaryTimelineOf(name: String): Option<Timeline> {
        match (this.types.get(name)) {
            case Some(m) =>
                Some(this.store.timeline(MemoryTypeRegistry.summarySeriesOf(name), "总结 " + name, m.levels))
            case None => None
        }
    }

    // 某类型原始条目数
    public func countEntries(name: String): Int64 {
        this.store.rawTsdb().query(name).count()
    }

    public static func summarySeriesOf(name: String): String {
        name + ".summary"
    }

    // 类型名白名单：[A-Za-z0-9_/-]；拒绝空名、绝对路径、`..`（防路径穿越，同 liveboard）；
    // 预留 `meta`（注册表 series）与 `__` 前缀（tsdb 保留前缀，见 tsdb.cj）。
    public static func validateTypeName(name: String): Unit {
        if (name == "") {
            throw Exception("类型名不能为空")
        }
        if (name == MemoryTypeRegistry.META_SERIES) {
            throw Exception("类型名保留: " + name)
        }
        if (name.startsWith("__")) {
            throw Exception("类型名不能以 __ 开头（tsdb 保留前缀）")
        }
        if (name.indexOf("..") != None) {
            throw Exception("类型名不能包含 ..")
        }
        if (name.startsWith("/")) {
            throw Exception("类型名不能是绝对路径")
        }
        for (c in name.toRuneArray()) {
            let v = UInt32(c)
            let ok = (v >= UInt32(97) && v <= UInt32(122)) ||   // a-z
                (v >= UInt32(65) && v <= UInt32(90)) ||         // A-Z
                (v >= UInt32(48) && v <= UInt32(57)) ||         // 0-9
                v == UInt32(95) || v == UInt32(45) || v == UInt32(47)   // _ - /
            if (!ok) {
                throw Exception("非法类型名字符: " + c.toString())
            }
        }
    }
}

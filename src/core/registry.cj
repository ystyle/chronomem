package chronomem.core

import tsdb.*
import std.collection.*
import std.sync.Mutex
import stdx.encoding.json.stream.*

// 记忆类型元数据（固定结构，json.stream 序列化；schema/retention/summaryLevels/summaryGroupBy 可空）。
// 落库于 tsdb `meta` series（tag=name 定位），重启时重建注册表。
public struct TypeMeta <: JsonSerializable & JsonDeserializable<TypeMeta> {
    public let name: String                 // 类型名（白名单 [A-Za-z0-9_/-]，如 worklog、proj/decisions）
    public let description: String
    public let schema: Option<String>       // 可选字段描述（JSON 字符串；宽松模式，仅作文档/LLM 提示）
    public let levels: ArrayList<String>    // 粒度链（§5.1）
    public let retention: Option<String>    // 可选保留期（如 "30d"，后续接入 tsdb setRetention）
    public let autoSummarize: Bool          // 后台自动语义总结（默认 false，opt-in；§7.3）
    public let summaryLevels: Option<ArrayList<String>>  // 自动总结粒度（缺省 = 最粗 2 档）
    public let summaryGroupBy: Option<ArrayList<String>> // 总结分组维度（tag 键列表，如 ["proj"]，上限 2 个；None=不分）
    public let createdAt: Int64

    public init(name: String, description: String, schema: Option<String>,
        levels: ArrayList<String>, retention: Option<String>,
        autoSummarize: Bool, summaryLevels: Option<ArrayList<String>>, createdAt: Int64,
        summaryGroupBy!: Option<ArrayList<String>> = None) {
        this.name = name
        this.description = description
        this.schema = schema
        this.levels = levels
        this.retention = retention
        this.autoSummarize = autoSummarize
        this.summaryLevels = summaryLevels
        this.summaryGroupBy = summaryGroupBy
        this.createdAt = createdAt
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("name").writeValue(this.name)
        w.writeName("description").writeValue(this.description)
        w.writeName("schema").writeValue(this.schema)
        w.writeName("levels").writeValue(this.levels)
        w.writeName("retention").writeValue(this.retention)
        w.writeName("autoSummarize").writeValue(this.autoSummarize)
        w.writeName("summaryLevels").writeValue(this.summaryLevels)
        w.writeName("summaryGroupBy").writeValue(this.summaryGroupBy)
        w.writeName("createdAt").writeValue(this.createdAt)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): TypeMeta {
        var name = ""
        var description = ""
        var schema: Option<String> = None
        var levels = ArrayList<String>()
        var retention: Option<String> = None
        var autoSummarize = false
        var summaryLevels: Option<ArrayList<String>> = None
        var summaryGroupBy: Option<ArrayList<String>> = None
        var createdAt = Int64(0)
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "name" => name = r.readValue<String>()
                case "description" => description = r.readValue<String>()
                case "schema" => schema = r.readValue<Option<String>>()
                case "levels" => levels = r.readValue<ArrayList<String>>()
                case "retention" => retention = r.readValue<Option<String>>()
                case "autoSummarize" => autoSummarize = r.readValue<Bool>()
                case "summaryLevels" => summaryLevels = r.readValue<Option<ArrayList<String>>>()
                case "summaryGroupBy" => summaryGroupBy = r.readValue<Option<ArrayList<String>>>()
                case "createdAt" => createdAt = r.readValue<Int64>()
                case _ => r.skip()
            }
        }
        r.endObject()
        TypeMeta(name, description, schema, levels, retention, autoSummarize, summaryLevels, createdAt, summaryGroupBy: summaryGroupBy)
    }
}

// 记忆类型注册表：管理 <type> 与 <type>.summary 两个 series 的注册 + __meta 持久化。
// 类型名白名单校验（防路径穿越，同 liveboard）、粒度链校验（§5.1）。
public class MemoryTypeRegistry {
    private let store: TimelineStore
    private let types = HashMap<String, TypeMeta>()
    // 并发保护：后台总结执行器（SummarizeJobRunner）与 MCP 接收循环、cron 物化线程
    // 可能同时读写 types；tsdb 自身并发安全，此锁只保护注册表内存态。
    private let lock = Mutex()

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

    // 创建记忆类型：校验 → 注册两个 series → 持久化 meta。
    public func create(meta: TypeMeta): Unit {
        MemoryTypeRegistry.validateTypeName(meta.name)
        Timeline.validateLevels(meta.levels)
        MemoryTypeRegistry.validateSummaryLevels(meta)
        MemoryTypeRegistry.validateSummaryGroupBy(meta)
        synchronized(this.lock) {
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
    }

    public func get(name: String): Option<TypeMeta> {
        synchronized(this.lock) { this.types.get(name) }
    }
    public func has(name: String): Bool {
        synchronized(this.lock) { this.types.contains(name) }
    }

    // 更新已有类型的 meta（字段升级，如补 summaryGroupBy）。
    // 校验类型存在 + 校验粒度/总结配置；持久化新 meta（meta series 同名后写覆盖先写，重启恢复取最新）。
    public func updateMeta(meta: TypeMeta): Unit {
        synchronized(this.lock) {
            if (!this.types.contains(meta.name)) {
                throw Exception("类型不存在: " + meta.name)
            }
            MemoryTypeRegistry.validateSummaryLevels(meta)
            MemoryTypeRegistry.validateSummaryGroupBy(meta)
            // 持久化新 meta（同名后写覆盖先写，load 时取最新）
            let tags = HashMap<String, String>()
            tags["name"] = meta.name
            this.store.rawTsdb().append(MemoryTypeRegistry.META_SERIES, nowMs(),
                toJsonString(meta), tags)
            this.types[meta.name] = meta
        }
    }

    public func list(): ArrayList<TypeMeta> {
        synchronized(this.lock) {
            let l = ArrayList<TypeMeta>()
            for ((_, m) in this.types) { l.add(m) }
            l
        }
    }

    // 某类型主 series 句柄
    public func timelineOf(name: String): Option<Timeline> {
        synchronized(this.lock) {
            match (this.types.get(name)) {
                case Some(m) => Some(this.store.timeline(name, "记忆类型 " + name, m.levels))
                case None => None
            }
        }
    }

    // 某类型语义总结 series 句柄
    public func summaryTimelineOf(name: String): Option<Timeline> {
        synchronized(this.lock) {
            match (this.types.get(name)) {
                case Some(m) =>
                    Some(this.store.timeline(MemoryTypeRegistry.summarySeriesOf(name), "总结 " + name, m.levels))
                case None => None
            }
        }
    }

    // 某类型原始条目数
    public func countEntries(name: String): Int64 {
        this.store.rawTsdb().query(name).count()
    }

    // 某类型总结记录数
    public func countSummaries(name: String): Int64 {
        this.store.rawTsdb().query(MemoryTypeRegistry.summarySeriesOf(name)).count()
    }

    // TRUNCATE：清空类型全部条目（原始 + 总结），保留类型。返回删除的原始条目数。
    public func truncate(name: String): Int64 {
        synchronized(this.lock) {
            if (!this.types.contains(name)) {
                throw Exception("类型不存在: " + name)
            }
            let raw = this.timelineOf(name).getOrThrow().clearAll()
            this.summaryTimelineOf(name).getOrThrow().clearAll()
            raw
        }
    }

    // DROP：删除类型。**守卫：原始与总结序列必须都为空**（防误删），否则抛异常。
    // 删除两个 series + meta 记录 + 注册表条目。
    public func drop(name: String): Unit {
        synchronized(this.lock) {
            if (!this.types.contains(name)) {
                throw Exception("类型不存在: " + name)
            }
            let rawCount = this.countEntries(name)
            let sumCount = this.countSummaries(name)
            if (rawCount > 0 || sumCount > 0) {
                throw Exception("类型 " + name + " 非空（条目 " + rawCount.toString() +
                    "，总结 " + sumCount.toString() + "），先 mem/truncate 清空再删")
            }
            this.timelineOf(name).getOrThrow().deleteAll()
            this.summaryTimelineOf(name).getOrThrow().deleteAll()
            this.store.rawTsdb().deletePointsByTag(MemoryTypeRegistry.META_SERIES, "name", name)
            this.types.remove(name)
        }
    }

    // 校验 summaryLevels：须是类型 levels 的子集（升序无重复由类型自身保证）
    public static func validateSummaryLevels(meta: TypeMeta): Unit {
        match (meta.summaryLevels) {
            case Some(ls) =>
                if (ls.size == 0) {
                    throw Exception("summary_levels 不能为空（不设则用缺省最粗 2 档）")
                }
                for (l in ls) {
                    if (!meta.levels.contains(l)) {
                        throw Exception("summary_levels 里的 " + l + " 不在类型 levels 内: " + Timeline.coarsestLevels(meta.levels, meta.levels.size).toString())
                    }
                }
            case None => ()
        }
    }

    // 校验 summaryGroupBy：总结分组维度（tag 键列表）。
    // 约束：最多 2 个维度；每个必须是合法 tag 键名（非空、无非法字符，见 validateTagKey）。
    public static func validateSummaryGroupBy(meta: TypeMeta): Unit {
        match (meta.summaryGroupBy) {
            case Some(keys) =>
                if (keys.size == 0) {
                    throw Exception("summary_group_by 不能为空数组（不设则按整窗总结）")
                }
                if (keys.size > 2) {
                    throw Exception("summary_group_by 维度上限 2 个（当前 " + keys.size.toString() + " 个）：" + keys.toString())
                }
                for (k in keys) {
                    MemoryTypeRegistry.validateTagKey(k)
                }
                // 去重（同键重复无意义）
                let seen = HashSet<String>()
                for (k in keys) {
                    if (seen.contains(k)) {
                        throw Exception("summary_group_by 重复维度: " + k)
                    }
                    seen.add(k)
                }
            case None => ()
        }
    }

    // 分组维度 tag 键名校验：非空、不含空白/等号/逗号/花括号（会被 tags JSON / tag=value 语法混淆）
    public static func validateTagKey(k: String): Unit {
        if (k == "") {
            throw Exception("分组维度 tag 键名不能为空")
        }
        for (c in k.runes()) {
            let v = UInt32(c)
            let ok = (v >= UInt32(97) && v <= UInt32(122)) ||   // a-z
                (v >= UInt32(65) && v <= UInt32(90)) ||         // A-Z
                (v >= UInt32(48) && v <= UInt32(57)) ||         // 0-9
                v == UInt32(95) || v == UInt32(45) || v == UInt32(46) || v == UInt32(47)   // _ - . /
            if (!ok) {
                throw Exception("非法分组维度 tag 键: " + k + "（仅允许字母/数字/_-./）")
            }
        }
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

// 忆时塔 Web UI 数据访问层：直接使用 MemoryService（同进程，无 HTTP/MCP 开销）。
// 只做「读 + 委托写」，不包含任何渲染逻辑；固定结构用 json.stream（经 chronomem.core 工具函数）。
package chronomem.ui

import chronomem.core.*
import chronomem.mcp.MemoryService
import tsdb.{Point, BucketMeta, BucketRecord}
import jsonvalue.*
import std.collection.*
import std.sort.*
import std.time.TimeZone

public struct UiResult {
    public let ok: Bool
    public let message: String

    public init(ok: Bool, message: String) {
        this.ok = ok
        this.message = message
    }

    public static func success(m: String): UiResult { UiResult(true, m) }
    public static func error(m: String): UiResult { UiResult(false, m) }
}

// 总结记录（UI 形态；与 SummaryRecord 平铺为简单结构）
public struct UiSummaryItem {
    public let ts: Int64
    public let windowFrom: Int64
    public let windowTo: Int64
    public let model: String
    public let text: String
    public let groupKey: Option<String>

    public init(ts: Int64, windowFrom: Int64, windowTo: Int64, model: String,
        text: String, groupKey: Option<String>) {
        this.ts = ts
        this.windowFrom = windowFrom
        this.windowTo = windowTo
        this.model = model
        this.text = text
        this.groupKey = groupKey
    }
}

public struct UiTypeInfo {
    public let meta: TypeMeta
    public let entries: Int64
    public let summaries: Int64
    public let bucketCounts: ArrayList<(String, Int64)>

    public init(meta: TypeMeta, entries: Int64, summaries: Int64, bucketCounts: ArrayList<(String, Int64)>) {
        this.meta = meta
        this.entries = entries
        this.summaries = summaries
        this.bucketCounts = bucketCounts
    }
}

// ---------- 类型 ----------

public func uiListTypes(svc: MemoryService): ArrayList<TypeMeta> {
    let out = ArrayList<TypeMeta>()
    for (m in svc.registry.list()) { out.add(m) }
    sort(out, by: { a, b => a.createdAt.compare(b.createdAt) })
    out
}

public func uiGetType(svc: MemoryService, name: String): Option<TypeMeta> {
    svc.registry.get(name)
}

public func uiTypeInfo(svc: MemoryService, name: String): Option<UiTypeInfo> {
    match (svc.registry.get(name)) {
        case Some(meta) =>
            let counts = ArrayList<(String, Int64)>()
            for (level in meta.levels) {
                match (svc.registry.timelineOf(name)) {
                    case Some(tl) => counts.add((level, Int64(tl.listBuckets(level, None, None).size)))
                    case None => counts.add((level, 0))
                }
            }
            Some(UiTypeInfo(meta, svc.registry.countEntries(name), svc.registry.countSummaries(name), counts))
        case None => None
    }
}

// ---------- 条目 ----------

// queryPoints 直接返回（带存在性校验）；类型不存在返回空列表（页面按空数据渲染）
public func uiQuery(svc: MemoryService, name: String, from: Int64, to: Int64,
    limit: Int64, tagKey: String, tagValue: String): ArrayList<Point> {
    if (svc.registry.timelineOf(name).isNone()) { return ArrayList<Point>() }
    // UI 目前只提供单 tag 输入，构造成单条件列表（多条件语法留给 MCP 层）
    let tagFilters = ArrayList<TagFilter>()
    if (tagKey != "" && tagValue != "") {
        tagFilters.add(TagFilter(tagKey, ArrayList<String>([tagValue])))
    }
    let fromArg = if (from > 0) { from } else { 0 }
    let toArg = if (to > 0) { to } else { 0 }
    svc.registry.timelineOf(name).getOrThrow().queryPoints(fromArg, toArg, limit, tagFilters)
}

public func uiCount(svc: MemoryService, name: String): Int64 {
    svc.registry.countEntries(name)
}

public func uiListBuckets(svc: MemoryService, name: String, granularity: String): ArrayList<BucketRecord> {
    if (svc.registry.timelineOf(name).isNone()) { return ArrayList<BucketRecord>() }
    svc.registry.timelineOf(name).getOrThrow().listBuckets(granularity, None, None)
}

// 轻量桶列表（只带 refs 条数，不构造 refs 对象数组——塔层/桶卡片/摘要窗口统计用）
public func uiListBucketMetas(svc: MemoryService, name: String, granularity: String): ArrayList<BucketMeta> {
    if (svc.registry.timelineOf(name).isNone()) { return ArrayList<BucketMeta>() }
    svc.registry.timelineOf(name).getOrThrow().listBucketMetas(granularity, None, None)
}

public func uiDrillDown(svc: MemoryService, name: String, granularity: String, bucketKey: String): ArrayList<Point> {
    if (svc.registry.timelineOf(name).isNone()) { return ArrayList<Point>() }
    svc.registry.timelineOf(name).getOrThrow().drillDown(granularity, bucketKey)
}

// ---------- 总结 ----------

// 最新在前
public func uiSummaries(svc: MemoryService, name: String, limit: Int64): ArrayList<UiSummaryItem> {
    let out = ArrayList<UiSummaryItem>()
    match (svc.registry.summaryTimelineOf(name)) {
        case Some(tl) =>
            let points = tl.queryPoints(0, 0, limit, ArrayList<TagFilter>())
            for (p in points) {
                let rec = try {
                    fromJsonString<SummaryRecord>(p.payload)
                } catch (_) {
                    // 旧格式/损坏：跳过（summaries 只展示可解析的）
                    continue
                }
                out.add(UiSummaryItem(rec.ts, rec.windowFrom, rec.windowTo, rec.model, rec.text, rec.groupKey))
            }
            sort(out, by: { a, b => b.ts.compare(a.ts) })
        case None => ()
    }
    out
}

// 覆盖 [winFrom, winTo] 窗口的总结条目（语义回顾：按窗口查询）
public func uiSummariesOfWindow(svc: MemoryService, name: String, winFrom: Int64, winTo: Int64): ArrayList<UiSummaryItem> {
    let all = uiSummaries(svc, name, 200)
    let out = ArrayList<UiSummaryItem>()
    for (s in all) {
        // 覆盖：总结窗口完全落在查询窗口内
        if (s.windowFrom >= winFrom && s.windowTo <= winTo) { out.add(s) }
    }
    out
}

public func uiLlmLive(svc: MemoryService): Bool {
    match (svc.summarizer) {
        case Some(_) => true
        case None => false
    }
}

public func uiLlmModel(svc: MemoryService): String {
    match (svc.summarizer) {
        case Some(z) => z.modelName()
        case None => ""
    }
}

// ---------- 写操作 ----------

public func uiAppend(svc: MemoryService, name: String, ts: Int64, payloadJson: String, tags: ArrayList<(String, String)>): UiResult {
    if (svc.registry.timelineOf(name).isNone()) {
        return UiResult.error("类型不存在：${name}，请先创建")
    }
    // payload 必须是合法 JSON 对象（宽松模式仅接受 object，避免裸 token 被宽容解析）
    let parsed = try {
        JsonValue.parse(payloadJson)
    } catch (_) {
        JsonValue.Null
    }
    let okJson = match (parsed) {
        case JsonValue.Map(_) => true
        case _ => false
    }
    if (!okJson) {
        return UiResult.error("payload 不是合法 JSON")
    }
    let tagMap = HashMap<String, String>()
    for ((k, v) in tags) {
        if (k != "") { tagMap.add(k, v) }
    }
    let tsArg = if (ts > 0) { ts } else { nowMs() }
    svc.registry.timelineOf(name).getOrThrow().append(tsArg, payloadJson, tagMap)
    UiResult.success("已追加条目（ts=${tsArg.toString()}）")
}

func buildTagsJson(tags: ArrayList<(String, String)>): String {
    let sb = StringBuilder()
    sb.append("{")
    var first = true
    for ((k, v) in tags) {
        if (k == "") { continue }
        if (!first) { sb.append(",") }
        sb.append("\"")
        sb.append(k)
        sb.append("\":\"")
        sb.append(v)
        sb.append("\"")
        first = false
    }
    sb.append("}")
    sb.toString()
}

// 触发后台总结（window 为空默认 0/0，由 SummarizeJobRunner 处理）
public func uiTriggerSummarize(svc: MemoryService, name: String, winFrom: Int64, winTo: Int64,
    instructions: String): UiResult {
    if (svc.registry.timelineOf(name).isNone()) {
        return UiResult.error("类型不存在：${name}")
    }
    match (svc.summarizer) {
        case None => return UiResult.error("未配置 LLM（LLM_BASE_URL / LLM_API_KEY / LLM_MODEL）")
        case Some(_) => ()
    }
    match (svc.summarizeRunner) {
        case Some(runner) =>
            let jobId = runner.submit(name, winFrom, winTo, instructions, true)
            UiResult.success("总结任务已提交（job_id=${jobId.toString()}，后台异步执行）")
        case None => UiResult.error("总结执行器未运行")
    }
}

public func uiSummarizeStatus(svc: MemoryService, jobId: Int64): String {
    match (svc.summarizeRunner) {
        case Some(runner) => runner.status(jobId)
        case None => "unknown"
    }
}

public func uiTruncate(svc: MemoryService, name: String): UiResult {
    if (svc.registry.timelineOf(name).isNone()) {
        return UiResult.error("类型不存在：${name}")
    }
    let n = svc.registry.truncate(name)
    UiResult.success("已清空（TRUNCATE）：删除 ${n.toString()} 条，类型保留")
}

public func uiDeleteType(svc: MemoryService, name: String): UiResult {
    if (svc.registry.timelineOf(name).isNone()) {
        return UiResult.error("类型不存在：${name}")
    }
    let entries = svc.registry.countEntries(name)
    let summaries = svc.registry.countSummaries(name)
    if (entries + summaries > 0) {
        return UiResult.error("守卫：原始 ${entries.toString()} 条 + 总结 ${summaries.toString()} 条未清空，DROP 被拒绝；请先清空")
    }
    svc.registry.drop(name)
    UiResult.success("类型已删除：${name}")
}

public func uiCreateType(svc: MemoryService, meta: TypeMeta): UiResult {
    // 名称白名单（与 core 同约定）
    if (!isValidTypeName(meta.name)) {
        return UiResult.error("非法类型名：${meta.name}（白名单 [A-Za-z0-9_/-]，禁 .. 与绝对路径）")
    }
    if (svc.registry.has(meta.name)) {
        return UiResult.error("类型已存在：${meta.name}")
    }
    svc.registry.create(meta)
    UiResult.success("类型已创建：${meta.name}")
}

public func isValidTypeName(name: String): Bool {
    if (name == "" || name.size > 128) { return false }
    if (name.contains("..") || name.startsWith("/")) { return false }
    for (i in 0..name.size) {
        let c = name[i]
        let ok = (c >= 48u8 && c <= 57u8) || (c >= 65u8 && c <= 90u8) || (c >= 97u8 && c <= 122u8)
            || c == 95u8 || c == 47u8 || c == 45u8
        if (!ok) { return false }
    }
    true
}

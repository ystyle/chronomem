package chronomem.mcp

import chronomem.core.*
import jsonvalue.*
import mcp.*
import std.collection.*
import std.time.*
import tsdb.*

// ---------- 参数解析 / 结果辅助 ----------

// 单条 append payload 上限（字节，序列化后 utf8 计）。忆时塔为日志型存储（实测
// 单条 <50KB），256KB 上限是生产 OOM 防线（fix/append-size-limit）：950KB 级病态
// 输入在默认 256MB GC 堆下瞬时分配 ~200MB 顶爆堆 → OOM → 请求悬挂。上限需远小于
// badger 1MB 内联阈值（限长后所有条目走 memtable 内联，行为一致）。
public let MAX_APPEND_PAYLOAD_BYTES = Int64(256 * 1024)

func argStr(args: HashMap<String, JsonValue>, name: String): String {
    match (args.get(name)) {
        case Some(JsonValue.String(s)) => s
        case _ => ""
    }
}

func argInt(args: HashMap<String, JsonValue>, name: String): Int64 {
    match (args.get(name)) {
        case Some(JsonValue.Number(n)) => Int64(n)
        case _ => 0
    }
}

func argBool(args: HashMap<String, JsonValue>, name: String, def: Bool): Bool {
    match (args.get(name)) {
        case Some(JsonValue.Boolean(b)) => b
        case _ => def
    }
}

func argLevels(args: HashMap<String, JsonValue>, name: String, def: ArrayList<String>): ArrayList<String> {
    match (args.get(name)) {
        case Some(JsonValue.Array(arr)) =>
            let l = ArrayList<String>()
            for (v in arr) {
                match (v) {
                    case JsonValue.String(s) => l.add(s)
                    case _ => ()
                }
            }
            if (l.size > 0) { l } else { def }
        case _ => def
    }
}

// 可选字符串参数：缺省 / null / 空串 → None（用于"清空该字段"），否则 Some(值)。
// 与 argStr 的区别：argStr 无法区分"未传"和"传了空串"，而 type_update 需要这个区分。
func argOptStr(args: HashMap<String, JsonValue>, name: String): Option<String> {
    match (args.get(name)) {
        case Some(JsonValue.String(s)) => if (s == "") { None } else { Some(s) }
        case _ => None
    }
}

// 可选字符串数组参数：缺省 / null / 空数组 → None（清空），否则 Some(列表)。
// 与 argLevels 同理：空数组表达"清空"而非"用缺省"。
func argOptList(args: HashMap<String, JsonValue>, name: String): Option<ArrayList<String>> {
    match (args.get(name)) {
        case Some(JsonValue.Array(arr)) =>
            let l = ArrayList<String>()
            for (v in arr) {
                match (v) {
                    case JsonValue.String(s) => l.add(s)
                    case _ => ()
                }
            }
            if (l.size > 0) { Some(l) } else { None }
        case _ => None
    }
}

// 两个字符串列表内容相同（长度 + 逐元素）。仓颉 ArrayList 的 == 依赖 T 的 Equatable，
// 这里显式比较，避免依赖隐式约束。
func sameStringList(a: ArrayList<String>, b: ArrayList<String>): Bool {
    if (a.size != b.size) { return false }
    for (i in 0..a.size) {
        if (a[i] != b[i]) { return false }
    }
    true
}

// 两个可选字符串列表相等（含 None 与非 None 混合）。
func sameOptList(a: Option<ArrayList<String>>, b: Option<ArrayList<String>>): Bool {
    match (a) {
        case None =>
            match (b) {
                case None => true
                case Some(_) => false
            }
        case Some(x) =>
            match (b) {
                case None => false
                case Some(y) => sameStringList(x, y)
            }
    }
}

func argTags(args: HashMap<String, JsonValue>, name: String): HashMap<String, String> {
    let out = HashMap<String, String>()
    match (args.get(name)) {
        case Some(JsonValue.Map(m)) =>
            for ((k, v) in m) {
                match (v) {
                    case JsonValue.String(s) => out[k] = s
                    case _ => ()
                }
            }
        case _ => ()
    }
    out
}

// tag 参数：接受 "key=value" 字符串（返回 (key, value)）
func argTagPair(args: HashMap<String, JsonValue>, name: String): Option<(String, String)> {
    let s = argStr(args, name)
    if (s == "") { return None }
    match (s.indexOf("=")) {
        case Some(i) => Some((s[0..i], s[i + 1..]))
        case None => Some((s, ""))
    }
}

func toolError(msg: String): CallToolResult {
    let r = CallToolResult.text(msg)
    r.isError = true
    r
}

func levelsString(levels: ArrayList<String>): String {
    let sb = StringBuilder()
    var first = true
    for (l in levels) {
        if (!first) { sb.append(" → ") }
        sb.append(l)
        first = false
    }
    sb.toString()
}

// 时间戳格式化（按自然窗口时区，而非进程本地——容器内进程本地是 UTC）
func fmtTs(ts: Int64, tz: TimeZone): String {
    DateTime.ofEpoch(second: ts / 1000, nanosecond: (ts % 1000) * 1000000)
        .inTimeZone(tz).format("MM-dd HH:mm:ss")
}

func pointTags(p: Point): String {
    if (p.tags == "{}" || p.tags == "") { return "" }
    let sb = StringBuilder()
    try {
        let v = JsonValue.parse(p.tags)
        match (v) {
            case JsonValue.Map(m) =>
                var first = true
                for ((k, tv) in m) {
                    if (!first) { sb.append(",") }
                    // 字符串值取 asString（toString 是 JsonValue 内部表示）；其它值 stringify
                    let vs = match (tv) {
                        case JsonValue.String(s) => s
                        case _ => tv.stringify()
                    }
                    sb.append(k + "=" + vs)
                    first = false
                }
            case _ => ()
        }
    } catch (_) {}
    if (sb.toString() == "") { "" } else { " <" + sb.toString() + ">" }
}

func formatPoint(p: Point, tz: TimeZone): String {
    "[" + fmtTs(p.ts, tz) + "] " + p.payload + pointTags(p)
}

func formatPoints(points: ArrayList<Point>, tz: TimeZone): String {
    let sb = StringBuilder()
    for (p in points) {
        sb.append(formatPoint(p, tz))
        sb.append("\n")
    }
    sb.toString()
}

// 类型必须存在；不存在返回 toolError
func requireType(svc: MemoryService, name: String): Option<CallToolResult> {
    if (name == "") { return Some(toolError("缺少参数 type")) }
    if (!svc.registry.has(name)) { return Some(toolError("类型不存在: " + name + "（先 mem/type_create）")) }
    None
}

// 校验粒度在该类型的 levels 内；不在返回 toolError
func requireGranularity(svc: MemoryService, name: String, granularity: String): Option<CallToolResult> {
    if (granularity == "") { return Some(toolError("缺少参数 granularity（10min/30min/1h/3h/day/week/month）")) }
    let meta = svc.registry.get(name)
    match (meta) {
        case Some(m) => if (!m.levels.contains(granularity)) {
            return Some(toolError("粒度 " + granularity + " 不在类型 " + name + " 的 levels 内: " + levelsString(m.levels)))
        }
        case None => ()
    }
    None
}

// ---------- 语义总结核心（mem/summarize 与 recall mode=summary 共用） ----------

// 未分组（条目无任何分组维度 tag）的 groupKey 值
public let UNGROUPED_GROUP = "\u{0000}未分组"

// 从 Point 的 tags JSON 解析出指定 tag 的值（无则 None）
func tagValueOf(p: Point, tag: String): Option<String> {
    for ((k, v) in tagsPairs(p.tags)) {
        if (k == tag) { return Some(v) }
    }
    None
}

// 按类型分组维度计算一条记录的 groupKey：
// - 维度为空（类型未配 summaryGroupBy）→ None（整窗总结）
// - 维度非空 → Some(各维度 tag 值以 \u0001 连接)；任一条目缺任一维度 tag → 归 UNGROUPED_GROUP
func groupKeyOf(meta: TypeMeta, p: Point): Option<String> {
    match (meta.summaryGroupBy) {
        case None => None
        case Some(dims) =>
            let sb = StringBuilder()
            var missing = false
            for (d in dims) {
                match (tagValueOf(p, d)) {
                    case Some(v) =>
                        if (sb.toString() != "") { sb.append("\u{0001}") }
                        sb.append(v)
                    case None => missing = true
                }
            }
            if (missing) { Some(UNGROUPED_GROUP) } else if (sb.toString() == "") {
                // 空维度数组已被校验拦截，不会走到；兜底
                Some(UNGROUPED_GROUP)
            } else {
                Some(sb.toString())
            }
    }
}

// groupKey 的展示名：None → "整窗"；未分组 → "未分组"；否则原值
func groupLabel(key: Option<String>): String {
    match (key) {
        case None => "整窗"
        case Some(v) => if (v == UNGROUPED_GROUP) { "未分组" } else { v }
    }
}

// 分批流式入桶累积器（lambda 不能捕获可变局部变量，捕获本对象引用改内部字段）：
// 窗口点按组分桶为 EntryText（边读边拼），total 计数；每批 Point 即弃。
class SummaryBucketAccumulator {
    public let buckets = HashMap<Option<String>, ArrayList<EntryText>>()
    public var total: Int64 = 0
    private let meta: TypeMeta

    public init(meta: TypeMeta) {
        this.meta = meta
    }

    public func absorb(points: ArrayList<Point>): Unit {
        for (p in points) {
            this.total += 1
            let key = groupKeyOf(this.meta, p)
            let entry = EntryText(p.ts, p.payload)
            match (this.buckets.get(key)) {
                case Some(list) => list.add(entry)
                case None =>
                    let list = ArrayList<EntryText>()
                    list.add(entry)
                    this.buckets[key] = list
            }
        }
    }
}

// 对 [winFrom, winTo] 窗口做语义总结；store=true 时落 <type>.summary，返回结果文本。
// 类型配置了 summaryGroupBy 时按维度分桶，每桶独立总结（各自落一条 SummaryRecord）。
// recompute=true 时忽略已有总结强制重算（否则已有同窗口同分组总结时跳过该分组）。
func doSummarize(svc: MemoryService, name: String, winFrom: Int64, winTo: Int64,
    instructions: String, store: Bool, recompute!: Bool = false): CallToolResult {
    match (svc.summarizer) {
        case None => return toolError("未配置 LLM（LLM_BASE_URL / LLM_API_KEY / LLM_MODEL）")
        case Some(_) => ()
    }
    let tl = svc.registry.timelineOf(name).getOrThrow()
    let meta = svc.registry.get(name).getOrThrow()
    // 分批流式读窗口（keyset 翻页，每批 ≤200）：边读边按组累积 EntryText，
    // 点对象每批即弃——避免整窗 ArrayList<Point> 驻留（大窗口+大 payload
    // 时内存峰值从 O(窗口字节) 降到 O(单批字节+最终文本)）。
    let acc = SummaryBucketAccumulator(meta)
    tl.forEachWindowPoint(winFrom, winTo, 200, { points => acc.absorb(points) })
    if (acc.total == 0) {
        return CallToolResult.text("该窗口无条目，无需总结")
    }
    let sb = StringBuilder()
    var anyStored = false
    var anyGenerated = false
    for ((groupKey, entries) in acc.buckets) {
        // 幂等：已有覆盖该窗口的同分组总结则跳过（除非 recompute）
        if (!recompute) {
            if (latestOverlappingSummary(svc, name, winFrom, winTo, groupKey).isSome()) {
                sb.append("【" + groupLabel(groupKey) + "】已有总结，跳过（recompute=true 可强制重算）\n")
                continue
            }
        }
        let rec = svc.summarizer.getOrThrow().summarize(winFrom, winTo, entries, instructions, groupKey: groupKey)
        if (store) {
            let stl = svc.registry.summaryTimelineOf(name).getOrThrow()
            stl.append(rec.ts, toJsonString(rec), HashMap<String, String>())
            anyStored = true
        }
        anyGenerated = true
        let head = "【" + groupLabel(groupKey) + "】@" + fmtTs(rec.ts, svc.store.timeZoneOf()) + "\n"
        sb.append(head + rec.text + "\n\n")
    }
    if (!anyGenerated) {
        return CallToolResult.text("该窗口各分组均已有总结，无需重复（recompute=true 可强制重算）")
    }
    let tail = if (store && anyStored) { "\n（已落库 <type>.summary；可用 mem/summaries 查看）" } else { "" }
    CallToolResult.text(sb.toString() + tail)
}

// 找覆盖 [winFrom, winTo] 的最新一条 SummaryRecord；
// groupKey 可选过滤（None = 整窗/无分组总结；Some(UNGROUPED_GROUP) = 未分组）
func latestOverlappingSummary(svc: MemoryService, name: String, winFrom: Int64, winTo: Int64,
    groupKey: Option<String>): Option<SummaryRecord> {
    let stl = svc.registry.summaryTimelineOf(name).getOrThrow()
    let points = stl.queryPoints(0, 0, 50, None)
    for (p in points) {
        let rec = fromJsonString<SummaryRecord>(p.payload)
        if (rec.windowFrom <= winTo && rec.windowTo >= winFrom && rec.groupKey == groupKey) {
            return Some(rec)
        }
    }
    None
}

// 收集覆盖 [winFrom, winTo] 的总结（最新在前）。groupFilter 可选：
// 空 = 全部；否则仅匹配该分组值（"未分组" → UNGROUPED_GROUP）
func overlappingSummaries(svc: MemoryService, name: String, winFrom: Int64, winTo: Int64,
    groupFilter: String): ArrayList<SummaryRecord> {
    let out = ArrayList<SummaryRecord>()
    let stl = svc.registry.summaryTimelineOf(name).getOrThrow()
    let points = stl.queryPoints(0, 0, 50, None)
    for (p in points) {
        let rec = fromJsonString<SummaryRecord>(p.payload)
        if (rec.windowFrom <= winTo && rec.windowTo >= winFrom) {
            if (groupFilter != "") {
                let want = if (groupFilter == "未分组") { Some(UNGROUPED_GROUP) } else { Some(groupFilter) }
                if (rec.groupKey != want) { continue }
            }
            out.add(rec)
        }
    }
    out
}

// CallToolResult → 纯文本（拼 Text 块）
func resultText(r: CallToolResult): String {
    let sb = StringBuilder()
    for (c in r.content) {
        match (c) {
            case ContentBlock.Text(tc) => sb.append(tc.text)
            case _ => ()
        }
    }
    sb.toString()
}

// 窗口计算：显式 from/to 或 granularity+anchor；返回 (winFrom, winTo) 或 None（无法解析）
// day/week/month 按本地日历对齐（§5.2，非 epoch 锚定），10min/30min/1h/3h 为钟表对齐
func resolveWindow(svc: MemoryService, name: String, args: HashMap<String, JsonValue>): Option<(Int64, Int64)> {
    let from = argInt(args, "from")
    let to = argInt(args, "to")
    if (from > 0 && to > 0) { return Some((from, to)) }
    let granularity = argStr(args, "granularity")
    if (granularity == "") { return None }
    let gErr = requireGranularity(svc, name, granularity)
    if (let Some(e) <- gErr) { return None }
    let anchor = argInt(args, "windowStartMs")
    let anchorFinal = if (anchor > 0) { anchor } else { nowMs() }
    let tl = svc.registry.timelineOf(name).getOrThrow()
    Some(tl.windowRangeOf(anchorFinal, granularity))
}

// ---------- 工具 handler ----------

public func handleTypeCreate(svc: MemoryService, args: HashMap<String, JsonValue>): CallToolResult {
    let name = argStr(args, "name")
    if (name == "") { return toolError("缺少参数 name（类型名，如 worklog 或 proj/decisions）") }
    let levels = argLevels(args, "levels", Timeline.defaultLevels())
    let schema: Option<String> = match (args.get("schema")) {
        case Some(v) =>
            match (v) {
                case JsonValue.String(s) => Some(s)
                case _ => Some(v.stringify())
            }
        case None => None
    }
    let retention: Option<String> = if (argStr(args, "retention") == "") { None } else { Some(argStr(args, "retention")) }
    let autoSummarize = argBool(args, "auto_summarize", false)
    let summaryLevels: Option<ArrayList<String>> = match (args.get("summary_levels")) {
        case Some(JsonValue.Array(arr)) =>
            let l = ArrayList<String>()
            for (v in arr) {
                match (v) {
                    case JsonValue.String(s) => l.add(s)
                    case _ => ()
                }
            }
            if (l.size > 0) { Some(l) } else { None }
        case _ => None
    }
    // 总结分组维度（tag 键列表，如 ["proj"]，上限 2 个）
    let summaryGroupBy: Option<ArrayList<String>> = match (args.get("summary_group_by")) {
        case Some(JsonValue.Array(arr)) =>
            let l = ArrayList<String>()
            for (v in arr) {
                match (v) {
                    case JsonValue.String(s) => l.add(s)
                    case _ => ()
                }
            }
            if (l.size > 0) { Some(l) } else { None }
        case _ => None
    }
    let meta = TypeMeta(name, argStr(args, "description"), schema, levels, retention,
        autoSummarize, summaryLevels, nowMs(), summaryGroupBy: summaryGroupBy)
    try {
        svc.registry.create(meta)
    } catch (e: Exception) {
        return toolError(e.toString())
    }
    let autoTag = if (autoSummarize) { "，自动总结" } else { "" }
    let groupTag = match (summaryGroupBy) {
        case Some(dims) => "，按分组总结（" + dims.toString() + "）"
        case None => ""
    }
    CallToolResult.text("已创建类型 " + name + "（粒度 " + levelsString(levels) + autoTag + groupTag + "）")
}

// 更新已有类型的可变配置：description / schema / retention / auto_summarize /
// summary_levels / summary_group_by。
// - **levels 与 name 不可修改**：levels 的物化桶链不可逆，改值必须 truncate + type_delete 重建；
//   传与现值相同的 levels 按 no-op 接受 —— bridge "查存在 → 缺则建 / 有则校正" 的幂等自愈依赖这一点。
// - 字段语义：**省略 = 保持不变；传空串 / 空数组 = 清空；其余 = 覆盖**。
// - 类型不存在 → 报错（本工具不创建类型，创建走 mem/type_create）。
public func handleTypeUpdate(svc: MemoryService, args: HashMap<String, JsonValue>): CallToolResult {
    let name = argStr(args, "name")
    if (name == "") { return toolError("缺少参数 name") }
    let oldOpt = svc.registry.get(name)
    match (oldOpt) {
        case None => return toolError("类型不存在: " + name + "（mem/type_update 只更新已有类型，创建请用 mem/type_create）")
        case Some(_) => ()
    }
    let old = oldOpt.getOrThrow()
    if (args.contains("levels")) {
        let wanted = argLevels(args, "levels", ArrayList<String>())
        if (!sameStringList(wanted, old.levels)) {
            return toolError("levels 不可修改（物化桶链不可逆）：当前 " + old.levels.toString()
                + "，请求 " + wanted.toString()
                + "；如需变更请 mem/truncate + mem/type_delete 后重新 mem/type_create")
        }
    }
    let description = if (args.contains("description")) { argStr(args, "description") } else { old.description }
    let schema = if (args.contains("schema")) { argOptStr(args, "schema") } else { old.schema }
    let retention = if (args.contains("retention")) { argOptStr(args, "retention") } else { old.retention }
    let autoSummarize = if (args.contains("auto_summarize")) {
        argBool(args, "auto_summarize", old.autoSummarize)
    } else {
        old.autoSummarize
    }
    let summaryLevels = if (args.contains("summary_levels")) { argOptList(args, "summary_levels") } else { old.summaryLevels }
    let summaryGroupBy = if (args.contains("summary_group_by")) { argOptList(args, "summary_group_by") } else { old.summaryGroupBy }
    let changed = ArrayList<String>()
    if (description != old.description) { changed.add("description") }
    if (schema != old.schema) { changed.add("schema") }
    if (retention != old.retention) { changed.add("retention") }
    if (autoSummarize != old.autoSummarize) { changed.add("auto_summarize") }
    if (!sameOptList(summaryLevels, old.summaryLevels)) { changed.add("summary_levels") }
    if (!sameOptList(summaryGroupBy, old.summaryGroupBy)) { changed.add("summary_group_by") }
    if (changed.size == 0) {
        return CallToolResult.text("已更新类型 " + name + "（无变化）")
    }
    let meta = TypeMeta(old.name, description, schema, old.levels, retention, autoSummarize,
        summaryLevels, old.createdAt, summaryGroupBy: summaryGroupBy)
    try {
        svc.registry.updateMeta(meta)
    } catch (e: Exception) {
        return toolError(e.toString())
    }
    let autoTag = if (autoSummarize) { "，自动总结" } else { "" }
    let groupTag = match (summaryGroupBy) {
        case Some(dims) => "，按分组总结（" + dims.toString() + "）"
        case None => ""
    }
    CallToolResult.text("已更新类型 " + name + "：" + changed.toString()
        + "（粒度 " + levelsString(old.levels) + autoTag + groupTag + "）")
}

public func handleListTypes(svc: MemoryService, args: HashMap<String, JsonValue>): CallToolResult {
    let types = svc.registry.list()
    if (types.size == 0) {
        return CallToolResult.text("（暂无记忆类型；用 mem/type_create 创建）")
    }
    let sb = StringBuilder()
    for (m in types) {
        sb.append("- " + m.name)
        if (m.description != "") { sb.append(": " + m.description) }
        sb.append("（条目 " + svc.registry.countEntries(m.name).toString() + "，粒度 " + levelsString(m.levels) + "）\n")
    }
    CallToolResult.text(sb.toString())
}

public func handleTypeInfo(svc: MemoryService, args: HashMap<String, JsonValue>): CallToolResult {
    let name = argStr(args, "name")
    if (name == "") { return toolError("缺少参数 name") }
    match (svc.registry.get(name)) {
        case None => return toolError("类型不存在: " + name)
        case Some(m) => ()
    }
    let sb = StringBuilder()
    sb.append("类型: " + name + "\n")
    sb.append("描述: " + svc.registry.get(name).getOrThrow().description + "\n")
    sb.append("粒度链: " + levelsString(svc.registry.get(name).getOrThrow().levels) + "\n")
    let autoText = if (svc.registry.get(name).getOrThrow().autoSummarize) { "true" } else { "false" }
    sb.append("自动总结: " + autoText + "\n")
    match (svc.registry.get(name).getOrThrow().summaryLevels) {
        case Some(ls) => sb.append("总结粒度: " + ls.toString() + "\n")
        case None => ()
    }
    match (svc.registry.get(name).getOrThrow().retention) {
        case Some(r) => sb.append("保留期: " + r + "\n")
        case None => ()
    }
    match (svc.registry.get(name).getOrThrow().schema) {
        case Some(sc) => sb.append("字段描述: 已设置（" + sc.size.toString() + " 字符）\n")
        case None => ()
    }
    match (svc.registry.get(name).getOrThrow().summaryGroupBy) {
        case Some(dims) => sb.append("总结分组维度: " + dims.toString() + "\n")
        case None => ()
    }
    sb.append("条目数: " + svc.registry.countEntries(name).toString() + "\n")
    let tl = svc.registry.timelineOf(name).getOrThrow()
    for (l in svc.registry.get(name).getOrThrow().levels) {
        sb.append(l + " 桶: " + tl.listBuckets(l, None, None).size.toString() + "\n")
    }
    CallToolResult.text(sb.toString())
}

// TRUNCATE：清空类型全部条目（原始 + 总结），保留类型
public func handleTruncate(svc: MemoryService, args: HashMap<String, JsonValue>): CallToolResult {
    let name = argStr(args, "type")
    if (let Some(e) <- requireType(svc, name)) { return e }
    let n = svc.registry.truncate(name)
    CallToolResult.text("已清空类型 " + name + "（删除原始条目 " + n.toString() + " 条，类型保留）")
}

// DROP：删除类型（守卫：原始与总结序列必须为空，防误删）
public func handleTypeDelete(svc: MemoryService, args: HashMap<String, JsonValue>): CallToolResult {
    let name = argStr(args, "type")
    if (let Some(e) <- requireType(svc, name)) { return e }
    try {
        svc.registry.drop(name)
    } catch (e: Exception) {
        return toolError(e.toString())
    }
    CallToolResult.text("已删除类型 " + name)
}

public func handleAppend(svc: MemoryService, args: HashMap<String, JsonValue>): CallToolResult {
    let name = argStr(args, "type")
    if (let Some(e) <- requireType(svc, name)) { return e }
    match (args.get("payload")) {
        case None => return toolError("缺少参数 payload（条目 JSON 对象）")
        case Some(JsonValue.Null) => return toolError("缺少参数 payload（条目 JSON 对象）")
        case Some(_) => ()
    }
    let payloadJson = args.get("payload").getOrThrow().stringify()
    // 单条限长（生产 OOM 防线，见 MAX_APPEND_PAYLOAD_BYTES）：大 payload 的请求处理
    // 瞬时分配放大 ~5-7×，顶爆 256MB GC 堆 → OOM → 请求悬挂/服务卡死。
    let payloadBytes = payloadJson.toArray().size
    if (payloadBytes > MAX_APPEND_PAYLOAD_BYTES) {
        return toolError("条目过大：" + (payloadBytes / 1024).toString()
            + "KB 超过上限 " + (MAX_APPEND_PAYLOAD_BYTES / 1024).toString()
            + "KB（忆时塔为日志型存储，超大文本请拆分后追加）")
    }
    let ts = argInt(args, "ts")
    let tsFinal = if (ts > 0) { ts } else { nowMs() }
    let tags = argTags(args, "tags")
    let tl = svc.registry.timelineOf(name).getOrThrow()
    tl.append(tsFinal, payloadJson, tags)
    CallToolResult.text("已追加 " + name + " @" + fmtTs(tsFinal, svc.store.timeZoneOf()))
}

public func handleQuery(svc: MemoryService, args: HashMap<String, JsonValue>): CallToolResult {
    let name = argStr(args, "type")
    if (let Some(e) <- requireType(svc, name)) { return e }
    let from = argInt(args, "from")
    let to = argInt(args, "to")
    let limit = argInt(args, "limit")
    let page = argInt(args, "page")
    let tagFilter = argTagPair(args, "tag")
    let tl = svc.registry.timelineOf(name).getOrThrow()
    let pageSize = if (limit > 0) { limit } else { 20 }
    // 页码分页（page ≥ 1 时生效，默认第 1 页；limit = 每页条数）：
    // 响应头给出总数/总页数，AI 可据此翻页取完，不遗漏（此前单次全量取 limit 条）。
    let (points, total) = tl.queryPointsPage(from, to, page, pageSize, tagFilter)
    if (total == 0) { return CallToolResult.text("（无匹配条目）") }
    let sb = StringBuilder()
    // 分页头：共 N 条 · 第 p/totalPages 页 · 每页 L 条
    let totalPages = (total + pageSize - 1) / pageSize
    let curPage = if (page > 0) { page } else { 1 }
    if (points.size == 0) {
        sb.append("（无更多条目：共 " + total.toString() + " 条 · 第 " + curPage.toString() + "/"
            + totalPages.toString() + " 页 · 每页 " + pageSize.toString() + " 条）")
        return CallToolResult.text(sb.toString())
    }
    sb.append("共 " + total.toString() + " 条 · 第 " + curPage.toString() + "/" + totalPages.toString()
        + " 页 · 每页 " + pageSize.toString() + " 条")
    if (curPage < totalPages) {
        sb.append("（下一页请带 page=" + (curPage + 1).toString() + "）")
    }
    sb.append("\n")
    sb.append(formatPoints(points, svc.store.timeZoneOf()))
    CallToolResult.text(sb.toString())
}

public func handleRecall(svc: MemoryService, args: HashMap<String, JsonValue>): CallToolResult {
    let name = argStr(args, "type")
    if (let Some(e) <- requireType(svc, name)) { return e }
    let granularity = argStr(args, "granularity")
    if (let Some(e) <- requireGranularity(svc, name, granularity)) { return e }
    let mode = argStr(args, "mode")
    let isSummary = mode == "summary"
    let anchor = argInt(args, "windowStartMs")
    let summarizeOnMiss = argBool(args, "summarize_on_miss", false)
    let tl = svc.registry.timelineOf(name).getOrThrow()

    // 目标窗口（day/week/month 本地日历对齐，§5.2；钟表粒度 epoch 对齐）
    let anchorFinal = if (anchor > 0) { anchor } else { nowMs() }
    let (winFrom, winTo) = tl.windowRangeOf(anchorFinal, granularity)

    if (isSummary) {
        // 语义回顾：返回覆盖窗口的摘要（可按分组过滤）；无摘要时按 summarize_on_miss 决定现算
        let groupFilter = argStr(args, "group")
        let matches = overlappingSummaries(svc, name, winFrom, winTo, groupFilter)
        if (matches.size > 0) {
            let sb = StringBuilder()
            for (rec in matches) {
                sb.append("【" + groupLabel(rec.groupKey) + "】\n")
                sb.append(rec.text + "\n\n")
            }
            return CallToolResult.text(sb.toString())
        }
        if (summarizeOnMiss) {
            // 无摘要：提交后台总结任务，立即返回（LLM 在后台跑，不阻塞本请求）
            if (svc.summarizer.isNone()) {
                return toolError("未配置 LLM（LLM_BASE_URL / LLM_API_KEY / LLM_MODEL）")
            }
            let id = svc.summarizeRunner.getOrThrow().submit(name, winFrom, winTo, "", true)
            return CallToolResult.text("该时段无摘要，已提交后台总结任务 #" + id.toString() +
                "，完成后重试本调用即可获取（或 mem/summarize_status #" + id.toString() + " 查询状态）")
        }
        return CallToolResult.text("该时段尚无语义摘要，请先 mem/summarize（或设 summarize_on_miss=true 现算）")
    }
    // 精确下钻（零 LLM）。严格匹配目标窗口：窗口没有桶时不得回退到更早窗口，
    // 否则会把**别的时段**的记录当作本时段证据返回（调用方无从辨别）。
    match (tl.bucketAt(granularity, anchorFinal)) {
        case Some(key) =>
            let points = tl.drillDown(granularity, key)
            if (points.size == 0) { return CallToolResult.text("该时间窗无记录") }
            CallToolResult.text(formatPoints(points, svc.store.timeZoneOf()))
        case None =>
            // 「本来就没记录」与「有记录但尚未物化」对调用方含义完全不同，须分开告知。
            let alive = tl.countIn(winFrom, winTo)
            if (alive > 0) {
                return CallToolResult.text("该时间窗有 " + alive.toString()
                    + " 条记录但尚未物化（物化每分钟推进）；期间可用 mem/query 直读原始条目")
            }
            CallToolResult.text("该时间窗无记录")
    }
}

public func handleBuckets(svc: MemoryService, args: HashMap<String, JsonValue>): CallToolResult {
    let name = argStr(args, "type")
    if (let Some(e) <- requireType(svc, name)) { return e }
    let granularity = argStr(args, "granularity")
    if (let Some(e) <- requireGranularity(svc, name, granularity)) { return e }
    let tl = svc.registry.timelineOf(name).getOrThrow()
    let buckets = tl.listBuckets(granularity, None, None)
    if (buckets.size == 0) { return CallToolResult.text("该粒度暂无物化桶") }
    let sb = StringBuilder()
    for (b in buckets) {
        sb.append(b.bucketKey + " | " + b.summary + "\n")
    }
    CallToolResult.text(sb.toString())
}

public func handleSummarize(svc: MemoryService, args: HashMap<String, JsonValue>): CallToolResult {
    let name = argStr(args, "type")
    if (let Some(e) <- requireType(svc, name)) { return e }
    let instructions = argStr(args, "instructions")
    let store = argBool(args, "store", true)
    let from = argInt(args, "from")
    let to = argInt(args, "to")
    var winFrom = Int64(0)
    var winTo = Int64(0)
    if (from > 0 && to > 0) {
        winFrom = from
        winTo = to
    } else {
        let granularity = argStr(args, "granularity")
        if (granularity == "") {
            return toolError("需提供 from/to（显式窗口，任务阶段）或 granularity（按粒度窗口）")
        }
        if (let Some(e) <- requireGranularity(svc, name, granularity)) { return e }
        let anchor = argInt(args, "windowStartMs")
        let anchorFinal = if (anchor > 0) { anchor } else { nowMs() }
        let tl = svc.registry.timelineOf(name).getOrThrow()
        let (wf, wt) = tl.windowRangeOf(anchorFinal, granularity)
        winFrom = wf
        winTo = wt
    }
    // 未配置 LLM：提交也会失败，直接明确报错（其余功能不受影响）
    if (svc.summarizer.isNone()) {
        return toolError("未配置 LLM（LLM_BASE_URL / LLM_API_KEY / LLM_MODEL）")
    }
    let recompute = argBool(args, "recompute", false)
    // 提交后台任务，立即返回（LLM 在后台线程跑，不阻塞本请求与任何其他请求）
    let id = svc.summarizeRunner.getOrThrow().submit(name, winFrom, winTo, instructions, store, recompute: recompute)
    let modelOverride = argStr(args, "model")
    let modelNote = if (modelOverride != "" && svc.summarizer.getOrThrow().modelName() != modelOverride) {
        "（注：model=" + modelOverride + " 覆盖暂未生效，使用配置模型 " + svc.summarizer.getOrThrow().modelName() + "）"
    } else {
        ""
    }
    let storeHint = if (store) {
        "结果将落库，可用 mem/summaries 或 mem/recall mode=summary 查看"
    } else {
        "结果暂存内存，可用 mem/summarize_status 查询"
    }
    CallToolResult.text("已提交后台总结任务 #" + id.toString() + "（类型 " + name + "，窗口 " +
        winFrom.toString() + "~" + winTo.toString() + "，模型 " + svc.summarizer.getOrThrow().modelName() +
        "）。" + storeHint + "；状态用 mem/summarize_status 查询。" + modelNote)
}

// mem/summarize_status：查询后台总结任务状态（store=false 时可取回结果文本）
public func handleSummarizeStatus(svc: MemoryService, args: HashMap<String, JsonValue>): CallToolResult {
    let id = argInt(args, "job_id")
    if (id <= 0) { return toolError("缺少参数 job_id（mem/summarize 返回的任务号）") }
    match (svc.summarizeRunner) {
        case None => toolError("后台总结执行器未初始化")
        case Some(r) =>
            let st = r.status(id)
            match (r.getResult(id)) {
                case Some(text) => CallToolResult.text("任务 #" + id.toString() + " 状态: " + st + "\n" + text)
                case None => CallToolResult.text("任务 #" + id.toString() + " 状态: " + st)
            }
    }
}

public func handleSummaries(svc: MemoryService, args: HashMap<String, JsonValue>): CallToolResult {
    let name = argStr(args, "type")
    if (let Some(e) <- requireType(svc, name)) { return e }
    let from = argInt(args, "from")
    let to = argInt(args, "to")
    let limit = argInt(args, "limit")
    let stl = svc.registry.summaryTimelineOf(name).getOrThrow()
    let points = stl.queryPoints(from, to, if (limit > 0) { limit } else { 10 }, None)
    if (points.size == 0) { return CallToolResult.text("（暂无总结记录）") }
    let sb = StringBuilder()
    for (p in points) {
        let rec = fromJsonString<SummaryRecord>(p.payload)
        let groupTag = match (rec.groupKey) {
            case Some(g) => "【" + groupLabel(Some(g)) + "】"
            case None => ""
        }
        // 生成口径可见：切过块/截断过的摘要一眼能看出来（否则只能猜为什么质量不同）
        let genTag = if (rec.strategy == "" || rec.strategy == "direct") {
            ""
        } else {
            " " + rec.strategy + "(" + rec.chunks.toString() + "段/截断" + rec.clippedEntries.toString() + ")"
        }
        sb.append("[" + fmtTs(rec.ts, svc.store.timeZoneOf()) + " 窗口 " + rec.windowFrom.toString() + "~" + rec.windowTo.toString() + " " + rec.model + genTag + "]" + groupTag + "\n")
        sb.append(rec.text + "\n\n")
    }
    CallToolResult.text(sb.toString())
}

// ---------- 工具注册 ----------

func schemaBuilder(): ToolInputSchema {
    ToolInputSchema("object", HashMap<String, JsonValue>(), [])
}

public func registerTools(server: McpServer, svc: MemoryService): Unit {
    // mem/type_create
    let s1 = schemaBuilder()
    s1.addField("name", "string", "类型名（白名单 [A-Za-z0-9_/-]，如 worklog、proj/decisions）", required: true)
    s1.addField("levels", "array", "粒度链（可选，默认 10min/30min/1h/day/week；低频类型可收敛到 day/week）")
    s1.addField("description", "string", "类型描述")
    s1.addField("schema", "string", "可选字段描述（JSON 字符串，仅作文档/LLM 提示，宽松模式不校验）")
    s1.addField("retention", "string", "可选保留期（如 30d）")
    s1.addField("auto_summarize", "boolean", "后台自动语义总结（默认 false，opt-in；已闭合窗口自动长摘要）")
    s1.addField("summary_levels", "array", "自动总结粒度（可选；缺省 = 粒度链最粗 2 档，如 day/week）")
    s1.addField("summary_group_by", "array", "总结分组维度（可选；tag 键列表，如 [\"proj\"]，上限 2 个；None=整窗总结）")
    let t1 = Tool("mem/type_create", "创建记忆类型（自动建 <type>.summary 总结 series）", s1)
    server.addTool(t1, { params => handleTypeCreate(svc, params.arguments) })

    // mem/type_update（更新可变配置；levels/name 不可改）
    let sUpd = schemaBuilder()
    sUpd.addField("name", "string", "类型名（必须已存在；本工具不创建类型）", required: true)
    sUpd.addField("description", "string", "新描述（空串=清空；省略=不变）")
    sUpd.addField("schema", "string", "新字段描述 JSON（空串=清空；省略=不变）")
    sUpd.addField("retention", "string", "新保留期，如 30d（空串=清空；省略=不变）")
    sUpd.addField("auto_summarize", "boolean", "后台自动语义总结开关（省略=不变）")
    sUpd.addField("summary_levels", "array", "自动总结粒度（[]=清空回缺省；省略=不变）")
    sUpd.addField("summary_group_by", "array", "总结分组维度 tag 键（上限 2 个；[]=清空；省略=不变）")
    sUpd.addField("levels", "array", "仅作一致性校验：只接受与现值相同的粒度链（levels 不可修改）")
    let updDesc = "更新已有类型的可变配置（description/schema/retention/auto_summarize/" +
        "summary_levels/summary_group_by）；省略的字段保持不变，空串/空数组表示清空；" +
        "levels 与 name 不可修改（物化桶链不可逆），levels 传相同值按无变化接受"
    let tUpd = Tool("mem/type_update", updDesc, sUpd)
    server.addTool(tUpd, { params => handleTypeUpdate(svc, params.arguments) })

    // mem/list_types
    let s2 = schemaBuilder()
    let t2 = Tool("mem/list_types", "列出全部记忆类型（name/描述/条目数/粒度链）", s2)
    server.addTool(t2, { params => handleListTypes(svc, params.arguments) })

    // mem/type_info
    let s3 = schemaBuilder()
    s3.addField("name", "string", "类型名", required: true)
    let t3 = Tool("mem/type_info", "单类型详情（meta + 条目数 + 各粒度物化桶数）", s3)
    server.addTool(t3, { params => handleTypeInfo(svc, params.arguments) })

    // mem/truncate（TRUNCATE：清空条目，保留类型）
    let sTrunc = schemaBuilder()
    sTrunc.addField("type", "string", "类型名", required: true)
    let tTrunc = Tool("mem/truncate", "清空类型全部条目（原始 + 总结，TRUNCATE 语义），保留类型本身", sTrunc)
    server.addTool(tTrunc, { params => handleTruncate(svc, params.arguments) })

    // mem/type_delete（DROP：删类型；守卫：原始与总结序列必须为空）
    let sDel = schemaBuilder()
    sDel.addField("type", "string", "类型名", required: true)
    let tDel = Tool("mem/type_delete", "删除类型（DROP 语义；须原始与总结序列为空，先 mem/truncate）", sDel)
    server.addTool(tDel, { params => handleTypeDelete(svc, params.arguments) })

    // mem/append
    let s4 = schemaBuilder()
    s4.addField("type", "string", "类型名", required: true)
    s4.addField("payload", "object", "条目 JSON 对象", required: true)
    s4.addField("tags", "object", "标签（string→string）")
    s4.addField("ts", "integer", "时间戳毫秒（缺省=当前时间）")
    let t4 = Tool("mem/append", "追加一条原始条目到记忆类型", s4)
    server.addTool(t4, { params => handleAppend(svc, params.arguments) })

    // mem/query
    let s5 = schemaBuilder()
    s5.addField("type", "string", "类型名", required: true)
    s5.addField("from", "integer", "起始时间（毫秒，0=不限）")
    s5.addField("to", "integer", "结束时间（毫秒，0=不限）")
    s5.addField("limit", "integer", "每页条数（默认 20；响应头给总数/总页数，翻页用 page）")
    s5.addField("page", "integer", "页码（1 起，默认 1；首页响应会提示下一页的 page 值）")
    s5.addField("tag", "string", "标签过滤 key=value")
    let t5 = Tool("mem/query", "结构回想：最近/时间范围/tag 过滤原始条目（零 LLM）；分页返回（响应头含 总数·第x/y页，按提示翻页取完，勿一次拉超大 limit）", s5)
    server.addTool(t5, { params => handleQuery(svc, params.arguments) })

    // mem/recall
    let s6 = schemaBuilder()
    s6.addField("type", "string", "类型名", required: true)
    s6.addField("granularity", "string", "粒度（须在类型 levels 内）", required: true)
    s6.addField("windowStartMs", "integer", "锚点毫秒时间戳（缺省=当前时间）")
    s6.addField("mode", "string", "exact=下钻原始（零 LLM）/ summary=语义回顾")
    s6.addField("summarize_on_miss", "boolean", "summary 模式无摘要时是否现算落库（默认 false）")
    s6.addField("group", "string", "summary 模式按分组过滤（可选；类型配置了分组维度时有效，如 proj 值；\"未分组\" 查无 tag 条目）")
    let t6 = Tool("mem/recall", "回想：mode=exact 沿物化桶下钻原始条目（零 LLM）；mode=summary 返回时段语义摘要", s6)
    server.addTool(t6, { params => handleRecall(svc, params.arguments) })

    // mem/buckets
    let s7 = schemaBuilder()
    s7.addField("type", "string", "类型名", required: true)
    s7.addField("granularity", "string", "粒度（须在类型 levels 内）", required: true)
    let t7 = Tool("mem/buckets", "列出某粒度的物化桶（发现可用窗口 + 桶摘要）", s7)
    server.addTool(t7, { params => handleBuckets(svc, params.arguments) })

    // mem/summarize
    let s8 = schemaBuilder()
    s8.addField("type", "string", "类型名", required: true)
    s8.addField("from", "integer", "窗口起始（毫秒）")
    s8.addField("to", "integer", "窗口结束（毫秒）")
    s8.addField("granularity", "string", "按粒度窗口（须在类型 levels 内；与 from/to 二选一）")
    s8.addField("windowStartMs", "integer", "granularity 模式的锚点（缺省=当前时间）")
    s8.addField("instructions", "string", "额外总结要求")
    s8.addField("model", "string", "模型覆盖（当前用配置模型）")
    s8.addField("recompute", "boolean", "强制基于原始条目重算（当前恒为原始基）")
    s8.addField("store", "boolean", "是否落库为总结记录（默认 true）")
    let t8 = Tool("mem/summarize", "语义总结（后台异步）：提交总结任务立即返回 job_id，LLM 在后台执行，不阻塞其他请求；完成后用 mem/summaries / mem/recall 或 mem/summarize_status 取回", s8)
    server.addTool(t8, { params => handleSummarize(svc, params.arguments) })

    // mem/summarize_status
    let s8s = schemaBuilder()
    s8s.addField("job_id", "integer", "mem/summarize 返回的任务号", required: true)
    let t8s = Tool("mem/summarize_status", "查后台总结任务状态（pending/running/done/failed；store=false 时返回结果文本）", s8s)
    server.addTool(t8s, { params => handleSummarizeStatus(svc, params.arguments) })

    // mem/summaries
    let s9 = schemaBuilder()
    s9.addField("type", "string", "类型名", required: true)
    s9.addField("from", "integer", "起始时间（毫秒，0=不限）")
    s9.addField("to", "integer", "结束时间（毫秒，0=不限）")
    s9.addField("limit", "integer", "条数（默认 10）")
    let t9 = Tool("mem/summaries", "查某类型的语义总结记录（最新在前）", s9)
    server.addTool(t9, { params => handleSummaries(svc, params.arguments) })
}

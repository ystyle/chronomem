// 忆时塔 Web UI 纯逻辑层：与渲染无关的解析/格式化（可独立单测）。
// package chronomem.ui —— 不依赖 cjxt / chronomem.mcp，仅依赖 std + chronomem.core 类型。
package chronomem.ui

import std.collection.*
import std.sort.*
import std.time.*
import jsonvalue.*

// ---------- 字符串辅助（标准库无 trim/trimStart 字符串版本，字节级自实现） ----------

public func trimSpace(s: String): String {
    var start = Int64(0)
    var end = s.size
    while (start < end) {
        let c = s[start]
        if (c == 32u8 || c == 9u8 || c == 10u8 || c == 13u8) { start += 1; continue }
        // 全角空格 \u{3000} = E3 80 80
        if (c == 227u8 && start + 2 < end && s[start + 1] == 128u8 && s[start + 2] == 128u8) { start += 3; continue }
        break
    }
    while (start < end) {
        let c = s[end - 1]
        if (c == 32u8 || c == 9u8 || c == 10u8 || c == 13u8) { end -= 1; continue }
        if (c == 128u8 && end - 3 >= start && s[end - 2] == 128u8 && s[end - 3] == 227u8) { end -= 3; continue }
        break
    }
    s[start..end]
}

// 跳过头部的任意给定字符（ASCII 假设；用于 "#* " 等标记剥离）
public func trimStartChars(s: String, chars: String): String {
    var start = Int64(0)
    while (start < s.size) {
        let c = s[start]
        var found = false
        for (i in 0..chars.size) {
            if (chars[i] == c) { found = true; break }
        }
        if (!found) { break }
        start += 1
    }
    s[start..s.size]
}

// ---------- 总结文本分节（SummaryRecord.text 是 LLM 结构化输出，节标题可能带 "### " / "**" 等前缀） ----------

public struct SummarySections {
    public let decisions: ArrayList<String>
    public let conclusions: ArrayList<String>
    public let todos: ArrayList<String>
    public let statusChanges: ArrayList<String>
    public let keywords: ArrayList<String>

    public init() {
        this.decisions = ArrayList<String>()
        this.conclusions = ArrayList<String>()
        this.todos = ArrayList<String>()
        this.statusChanges = ArrayList<String>()
        this.keywords = ArrayList<String>()
    }

    public func isEmpty(): Bool {
        decisions.isEmpty() && conclusions.isEmpty() && todos.isEmpty()
            && statusChanges.isEmpty() && keywords.isEmpty()
    }
}


// String.indexOf 返回 Option<Int64>：统一为 -1 缺失语义
func findChar(s: String, mark: String): Int64 {
    match (s.indexOf(mark)) {
        case Some(i) => i
        case None => -1
    }
}

// 节标题正则（行首或 ###/##/** 前缀后），返回节名；非标题行返回空串
func sectionOf(line0: String): String {
    var line = trimStartChars(trimSpace(line0), "#* \u{3000}")
    // 无冒号形式（"### 决策" / "结论"）：整行即节名
    if (line == "决策") { return "决策" }
    if (line == "结论") { return "结论" }
    if (line == "待办") { return "待办" }
    if (line == "TODO") { return "待办" }
    if (line == "状态变更" || line == "状态变化") { return "状态变更" }
    if (line == "关键词") { return "关键词" }
    let colon = findChar(line, "：")
    let colonAscii = findChar(line, ":")
    var head = ""
    if (colon >= 0 && (colonAscii < 0 || colon < colonAscii)) {
        head = line[0..colon]
    } else if (colonAscii >= 0) {
        head = line[0..colonAscii]
    }
    if (head == "") { return "" }
    if (head.startsWith("决策") || head.contains("决策")) { return "决策" }
    if (head.startsWith("结论") || head.contains("结论")) { return "结论" }
    if (head.startsWith("待办") || head.startsWith("TODO") || head.contains("待办")) { return "待办" }
    if (head.contains("状态变更") || head.contains("状态变化")) { return "状态变更" }
    if (head.startsWith("关键词") || head.contains("关键词")) { return "关键词" }
    ""
}

// 从文本解析出分节列表；支持多节单行的紧凑格式（如 "决策：…；结论：…"），也支持逐行 "- " 列表。
public func parseSummarySections(text: String): SummarySections {
    let out = SummarySections()
    var current = ""
    for (rawLine in text.split("\n")) {
        let line = trimSpace(rawLine)
        if (line == "") { continue }
        // 单行多节（紧凑格式）：按分号切分后逐段归节（仅当切出的段包含节头时）
        if (lineCountSections(line) >= 2) {
            for (seg in line.split("；")) {
                let s = trimSpace(seg)
                if (s == "") { continue }
                let sec = sectionOf(s)
                if (sec != "") {
                    current = sec
                    let rest = stripSectionHead(s)
                    if (rest != "") { appendBullet(out, current, rest) }
                } else if (current != "") {
                    appendBullet(out, current, s)
                }
            }
            continue
        }
        let sec = sectionOf(line)
        if (sec != "") {
            current = sec
            let rest = stripSectionHead(line)
            if (rest != "") { appendBullet(out, current, rest) }
        } else if (current != "") {
            appendBullet(out, current, line)
        }
    }
    out
}

func lineCountSections(line: String): Int64 {
    var n = Int64(0)
    if (sectionOf(line) != "") { n += 1 }
    for (seg in line.split("；")) {
        let s = trimSpace(seg)
        if (s != "" && sectionOf(s) != "") { n += 1 }
    }
    n
}

func stripSectionHead(line: String): String {
    var s = trimStartChars(trimSpace(line), "#* \u{3000}")
    let colon = findChar(s, "：")
    let colonAscii = findChar(s, ":")
    if (colon >= 0 && (colonAscii < 0 || colon < colonAscii)) {
        // "：" 为 3 字节 UTF-8 字符：从冒号之后截断（不能 cut+1 停在字符中间）
        s = s[colon + 3..s.size]
    } else if (colonAscii >= 0) {
        s = s[colonAscii + 1..s.size]
    } else {
        return ""
    }
    trimSpace(s)
}

func appendBullet(out: SummarySections, sec: String, line: String): Unit {
    // 去掉列表标记（- * · 1. 等）
    var t = trimSpace(line)
    if (t.startsWith("- ")) { t = t[2..t.size] }
    if (t.startsWith("* ")) { t = t[2..t.size] }
    if (t.startsWith("·")) { t = t[3..t.size] }
    t = trimSpace(t)
    if (t == "") { return }
    match (sec) {
        case "决策" => out.decisions.add(t)
        case "结论" => out.conclusions.add(t)
        case "待办" => out.todos.add(t)
        case "状态变更" => out.statusChanges.add(t)
        case "关键词" => out.keywords.add(t)
        case _ => ()
    }
}

// ---------- 时间格式化 ----------

public func fmtTime(ts: Int64, tz: TimeZone): String {
    DateTime.ofEpoch(second: ts / 1000, nanosecond: (ts % 1000) * 1000000)
        .inTimeZone(tz).format("MM-dd HH:mm:ss")
}

public func fmtDateTime(ts: Int64, tz: TimeZone): String {
    DateTime.ofEpoch(second: ts / 1000, nanosecond: (ts % 1000) * 1000000)
        .inTimeZone(tz).format("yyyy-MM-dd HH:mm:ss")
}

// ---------- ISO 桶 key 解析（"yyyy-MM-ddTHH:mm:ssZ" UTC）→ epoch ms（手写日历算法，零依赖） ----------

public func parseIsoUtcMs(key: String): Int64 {
    if (key.size < 19) { return 0 }
    let y = parseIntSeg(key, 0, 4)
    let mo = parseIntSeg(key, 5, 2)
    let d = parseIntSeg(key, 8, 2)
    let h = parseIntSeg(key, 11, 2)
    let mi = parseIntSeg(key, 14, 2)
    let se = parseIntSeg(key, 17, 2)
    if (y <= 0 || mo < 1 || mo > 12 || d < 1) { return 0 }
    let days = daysFromCivil(y, mo, d)
    days * 86400000 + h * 3600000 + mi * 60000 + se * 1000
}

func parseIntSeg(key: String, from: Int64, len: Int64): Int64 {
    if (from + len > key.size) { return 0 }
    var v = Int64(0)
    for (i in from..from + len) {
        let c = key[i]
        if (c < 48u8 || c > 57u8) { return 0 }
        v = v * 10 + Int64(c - 48u8)
    }
    v
}

// Howard Hinnant days_from_civil：公历日期 → 1970-01-01 起天数（UTC 日界）
public func daysFromCivil(y: Int64, m: Int64, d: Int64): Int64 {
    var yy = y
    if (m <= 2) { yy = yy - 1 }
    let era = if (yy >= 0) { yy / 400 } else { (yy - 399) / 400 }
    let yoe = yy - era * 400
    let mp = (m + 9) % 12
    let doy = (153 * mp + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    era * 146097 + doe - 719468
}

// 桶显示标签：day 桶 = 本地日期 "2026-08-29"；week 桶 = "08-17 周"；month = "2026-08"；钟表桶保留 UTC key
public func bucketLocalLabel(key: String, granularity: String, tz: TimeZone): String {
    let ms = parseIsoUtcMs(key)
    if (ms == 0) { return key }
    let dt = DateTime.ofEpoch(second: ms / 1000, nanosecond: 0).inTimeZone(tz)
    match (granularity) {
        case "day" => dt.format("yyyy-MM-dd")
        case "week" => dt.format("MM-dd") + " 周"
        case "month" => dt.format("yyyy-MM") + " 月"
        case _ => key
    }
}

// ---------- tags 解析 ----------

public func parseTags(tagsJson: String): ArrayList<(String, String)> {
    let out = ArrayList<(String, String)>()
    let s = trimSpace(tagsJson)
    if (s == "" || s == "{}") { return out }
    try {
        let v = JsonValue.parse(s)
        match (v) {
            case JsonValue.Map(m) =>
                for ((k, tv) in m) {
                    let vs = match (tv) {
                        case JsonValue.String(str) => str
                        case _ => tv.stringify()
                    }
                    out.add((k, vs))
                }
            case _ => ()
        }
    } catch (_) {}
    out
}

// ---------- 展示辅助 ----------

// 粒度 → 样式类（深色塔层级色）
public func levelChipClass(level: String): String {
    match (level) {
        case "10min" => "c10"
        case "30min" => "c30"
        case "1h" => "c1h"
        case "3h" => "c1h"
        case "day" => "cday"
        case "week" => "cweek"
        case "month" => "cweek"
        case _ => "c1h"
    }
}

public func levelChipText(level: String): String {
    match (level) {
        case "10min" => "10min"
        case "30min" => "30min"
        case "1h" => "1h"
        case "3h" => "3h"
        case "day" => "day"
        case "week" => "week"
        case "month" => "month"
        case _ => level
    }
}

// 标签按粒度排序序号（UI 里物化桶链顺序展示用）
public func levelIndex(level: String): Int64 {
    match (level) {
        case "10min" => 1
        case "30min" => 2
        case "1h" => 3
        case "3h" => 4
        case "day" => 5
        case "week" => 6
        case "month" => 7
        case _ => 99
    }
}

public func sortLevels(levels: ArrayList<String>): ArrayList<String> {
    let out = ArrayList<String>()
    for (l in levels) { out.add(l) }
    sort(out, by: { a, b => levelIndex(a).compare(levelIndex(b)) })
    out
}

// worklog payload 关键字段摘要（task/status/outcome）
public struct PayloadMeta {
    public let task: String
    public let status: String
    public let outcome: String

    public init(task: String, status: String, outcome: String) {
        this.task = task
        this.status = status
        this.outcome = outcome
    }
}

public func payloadMeta(payload: String): PayloadMeta {
    var task = ""
    var status = ""
    var outcome = ""
    try {
        let v = JsonValue.parse(payload)
        match (v) {
            case JsonValue.Map(m) =>
                for ((k, tv) in m) {
                    let vs = match (tv) {
                        case JsonValue.String(str) => str
                        case JsonValue.Number(num) => num.toString()
                        case _ => tv.stringify()
                    }
                    match (k) {
                        case "task" => task = vs
                        case "status" => status = vs
                        case "outcome" => outcome = vs
                        case _ => ()
                    }
                }
            case _ => ()
        }
    } catch (_) {}
    PayloadMeta(task, status, outcome)
}

public func statusClass(status: String): String {
    match (status) {
        case "完成" => "st-ok"
        case "阶段完成" => "st-phase"
        case "进行中" => "st-doing"
        case _ => ""
    }
}

public func isWorklogLike(name: String): Bool { name == "worklog" || name.contains("log") }

// ---------- UTF-8 安全截断 ----------
// 字节切片必须停在多字节字符边界（中文 3 字节/字符）：切在字符中间会产生
// 非法 UTF-8，序列化后前端解码失败（曾导致 500）。
public func clampUtf8(s: String, limit: Int64): String {
    if (limit <= 0) { return "" }
    if (s.size <= limit) { return s }
    var cut = limit
    // 若第 cut 字节是续字节（10xxxxxx），说明字符被切断：回退到字符末尾
    while (cut > 0 && (s[cut] & 0xC0u8) == 0x80u8) {
        cut -= 1
    }
    s[0..cut]
}

// ---------- payload 字段扁平化 ----------
// payload 是宽松 JSON：除 task/status/outcome 外还可能有 decisions/next 及任意自定义字段。
// 只展示前三个字段等于「记忆内容看不全」，故把全部字段扁平化后交给 UI 呈现。
public struct PayloadField {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        this.key = key
        this.value = value
    }
}

// 提取 payload 的全部字段（键升序，保证渲染稳定与可测）。
// 非 object 的 payload 返回空列表（宽松模式下的历史条目）。
public func payloadFields(payload: String): ArrayList<PayloadField> {
    let out = ArrayList<PayloadField>()
    var keys = ArrayList<String>()
    var vals = HashMap<String, String>()
    try {
        let v = JsonValue.parse(payload)
        match (v) {
            case JsonValue.Map(m) =>
                for ((k, tv) in m) {
                    keys.add(k)
                    vals[k] = jsonScalarText(tv)
                }
            case _ => ()
        }
    } catch (_) {}
    sort(keys, by: { a, b => a.compare(b) })
    for (k in keys) {
        match (vals.get(k)) {
            case Some(v) => out.add(PayloadField(k, v))
            case None => ()
        }
    }
    out
}

// JSON 标量 → 展示文本；对象/数组保留结构（紧凑 JSON）
func jsonScalarText(v: JsonValue): String {
    match (v) {
        case JsonValue.String(s) => s
        case JsonValue.Null => ""
        case _ => v.stringify()
    }
}

// ---------- 文本预览 ----------
// 折行/截断只影响「预览」，不影响「全文」：UI 必须同时拿到两者，
// 否则长记忆内容没有任何入口可看全（截断即不可读）。
public struct TextPreview {
    public let text: String      // 预览文本（单行、已归一化空白、必要时截断加省略号）
    public let full: String      // 完整文本（保留原始换行）
    public let truncated: Bool   // true = 预览被截断，UI 需给「展开/全文」入口

    public init(text: String, full: String, truncated: Bool) {
        this.text = text
        this.full = full
        this.truncated = truncated
    }
}

// 把换行/制表符/连续空白归一化为单个空格（预览单行显示用；全文不动）。
// 逐「字符」遍历并按 rune 边界推进：多字节字符整体写入，不会被切成单字节。
public func normalizeInline(s: String): String {
    let sb = StringBuilder()
    var runes = ArrayList<String>()
    for (r in s.runes()) {
        runes.add(r.toString())
    }
    var pendingSpace = false
    for (ch in runes) {
        let isSpace = ch == " " || ch == "\t" || ch == "\n" || ch == "\r"
            || ch == "\u{3000}"
        if (isSpace) {
            if (sb.size > 0) { pendingSpace = true }
            continue
        }
        if (pendingSpace) {
            sb.append(" ")
            pendingSpace = false
        }
        sb.append(ch)
    }
    sb.toString()
}

public func makePreview(raw: String, limit: Int64): TextPreview {
    let norm = normalizeInline(raw)
    if (norm.size <= limit) {
        return TextPreview(norm, raw, false)
    }
    return TextPreview(clampUtf8(norm, limit) + "…", raw, true)
}

// 条目预览：outcome 为空时回退 task（与旧行为一致，避免空预览）
public func previewOf(meta: PayloadMeta, limit!: Int64 = 150): TextPreview {
    let out = meta.outcome
    if (out == "") { return makePreview(meta.task, limit) }
    makePreview(out, limit)
}

// ---------- 类型描述预览 ----------
// 列表里描述过长会挤爆表格；但必须有看全的入口（详情弹窗），故返回值带 truncated 标记。
public func descPreview(desc: String, limit!: Int64 = 60): TextPreview {
    makePreview(desc, limit)
}

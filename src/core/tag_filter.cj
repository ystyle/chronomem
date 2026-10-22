package chronomem.core

import tsdb.*
import std.collection.*

// ===== 标签过滤条件（mem/query 的 tag 语法载体）=====
//
// 语法（首版刻意最小化）：
//   "proj=chronomem"                 单条件
//   "proj=chronomem role=user"       空格分隔 = 多条件 **AND**
//   "status=todo,done"               逗号分隔 = 同 tag 多值 **IN**（OR）
//   "status=todo,done room=r1"       IN 与 AND 组合
//
// 为什么不做 OR / 存在性 / 否定：mem/query 的调用方是 LLM 客户端，语法越少越不易误用；
// 实际查询以「固定条件 + AND」为主。真需要时再加独立参数，不把这个字符串变成小型查询语言。
//
// 关键安全约束：**解析失败必须报错，不能降级为「无过滤」**。否则一次笔误会把
// 「查某个项目」悄悄变成「查全部条目」，返回大量无关数据而调用方毫无察觉。

// 单个 tag 条件：该 tag 取值 ∈ values（多值 = IN，单值 = 等值）
public class TagFilter {
    public let tag: String
    public let values: ArrayList<String>

    public init(tag: String, values: ArrayList<String>) {
        this.tag = tag
        this.values = values
    }
}

// 解析结果：filters 为空表示不过滤（调用方未指定 tag）。
// error 非空表示语法错误，调用方必须把它变成 toolError 返回。
public class TagFilterParse {
    public let filters: ArrayList<TagFilter>
    public let error: String

    public init(filters: ArrayList<TagFilter>, error: String) {
        this.filters = filters
        this.error = error
    }

    public func isOk(): Bool { this.error == "" }
}

// 语法指引（错误信息与工具描述共用，避免两处口径漂移）
public let TAG_SYNTAX_HINT = "写法：key=value；多条件用空格分隔（AND），同 tag 多值用逗号（IN），如 \"proj=chronomem role=user\" 或 \"status=todo,done\""

// 解析 tag 过滤串。空串 = 不过滤。
public func parseTagFilters(input: String): TagFilterParse {
    let out = ArrayList<TagFilter>()
    let trimmed = trimSpaces(input)
    if (trimmed == "") {
        return TagFilterParse(out, "")
    }
    for (token in splitBySpace(trimmed)) {
        let eq = match (token.indexOf("=")) {
            case Some(i) => i
            case None =>
                return TagFilterParse(ArrayList<TagFilter>(),
                    "tag 条件缺少 '='：" + token + "。" + TAG_SYNTAX_HINT)
        }
        let tag = trimSpaces(token[0..eq])
        let valuePart = token[eq + 1..token.size]
        if (tag == "") {
            return TagFilterParse(ArrayList<TagFilter>(),
                "tag 条件的键为空：" + token + "。" + TAG_SYNTAX_HINT)
        }
        if (trimSpaces(valuePart) == "") {
            return TagFilterParse(ArrayList<TagFilter>(),
                "tag 条件的值为空：" + token + "。" + TAG_SYNTAX_HINT)
        }
        // 同 tag 多值：逗号分隔，去重保序
        let values = ArrayList<String>()
        let seen = HashSet<String>()
        for (raw in splitByComma(valuePart)) {
            let v = trimSpaces(raw)
            if (v == "") {
                return TagFilterParse(ArrayList<TagFilter>(),
                    "tag 条件的取值列表里有空项：" + token + "。" + TAG_SYNTAX_HINT)
            }
            if (!seen.contains(v)) {
                seen.add(v)
                values.add(v)
            }
        }
        out.add(TagFilter(tag, values))
    }
    TagFilterParse(out, "")
}

// 把过滤条件作用到 tsdb 查询上（条件间 AND，同 tag 多值用 filterIn 走索引归并）
public func applyTagFilters(q: Query, filters: ArrayList<TagFilter>): Query {
    var cur = q
    for (f in filters) {
        if (f.values.size == 1) {
            cur = cur.filter(f.tag, f.values[0])
        } else if (f.values.size > 1) {
            cur = cur.filterIn(f.tag, f.values.toArray())
        }
    }
    cur
}

// ---------- 字符串切分小工具（避免引入正则） ----------

func isSpaceByte(b: UInt8): Bool {
    b == 32u8 || b == 9u8 || b == 10u8 || b == 13u8
}

func trimSpaces(s: String): String {
    let bytes = s.toArray()
    var start: Int64 = 0
    var end: Int64 = bytes.size
    while (start < end && isSpaceByte(bytes[start])) {
        start += 1
    }
    while (end > start && isSpaceByte(bytes[end - 1])) {
        end -= 1
    }
    if (start == 0 && end == bytes.size) { return s }
    String.fromUtf8(bytes[start..end])
}

// 按任意空白切分，丢弃空片段
func splitBySpace(s: String): ArrayList<String> {
    let out = ArrayList<String>()
    let bytes = s.toArray()
    var i: Int64 = 0
    var start: Int64 = 0
    while (i < bytes.size) {
        if (isSpaceByte(bytes[i])) {
            if (i > start) { out.add(String.fromUtf8(bytes[start..i])) }
            i += 1
            start = i
        } else {
            i += 1
        }
    }
    if (i > start) { out.add(String.fromUtf8(bytes[start..i])) }
    out
}

// 按逗号切分（保留空片段，由调用方判断是否为空项——空项要报错而非静默丢弃）
func splitByComma(s: String): ArrayList<String> {
    let out = ArrayList<String>()
    let bytes = s.toArray()
    var start: Int64 = 0
    var i: Int64 = 0
    while (i < bytes.size) {
        if (bytes[i] == 44u8) {
            out.add(String.fromUtf8(bytes[start..i]))
            i += 1
            start = i
        } else {
            i += 1
        }
    }
    out.add(String.fromUtf8(bytes[start..bytes.size]))
    out
}

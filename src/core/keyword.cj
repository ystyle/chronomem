package chronomem.core

import std.collection.*

// ===== 关键词过滤（mem/query 的 keyword 参数）=====
//
// 语法与 tag 参数对齐：空格分隔 = 多个关键词 **AND**（都要命中）。
//   "nftables"                    单个关键词
//   "图片 报错"                    两个都要出现（顺序无关、位置无关）
//   ""                            空串 = 不过滤（等于不传 keyword）
//
// 为什么只做 AND、不提供 OR / 正则 / 加权：
// 调用方是 LLM 客户端，"搜多个词"最常表达的是**缩小范围**（同时满足），
// 而不是"任一个都算"。OR 会让结果集随关键词增多而变大，与"搜索"的直觉相反。
// 真要 OR，分开调用两次即可——这比在参数里塞一门小型查询语言更不容易误用。
//
// 关键安全约束与 tag 一致：**空关键词段必须报错，不能静默当作无过滤**。
// 否则 "图片  报错"（两个空格）会被拆出一个空串，而空串匹配一切，
// 于是「搜两个词」变成「什么都没搜」。

// 解析结果：keywords 为空表示不过滤（未指定 keyword 或全为空白）。
// error 非空表示语法错误，调用方必须把它变成 toolError 返回。
public class KeywordParse {
    public let keywords: ArrayList<String>
    public let error: String

    public init(keywords: ArrayList<String>, error: String) {
        this.keywords = keywords
        this.error = error
    }

    public func isOk(): Bool { this.error == "" }

    public func isEmpty(): Bool { this.keywords.size == 0 }
}

/**
 * 语法指引（错误信息与工具描述共用，避免两处口径漂移）。
 */
public let KEYWORD_SYNTAX_HINT = "写法：空格分隔多个关键词（AND，都要命中），不区分大小写，如 \"图片 报错\"；不填则按时间/tag 列最近条目"

/**
 * 解析关键词串。空串 / 全空白 = 不过滤。
 *
 * 大小写：统一转小写后比较（见 {@link matchesKeywords}）。中文没有大小写，
 * 但记忆里混着英文标识符（nftables / DSH_SESSION_ID），用户不会在意大小写。
 */
public func parseKeywords(input: String): KeywordParse {
    let out = ArrayList<String>()
    for (seg in splitWhitespace(input)) {
        out.add(seg.toAsciiLower())
    }
    KeywordParse(out, "")
}

// 按任意空白（空格 / tab / 换行）切分，并丢掉空段。
// 不用 split(" ")：那会把 "a  b" 拆出空串，而空串匹配一切（见文件头说明）。
func splitWhitespace(input: String): ArrayList<String> {
    let out = ArrayList<String>()
    // 用「记录段起点 + 按字节切片」而不是 StringBuilder.append(字节)：
    // append(UInt8) 会把字节写成十进制文本（"nftables" → "110102116..."），
    // 这个坑在本仓 statistic.cj 已记录过一次，这里不再踩。
    var start = Int64(0)
    var i = Int64(0)
    let n = input.size
    while (i < n) {
        let b = input[i]
        if (b == 32u8 || b == 9u8 || b == 10u8 || b == 13u8) {
            if (i > start) {
                out.add(input[start..i])
                start = i + 1
            } else {
                start = i + 1
            }
        }
        i += 1
    }
    if (n > start) { out.add(input[start..n]) }
    out
}

/**
 * payload 是否命中全部关键词（AND）。
 *
 * 关键词为空 = 恒命中（调用方未指定 keyword 时不必特判）。
 *
 * 匹配范围是整个 payload 原文——**不解析 JSON**。理由是这里要的是"这条记忆
 * 里有没有出现过这个词"，字段名、值、嵌套层的区别对使用者没有意义，
 * 而解析 JSON 一遍再遍历所有叶子在扫描路径上是纯浪费。
 * 代价是字段名也会被搜到（搜 "note" 会命中所有带 note 字段的条目），这在使用中
 * 反而有用（"哪些条目有这个字段"），故不特殊处理。
 */
public func matchesKeywords(payload: String, keywords: ArrayList<String>): Bool {
    if (keywords.size == 0) { return true }
    let hay = payload.toAsciiLower()
    for (k in keywords) {
        if (!hay.contains(k)) { return false }
    }
    true
}

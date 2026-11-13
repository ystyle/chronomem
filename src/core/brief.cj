package chronomem.core

import jsonvalue.*
import std.collection.*
import std.time.*

// ===== 紧凑简报（mem/brief 的纯逻辑层）=====
//
// 为什么需要它：`mem/query` 返回的是条目**全文**。一个项目的教训只有 17 条，
// 全文就是 1.7 万字符（≈8k tokens）；工作日志更多。于是"动手前查一眼这题踩过没"
// 的成本高到没人愿意付——**记忆写了没人读，根因就是这个成本**。
//
// brief 只输出**一行一条**（日期 + 一句话标题），同样的"知道有哪些"压到几百到
// 一两千字符。要细节再按 type/tag/keyword 走 mem/query 看全文，两级成本分开。
//
// 这条分层的意义：**先让"看"变得便宜，再谈"怎么让人想起来看"**。
// 顺序反过来（先要求必须看，但看一次 8k tokens）只会让人绕过规则。

// 标题候选字段：不同记忆类型的"一句话"落在不同字段上。
// 按此顺序取第一个非空字符串。
//
// 顺序分两段，语义不同：
//   ① 「这就是一句话」的字段（title/task/summary/name/error/rule）：优先，命中即用；
//   ② 「这是正文」的字段（event/cause/root_cause/decisions/outcome/fix/context/text/prompt）：
//      兜底，用于历史条目或没按约定写 title 的条目；
//   ③ `kind` 放最后：它是**分类标签**（"无根据断言"/"turn"），不是一句话。
//      放前面会让纠错账本每一行都显示成同一个分类名，等于什么都没说。
//
// 为什么要有第②段：真实数据里总有条目缺 title/task（早期写法不同、或写入时忘了）。
// 没有兜底时 headlineOf 会退化成把整段 JSON 塞进一行——`{"cause":"...` 这种开头
// 既占宽度又没信息量，一次能把简报的身价打回原形。
public let BRIEF_HEADLINE_FIELDS: Array<String> = [
    "title", "task", "summary", "name", "error", "rule",
    "event", "cause", "root_cause", "decisions", "outcome", "fix", "context", "text", "prompt",
    "kind"
]

// 从 payload 里取一句话标题。
//
// 规则：优先取候选字段（对象），否则把原文压成一行；最后按**字符**截断
// （不是字节——直接切字节会把汉字切成半个 UTF-8 序列，本仓踩过这个坑）。
public func headlineOf(payload: String, maxChars!: Int64 = 90): String {
    var raw = payload
    try {
        let v = JsonValue.parse(payload)
        match (v) {
            case JsonValue.Map(m) =>
                var picked = ""
                for (f in BRIEF_HEADLINE_FIELDS) {
                    match (m.get(f)) {
                        case Some(JsonValue.String(s)) =>
                            if (s != "") {
                                picked = s
                                break
                            }
                        case _ => ()
                    }
                }
                if (picked != "") {
                    raw = picked
                }
            case _ => ()
        }
    } catch (_) {
        // payload 不是 JSON（宽松模式下的历史条目）：直接用原文
    }
    oneLine(raw, maxChars)
}

// 压成一行并按字符截断。顺手把连续空白折成单个空格——条目里常有换行，
// 不折的话"一行一条"的版式立刻散架。
//
// 用**字节级**扫描而不是逐 Rune：这里只需判断 ASCII 空白，而 UTF-8 的续字节
// 全部 >= 0x80，不可能与空格混淆，所以按字节折叠是安全的，还省掉每个字符构 Rune 的开销。
public func oneLine(s: String, maxChars: Int64): String {
    let bytes = s.toArray()
    let out = ArrayList<Byte>()
    var prevSpace = false
    for (b in bytes) {
        let isSpace = b == b' ' || b == b'\t' || b == b'\n' || b == b'\r'
        if (isSpace) {
            if (!prevSpace) { out.add(b' ') }
            prevSpace = true
        } else {
            out.add(b)
            prevSpace = false
        }
    }
    let flat = String.fromUtf8(out.toArray()).trimAscii()
    let runes = flat.toRuneArray()
    if (Int64(runes.size) <= maxChars) {
        return flat
    }
    String(runes[0..maxChars]) + "…"
}

// 简报的一行：`[MM-dd] 标题`
//
// 为什么只到日不到时分秒：brief 的用途是"扫一眼有哪些事"；精确时间只在确定
// 要查某一条时才需要（去看全文即可）。少这两段，一行能省 6 个字符的固定开销。
public func briefLine(ts: Int64, payload: String, tz: TimeZone): String {
    let d = DateTime.ofEpoch(second: ts / 1000, nanosecond: (ts % 1000) * 1000000).inTimeZone(tz)
    "[" + d.format("MM-dd") + "] " + headlineOf(payload)
}

// 记忆类型在简报里的默认顺序（"最该被读"的在前）。
//
// dsh/lesson 第一：它是"别重复踩坑"的唯一载体，价值随复用次数增长；
// agent/self-correction 第二：记的是"我自己的判断偏差"（换个问题还会重犯），
//   与 lesson 的"外部环境的坑"是两回事，两者都要看才算完整；
// worklog 第三：任务账，用来回答"这个项目做到哪了"。
//
// dsh/activity **刻意不在默认里**：它是自动账本，条目量比另两者高一个量级
// （3000+ vs 100 量级），塞进"一行一条"的视图只会把真正该看的挤出去。
// 想知道某段时间的经过，正确入口是语义摘要（mem/recall mode=summary），
// 不是逐条翻账本。
public func defaultBriefTypes(): ArrayList<String> {
    let l = ArrayList<String>()
    l.add("dsh/lesson")
    l.add("agent/self-correction")
    l.add("worklog")
    l
}

// 天数 → 起始时间戳（毫秒）。days <= 0 表示不设下界（返回 0）。
public func briefFromMs(now: Int64, days: Int64): Int64 {
    if (days <= 0) {
        return 0
    }
    now - days * 24 * 60 * 60 * 1000
}

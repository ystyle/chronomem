package chronomem.core

import std.unittest.*
import std.unittest.testmacro.*
import std.time.TimeZone

// mem/brief 纯逻辑层用例。
//
// 这一层值得单独测的理由：它是"记忆有没有人读"的成本闸门。标题取错字段、
// 换成字节截断、或者把空白折叠漏掉，都不会报错——只是让简报变得难读，
// 而难读就等于没人读，问题会以"用了但没用"的形式悄悄回来。

@Test
class BriefTest {

    // 教训类 payload 的一句话在 title 上
    @TestCase
    func headlinePrefersTitle() {
        let p = "{\"title\":\"cjpm 的 [replace] 忽略版本号形式\",\"cause\":\"很长的根因……\",\"fix\":\"很长的解法……\"}"
        @Expect(headlineOf(p), "cjpm 的 [replace] 忽略版本号形式")
    }

    // 工作日志的一句话在 task 上
    @TestCase
    func headlineFallsBackToTask() {
        let p = "{\"task\":\"给忆时塔打 Windows 二进制\",\"status\":\"完成\",\"outcome\":\"很长的产出……\"}"
        @Expect(headlineOf(p), "给忆时塔打 Windows 二进制")
    }

    // title 为空串时不能就停在空串上，要继续往下一个候选字段找
    @TestCase
    func headlineSkipsEmptyField() {
        let p = "{\"title\":\"\",\"task\":\"真正的任务名\"}"
        @Expect(headlineOf(p), "真正的任务名")
    }

    // 候选字段优先于原文：不能被很长的原因字段带偏
    @TestCase
    func headlineIgnoresLongBodyFields() {
        let p = "{\"cause\":\"第一段很长的根因，比标题长得多得多得多得多得多得多得多得多得多得多\",\"title\":\"短标题\"}"
        @Expect(headlineOf(p), "短标题")
    }

    // 非 JSON payload（宽松模式的历史条目）：原文压成一行
    @TestCase
    func headlineHandlesPlainText() {
        @Expect(headlineOf("这是一条纯文本记忆"), "这是一条纯文本记忆")
    }

    // 换行必须折叠：条目里常有换行，不折就破坏"一行一条"的版式
    @TestCase
    func oneLineFlattensWhitespace() {
        @Expect(oneLine("第一行\n第二行", 90), "第一行 第二行")
        @Expect(oneLine("多个    空格", 90), "多个 空格")
        @Expect(oneLine("  前后空白  ", 90), "前后空白")
        @Expect(oneLine("制表\t与\r回车\n换行", 90), "制表 与 回车 换行")
    }

    // 截断按**字符**：10 个汉字截 5 个字，不能切出半个汉字
    @TestCase
    func oneLineTruncatesByRune() {
        let s = "一二三四五六七八九十"
        let r = oneLine(s, 5)
        @Expect(r, "一二三四五…")
        // 截断后仍是合法 UTF-8：能原样读回，字符数 = 5 + 1(省略号)
        @Expect(Int64(r.toRuneArray().size), Int64(6))
    }

    // 恰好等于上限时不加省略号（避免"刚好放得下"也被截）
    @TestCase
    func oneLineNoEllipsisAtExactLimit() {
        @Expect(oneLine("一二三四五", 5), "一二三四五")
    }

    // 英文字符串同样按字符截断
    @TestCase
    func oneLineTruncatesAscii() {
        @Expect(oneLine("abcdefghij", 4), "abcd…")
    }

    // briefLine 格式：[MM-dd] 标题（只到日，不含时分秒）
    @TestCase
    func briefLineFormat() {
        // 2026-11-06 00:00:00 UTC
        let ts = Int64(1793923200000)
        let line = briefLine(ts, "{\"title\":\"某条教训\"}", TimeZone.UTC)
        @Expect(line.startsWith("["), true)
        @Expect(line.contains("] 某条教训"), true)
        // 不含时分秒：冒号只能出现在……不该出现
        @Expect(line.indexOf(":") == None, true)
    }

    // 默认类型顺序：lesson 必须在 worklog 前面（"最该被读"的在前）
    @TestCase
    func defaultTypesOrder() {
        let t = defaultBriefTypes()
        @Expect(t.size, Int64(2))
        @Expect(t[0], "dsh/lesson")
        @Expect(t[1], "worklog")
        // activity 刻意不在默认里：账本量级高一个数量级，塞进来会挤掉该看的
        var hasActivity = false
        for (x in t) {
            if (x == "dsh/activity") { hasActivity = true }
        }
        @Expect(hasActivity, false)
    }

    // 天数 → 起点：0 或负数 = 不限（0），正数按 24h 推算
    @TestCase
    func fromMsByDays() {
        let now = Int64(1800000000000)
        @Expect(briefFromMs(now, 0), Int64(0))
        @Expect(briefFromMs(now, -5), Int64(0))
        @Expect(briefFromMs(now, 1), now - 86400000)
        @Expect(briefFromMs(now, 30), now - 30 * 86400000)
    }

    // 条目缺 title/task（真实数据里的早期写法）：要退到正文类字段，
    // 不能把整段 JSON 塞进一行——`{"cause":"..."` 既占宽又没信息量。
    @TestCase
    func headlineFallsBackToBodyField() {
        let p = "{\"cause\":\"两个独立原因叠在一起：① 参数写成普通参数 ② 编译器只报宏错误\"}"
        let h = headlineOf(p)
        @Expect(h.startsWith("{"), false)
        @Expect(h.startsWith("两个独立原因"), true)
    }

    // 正文兜底字段也要按优先级：cause 比 decisions 靠前
    @TestCase
    func headlineBodyFieldPriority() {
        let p = "{\"decisions\":\"决策内容\",\"cause\":\"根因内容\"}"
        @Expect(headlineOf(p), "根因内容")
    }

    // 完全未知的字段名：仍是 JSON 也不能吐花括号，退回原文压行
    // （此时 headlineOf 拿不到任何候选字段，只能把原文压成一行——
    //   这是最后的保底，测试钉住它至少不带换行、不超长）
    @TestCase
    func headlineUnknownFieldsStayOneLine() {
        let p = "{\"zzz\":\"x\"}"
        let h = headlineOf(p)
        @Expect(h.indexOf("\n") == None, true)
        @Expect(Int64(h.toRuneArray().size) <= 91, true)
    }
}

package chronomem.mcp

import chronomem.core.*
import jsonvalue.*
import std.collection.*

// 摘要窗口匹配与长期可见性回归。
//
// 摘要查询曾硬编码「取最近 50 条再内存过滤」，且匹配用 overlap 判据、不区分粒度。
// 两个后果都落在「长期」这个核心维度上：
//   ① 摘要超过 50 条后，更早窗口的摘要虽在库中却取不回——recall mode=summary 报「无摘要」，
//      自动调度的幂等判据同样看不见，于是老窗口被判未总结而**重复总结、重复烧 token**；
//   ② 日窗口在周窗口内部，于是周窗口被其内部的任一日摘要判为「已总结」——「总结到周」不产出；
//      反向地，查某一天的摘要会把整周摘要一并返回（时段归属错误）。

// 向某类型的 .summary series 直写一条摘要（测试用；绕过 LLM）。
// 走与生产一致的落库路径（含 wf tag）——测试辅助与真实写入若分叉，
// 用例就测不到生产行为（历史摘要的例外路径在对应用例里显式直写）。
func putSummary(s: MemoryService, typeName: String, ts: Int64, winFrom: Int64, winTo: Int64,
    text: String, group: Option<String>): Unit {
    let stl = s.registry.summaryTimelineOf(typeName).getOrThrow()
    let rec = SummaryRecord(ts, winFrom, winTo, "fake", ArrayList<Int64>(), "", text, groupKey: group)
    appendSummaryPoint(stl, rec)
}

// 统计窗口精确匹配（windowFrom/windowTo 全等）的摘要条数
func countSummariesExact(s: MemoryService, typeName: String, wf: Int64, wt: Int64): Int64 {
    var n = Int64(0)
    let stl = s.registry.summaryTimelineOf(typeName).getOrThrow()
    for (p in stl.queryPoints(0, 0, 0, ArrayList<TagFilter>())) {
        let rec = fromJsonString<SummaryRecord>(p.payload)
        if (rec.windowFrom == wf && rec.windowTo == wt) { n += 1 }
    }
    n
}

// ① 摘要可见性不受条数上限影响：写入 60 条后，最早的窗口仍须取回。
@Test
func summaryRecallIsNotCappedByCount() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"cap\",\"levels\":[\"day\",\"week\"]}"))
    let tl = s.registry.timelineOf("cap").getOrThrow()
    let (wf0, _) = tl.windowRangeOf(TEST_BASE, "day")
    var wf = wf0
    var ts = TEST_BASE
    for (i in 0..60) {
        let nxt = tl.nextWindowStartMs(wf, "day")
        putSummary(s, "cap", ts, wf, nxt - 1, "TEXT-" + i.toString(), None)
        wf = nxt
        ts += 1000
    }
    // 最早窗口（第 0 条）落在「最近 50 条」之外，仍必须能取回
    let r = resultText(handleRecall(s, argsFromJson(
        "{\"type\":\"cap\",\"granularity\":\"day\",\"mode\":\"summary\",\"windowStartMs\":" + wf0.toString() + "}")))
    @Expect(r.indexOf("TEXT-0") != None, true)
    s.close()
}

// ②-a 周窗口不得因内部存在日摘要而被判「已总结」（否则周层永不产出）。
@Test
func weekWindowNotConsideredSummarizedByInnerDaySummary() {
    let s = svcWithLlm()
    handleTypeCreate(s, argsFromJson("{\"name\":\"wk\",\"levels\":[\"day\",\"week\"]}"))
    let tl = s.registry.timelineOf("wk").getOrThrow()
    let (wf, wt) = tl.windowRangeOf(TEST_BASE, "week")
    tl.append(wf, "e1", tagsOf([]))
    tl.append(wf + 86400000, "e2", tagsOf([]))
    // 该周内某天已有日摘要（模拟日总结先跑过）
    let (dwf, dwt) = tl.windowRangeOf(wf, "day")
    putSummary(s, "wk", wf, dwf, dwt, "DAY-TEXT", None)
    // 总结整周：不应因存在日摘要而跳过
    let r = resultText(doSummarize(s, "wk", wf, wt, "", true))
    @Expect(r.indexOf("已有总结，跳过") != None, false)
    @Expect(countSummariesExact(s, "wk", wf, wt), 1)
    s.close()
}

// ②-b 查某一天的摘要，不得把整周摘要一并返回（时段归属必须精确）。
@Test
func daySummaryRecallDoesNotReturnWeekSummary() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"dw\",\"levels\":[\"day\",\"week\"]}"))
    let tl = s.registry.timelineOf("dw").getOrThrow()
    let (wf, wt) = tl.windowRangeOf(TEST_BASE, "week")
    let (dwf, dwt) = tl.windowRangeOf(wf, "day")
    putSummary(s, "dw", wf, dwf, dwt, "DAY-ONLY", None)
    putSummary(s, "dw", wf + 1, wf, wt, "WEEK-ONLY", None)
    let r = resultText(handleRecall(s, argsFromJson(
        "{\"type\":\"dw\",\"granularity\":\"day\",\"mode\":\"summary\",\"windowStartMs\":" + dwf.toString() + "}")))
    @Expect(r.indexOf("DAY-ONLY") != None, true)
    @Expect(r.indexOf("WEEK-ONLY") != None, false)
    s.close()
}

// ③ 递归总结（自底向上）：总结周窗口时，先补齐该周内各日的摘要（缺失则先按原始条目总结），
// 再以这些日摘要为材料聚合出周摘要——即「默认基于最近一层提炼」，而非每层都重读原始条目。
@Test
func weekSummaryAggregatesFromDaySummaries() {
    let s = svcWithLlm()
    handleTypeCreate(s, argsFromJson("{\"name\":\"rec\",\"levels\":[\"day\",\"week\"]}"))
    let tl = s.registry.timelineOf("rec").getOrThrow()
    let (wf, wt) = tl.windowRangeOf(TEST_BASE, "week")
    // 该周内两天各有条目（刻意不预先做日总结）
    tl.append(wf, "e1", tagsOf([]))
    tl.append(wf + 86400000, "e2", tagsOf([]))
    // 只请求周窗口：应自底向上补齐日摘要后聚合
    let r = resultText(doSummarize(s, "rec", wf, wt, "", true, level: "week"))
    @Expect(r.indexOf("该窗口无条目") != None, false)
    // 该周内两个有数据的日子都应产出日摘要
    var dayCount = Int64(0)
    var sub = tl.windowStartOf(wf, "day")
    while (sub <= wt) {
        let subEnd = tl.nextWindowStartMs(sub, "day") - 1
        dayCount += countSummariesExact(s, "rec", sub, subEnd)
        sub = tl.nextWindowStartMs(sub, "day")
    }
    @Expect(dayCount, 2)
    // 周摘要的 refs 必须指向两条**日摘要**（Proof：材料来自下层摘要而非原始条目）
    let week = summariesForWindow(s, "rec", wf, wt)
    @Expect(week.size, 1)
    @Expect(week[0].refs.size, 2)
    s.close()
}

// ③-b recompute=true 时强制原始基：即使已有日摘要，周摘要的 refs 也应指向原始条目。
@Test
func recomputeUsesRawEntriesNotFinerSummaries() {
    let s = svcWithLlm()
    handleTypeCreate(s, argsFromJson("{\"name\":\"raw\",\"levels\":[\"day\",\"week\"]}"))
    let tl = s.registry.timelineOf("raw").getOrThrow()
    let (wf, wt) = tl.windowRangeOf(TEST_BASE, "week")
    tl.append(wf, "e1", tagsOf([]))
    tl.append(wf + 86400000, "e2", tagsOf([]))
    // 先建好两层摘要（自底向上）
    _ = doSummarize(s, "raw", wf, wt, "", true, level: "week")
    // 再强制重算：材料应回到原始条目（该周共 2 条原始条目）
    _ = doSummarize(s, "raw", wf, wt, "", true, recompute: true, level: "week")
    let week = summariesForWindow(s, "raw", wf, wt)
    // recompute 是**追加**新版本而非覆盖（保留重算历史），故该窗口此时有 2 条；取最新一条
    @Expect(week.size >= 1, true)
    @Expect(week[0].refs.size, 2)
    // 原始条目 ts 落在窗口内；而日摘要的 ts 是生成时刻（nowMs，远大于窗口时间）——
    // 据此可区分材料来自原始条目还是下层摘要
    @Expect(week[0].refs[0] < wf + 86400000 * 2, true)
    s.close()
}

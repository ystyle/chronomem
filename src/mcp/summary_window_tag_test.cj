package chronomem.mcp

import chronomem.core.*
import jsonvalue.*
import std.collection.*

// 摘要窗口检索下推（wf tag）。
//
// 摘要点的 ts 是**生成时刻**而非窗口时间，所以按窗口取摘要无法用 tsdb 的 range 预筛——
// 早期实现只能把该类型的**全部摘要**分页遍历一遍再内存比 windowFrom/windowTo。
// 摘要量随运营线性增长（每日 × 分组数 + 每周一条），这条全量遍历同时压在
// 「语义回顾」与「自动调度的幂等判据」两条路径上。
//
// 修法：落库时把窗口起点写成 tag（`wf`），读时 `filter("wf", ...)` 走倒排索引，
// 只取该窗口起点下的少量摘要，再内存精确比对 windowTo 与 groupKey。
// 历史摘要没有该 tag，故保留「tag 路径无命中 → 退回全量遍历」的兜底。

// 读一条摘要的 wf tag（诊断用：确认落库确实带上了窗口起点）
func summaryHasWindowTag(s: MemoryService, typeName: String, ts: Int64): Bool {
    let stl = s.registry.summaryTimelineOf(typeName).getOrThrow()
    for (p in stl.queryPoints(0, 0, 0, None)) {
        if (p.ts == ts) {
            return p.tagsMap().get("wf").isSome()
        }
    }
    false
}

// ① 新写入的摘要必须带 wf tag（否则下推失效，仍退化为全量遍历）
@Test
func summaryAppendWritesWindowTag() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"tg\",\"levels\":[\"day\",\"week\"]}"))
    let tl = s.registry.timelineOf("tg").getOrThrow()
    let (wf, wt) = tl.windowRangeOf(TEST_BASE, "day")
    putSummary(s, "tg", wf, wf, wt, "TEXT", None)
    @Expect(summaryHasWindowTag(s, "tg", wf), true)
    s.close()
}

// ② 窗口精确匹配语义不因下推改变：同窗口多分组全取回，异窗口一律不混入
@Test
func summaryWindowLookupStaysExactAcrossGroups() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"ex\",\"levels\":[\"day\",\"week\"]}"))
    let tl = s.registry.timelineOf("ex").getOrThrow()
    let (wf, wt) = tl.windowRangeOf(TEST_BASE, "day")
    let (wf2, wt2) = tl.windowRangeOf(TEST_BASE + 86400000, "day")
    putSummary(s, "ex", wf, wf, wt, "A", Some("g1"))
    putSummary(s, "ex", wf + 1, wf, wt, "B", Some("g2"))
    putSummary(s, "ex", wf + 2, wf, wt, "C", None)
    // 同起点不同终点（不规则窗口）不得混入
    putSummary(s, "ex", wf + 3, wf, wt + 1, "D", Some("g3"))
    // 另一个窗口
    putSummary(s, "ex", wf2, wf2, wt2, "E", Some("g1"))
    let got = summariesForWindow(s, "ex", wf, wt)
    @Expect(got.size, 3)
    var texts = HashSet<String>()
    for (r in got) { texts.add(r.text) }
    @Expect(texts.contains("A"), true)
    @Expect(texts.contains("B"), true)
    @Expect(texts.contains("C"), true)
    @Expect(texts.contains("D"), false)
    @Expect(texts.contains("E"), false)
    s.close()
}

// ③ 历史摘要（无 wf tag）仍必须可见——兜底路径不能被下推优化挤掉
@Test
func legacyUntaggedSummaryStillVisible() {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"lg\",\"levels\":[\"day\",\"week\"]}"))
    let tl = s.registry.timelineOf("lg").getOrThrow()
    let (wf, wt) = tl.windowRangeOf(TEST_BASE, "day")
    // 直写一条**不带任何 tag** 的摘要，模拟升级前的存量
    let stl = s.registry.summaryTimelineOf("lg").getOrThrow()
    let rec = SummaryRecord(wf, wf, wt, "fake", ArrayList<Int64>(), "", "LEGACY")
    stl.append(wf, toJsonString(rec), HashMap<String, String>())
    let got = summariesForWindow(s, "lg", wf, wt)
    @Expect(got.size, 1)
    @Expect(got[0].text, "LEGACY")
    s.close()
}

// ④ 调度幂等判据：下推后仍能正确判定「该窗口该分组已总结」与「未总结」
@Test
func schedulerIdempotencySeesTaggedSummaries() {
    let s = svcWithLlm()
    handleTypeCreate(s, argsFromJson("{\"name\":\"idem\",\"levels\":[\"day\"],\"summary_group_by\":[\"proj\"]}"))
    handleAppend(s, argsFromJson("{\"type\":\"idem\",\"payload\":{\"t\":\"x\"},\"ts\":" + TEST_BASE.toString() + ",\"tags\":{\"proj\":\"p1\"}}"))
    let tl = s.registry.timelineOf("idem").getOrThrow()
    let (wf, wt) = tl.windowRangeOf(TEST_BASE, "day")
    // 先确认未总结
    @Expect(latestSummaryForWindow(s, "idem", wf, wt, Some("p1")).isNone(), true)
    _ = doSummarize(s, "idem", wf, wt, "", true)
    // 已总结：必须能被看见（否则重复总结烧 token）
    match (latestSummaryForWindow(s, "idem", wf, wt, Some("p1"))) {
        case Some(rec) => @Expect(rec.windowFrom, wf)
        case None => @Fail("tagged summary should be visible to idempotency check")
    }
    s.close()
}

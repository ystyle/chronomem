package chronomem.ui

import chronomem.mcp.MemoryService
import chronomem.core.*
import std.collection.{ArrayList, HashMap}

// UI 数据访问层（ui_api）测试：类型 CRUD / 追加校验 / 查询过滤 / 桶计数与下钻 / 总结读取 / 删除守卫。
// 全部基于 MemoryService.openFile（文件型临时库、零 LLM）。

func uiTestSvcWithWorklog(points: Array<(Int64, String, String)>): MemoryService {
    let svc = MemoryService.openFile(freshTestDir())
    let levels = ArrayList<String>()
    levels.add("day")
    levels.add("week")
    let groupBy = ArrayList<String>()
    groupBy.add("proj")
    let r = uiCreateType(svc, TypeMeta("worklog", "测试类型", None, levels, None, true, None, 1, summaryGroupBy: Some(groupBy)))
    if (!r.ok) { throw Exception("setup failed: ${r.message}") }
    for ((ts, payload, tags) in points) {
        let tagMap = HashMap<String, String>()
        for ((k, v) in parseTags(tags)) { tagMap.add(k, v) }
        svc.registry.timelineOf("worklog").getOrThrow().append(ts, payload, tagMap)
    }
    svc
}

@Test
func uiApiCreateAndListTypes() {
    let svc = MemoryService.openFile(freshTestDir())
    let levels = ArrayList<String>()
    levels.add("day")
    let r = uiCreateType(svc, TypeMeta("t1", "描述", None, levels, None, false, None, 1))
    @Expect(r.ok, true)
    @Expect(uiListTypes(svc).size, Int64(1))
    @Expect(uiGetType(svc, "t1").getOrThrow().name, "t1")
    // 重复创建被拒
    let dup = uiCreateType(svc, TypeMeta("t1", "d", None, levels, None, false, None, 1))
    @Expect(dup.ok, false)
    svc.close()
}

@Test
func uiApiValidateTypeName() {
    @Expect(isValidTypeName("worklog"), true)
    @Expect(isValidTypeName("proj/decisions"), true)
    @Expect(isValidTypeName("tool-errors_v2"), true)
    @Expect(isValidTypeName(""), false)
    @Expect(isValidTypeName("../x"), false)
    @Expect(isValidTypeName("/abs"), false)
    @Expect(isValidTypeName("a b"), false)
    @Expect(isValidTypeName("a+b"), false)
}

@Test
func uiApiAppendAndQuery() {
    let svc = MemoryService.openFile(freshTestDir())
    let levels = ArrayList<String>()
    levels.add("day")
    uiCreateType(svc, TypeMeta("worklog", "d", None, levels, None, false, None, 1))
    let tags = ArrayList<(String, String)>()
    tags.add(("proj", "ct"))
    tags.add(("branch", "main"))
    let r = uiAppend(svc, "worklog", 1788000000000, "{\"task\":\"T\"}", tags)
    @Expect(r.ok, true)
    let points = uiQuery(svc, "worklog", 0, 0, 20, "").points
    @Expect(points.size, Int64(1))
    let meta = payloadMeta(points[0].payload)
    @Expect(meta.task, "T")
    @Expect(parseTags(points[0].tags).size, Int64(2))
    // tag 过滤命中/未命中
    @Expect(uiQuery(svc, "worklog", 0, 0, 20, "proj=ct").points.size, Int64(1))
    @Expect(uiQuery(svc, "worklog", 0, 0, 20, "proj=other").points.size, Int64(0))
    svc.close()
}

// UI 的 tag 过滤必须与 MCP 同语法：空格 AND、逗号 IN。
// 此前页面自己按第一个 '=' 切一刀，把 "proj=ct kind=x" 当成 proj == "ct kind=x"，
// 于是多条件恒空——用户看到的"语法写了不生效"。
@Test
func uiApiQueryMultiConditionSameAsMcp() {
    let svc = MemoryService.openFile(freshTestDir())
    let levels = ArrayList<String>()
    levels.add("day")
    uiCreateType(svc, TypeMeta("chat", "d", None, levels, None, false, None, 1))
    // 三种 kind，两种 proj
    for ((ts, kind, proj) in [
        (1788000000000, "user", "im"),
        (1788000001000, "say", "im"),
        (1788000002000, "tool", "im"),
        (1788000003000, "user", "other"),
    ]) {
        let tags = ArrayList<(String, String)>()
        tags.add(("kind", kind))
        tags.add(("proj", proj))
        let r = uiAppend(svc, "chat", ts, "{\"task\":\"T\"}", tags)
        @Expect(r.ok, true)
    }
    // 单条件
    @Expect(uiQuery(svc, "chat", 0, 0, 20, "kind=user").points.size, Int64(2))
    // 空格 AND
    @Expect(uiQuery(svc, "chat", 0, 0, 20, "proj=im kind=user").points.size, Int64(1))
    // 逗号 IN（同 tag 多值）
    @Expect(uiQuery(svc, "chat", 0, 0, 20, "kind=user,say").points.size, Int64(3))
    // IN 与 AND 组合
    @Expect(uiQuery(svc, "chat", 0, 0, 20, "kind=user,say proj=im").points.size, Int64(2))
    // 语法错误必须报错，不能静默返回空列表
    let bad = uiQuery(svc, "chat", 0, 0, 20, "kind")
    @Expect(bad.isOk(), false)
    @Expect(bad.points.size, Int64(0))
    let bad2 = uiQuery(svc, "chat", 0, 0, 20, "kind=user,")
    @Expect(bad2.isOk(), false)
    svc.close()
}

@Test
func uiApiAppendBadPayloadRejected() {
    let svc = MemoryService.openFile(freshTestDir())
    let levels = ArrayList<String>()
    levels.add("day")
    uiCreateType(svc, TypeMeta("worklog", "d", None, levels, None, false, None, 1))
    let r = uiAppend(svc, "worklog", 0, "not-json", ArrayList<(String, String)>())
    @Expect(r.ok, false)
    @Expect(r.message.contains("JSON"), true)
    svc.close()
}

@Test
func uiApiAppendUnknownTypeRejected() {
    let svc = MemoryService.openFile(freshTestDir())
    let r = uiAppend(svc, "nope", 0, "{}", ArrayList<(String, String)>())
    @Expect(r.ok, false)
    @Expect(r.message.contains("不存在"), true)
    svc.close()
}

@Test
func uiApiTypeInfoBucketCounts() {
    let svc = uiTestSvcWithWorklog([
        (1787932800000, "{\"task\":\"c\"}", "{\"proj\":\"y\"}"),
        (1788019200000, "{\"task\":\"a\"}", "{\"proj\":\"x\"}"),
        (1788022800000, "{\"task\":\"b\"}", "{}"),
    ])
    // materialize 按锚点物化（历史窗口需显式锚点：调度器只在窗口闭合时物化当窗）
    let tl0 = svc.registry.timelineOf("worklog").getOrThrow()
    tl0.materialize(1787932800000, "测试")
    tl0.materialize(1788019200000, "测试")
    let info = uiTypeInfo(svc, "worklog").getOrThrow()
    @Expect(info.entries, Int64(3))
    @Expect(info.bucketCounts.size, Int64(2))
    @Expect(info.bucketCounts[0][1] >= Int64(1), true)
    @Expect(info.summaries, Int64(0))
    svc.close()
}

@Test
func uiApiBucketsAndDrill() {
    let d1 = 1788019200000  // 2026-08-29 00:00 北京（已闭合）
    let d2 = 1787932800000  // 2026-08-28 00:00 北京（已闭合）
    // tsdb append 严格时间序：按升序写入
    let svc = uiTestSvcWithWorklog([
        (d2, "{\"task\":\"c\"}", "{}"),
        (d1, "{\"task\":\"a\"}", "{}"),
        (d1 + 100000, "{\"task\":\"b\"}", "{}"),
    ])
    let tl2 = svc.registry.timelineOf("worklog").getOrThrow()
    tl2.materialize(d2, "测试")
    tl2.materialize(d1, "测试")
    let buckets = uiListBuckets(svc, "worklog", "day")
    @Expect(buckets.size, Int64(2))
    // 最早的桶（08-28）1 条，次桶（08-29）2 条
    @Expect(uiDrillDown(svc, "worklog", "day", buckets[0].bucketKey).size, Int64(1))
    @Expect(uiDrillDown(svc, "worklog", "day", buckets[1].bucketKey).size, Int64(2))
    // 轻量 metas：条数一致（refsCount），且 bucketKey/summary 对齐（防 GC 堆膨胀的列表通道）
    let metas = uiListBucketMetas(svc, "worklog", "day")
    @Expect(metas.size, Int64(2))
    @Expect(metas[0].bucketKey, buckets[0].bucketKey)
    @Expect(metas[0].refsCount, Int64(1))
    @Expect(metas[1].bucketKey, buckets[1].bucketKey)
    @Expect(metas[1].refsCount, Int64(2))
    svc.close()
}

@Test
func uiApiSummariesRead() {
    let svc = uiTestSvcWithWorklog([])
    // 直接向 summary series 写一条 SummaryRecord（模拟总结已落库）
    let rec = SummaryRecord(100, 1788019200000, 1788105600000, "fake-model",
        ArrayList<Int64>(), "", "决策：\n- 分组维度可配置\n\n结论：\n- 完成\n\n待办：\n- 无\n\n状态变更：\n- 状态：完成\n\n关键词：\n- 测试", groupKey: Some("x"))
    svc.registry.summaryTimelineOf("worklog").getOrThrow().append(rec.ts, toJsonString(rec), HashMap<String, String>())
    let items = uiSummaries(svc, "worklog", 10)
    @Expect(items.size, Int64(1))
    @Expect(items[0].groupKey.getOrThrow(), "x")
    @Expect(items[0].model, "fake-model")
    @Expect(parseSummarySections(items[0].text).decisions[0], "分组维度可配置")
    svc.close()
}

@Test
func uiApiSummariesWindowFilter() {
    let svc = uiTestSvcWithWorklog([])
    let rec1 = SummaryRecord(100, 1788019200000, 1788105600000, "m",
        ArrayList<Int64>(), "", "决策：\n- a", groupKey: None)
    let rec2 = SummaryRecord(200, 1787822400000, 1787908800000, "m",
        ArrayList<Int64>(), "", "决策：\n- b", groupKey: None)
    let stl = svc.registry.summaryTimelineOf("worklog").getOrThrow()
    stl.append(rec1.ts, toJsonString(rec1), HashMap<String, String>())
    stl.append(rec2.ts, toJsonString(rec2), HashMap<String, String>())
    // 查 08-30 日窗口内的总结（winFrom/winTo 覆盖）
    let inWin = uiSummariesOfWindow(svc, "worklog", 1788019200000, 1788105600000)
    @Expect(inWin.size, Int64(1))
    @Expect(inWin[0].ts, Int64(100))
    svc.close()
}

@Test
func uiApiTriggerSummarizeNoLlm() {
    let svc = uiTestSvcWithWorklog([(1788019200000, "{\"task\":\"a\"}", "{}")])
    let r = uiTriggerSummarize(svc, "worklog", 1788019200000, 1788105600000, "")
    @Expect(r.ok, false)
    @Expect(r.message.contains("LLM"), true)
    svc.close()
}

@Test
func uiApiTruncateAndDeleteGuard() {
    let svc = uiTestSvcWithWorklog([(1788019200000, "{\"task\":\"a\"}", "{}")])
    // 清空前删除被守卫拒绝
    let del = uiDeleteType(svc, "worklog")
    @Expect(del.ok, false)
    @Expect(del.message.contains("守卫"), true)
    // 清空后再删
    let tr = uiTruncate(svc, "worklog")
    @Expect(tr.ok, true)
    @Expect(uiCount(svc, "worklog"), Int64(0))
    let del2 = uiDeleteType(svc, "worklog")
    @Expect(del2.ok, true)
    @Expect(uiListTypes(svc).size, Int64(0))
    svc.close()
}

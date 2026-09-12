package chronomem.core

import tsdb.*
import std.collection.*
import std.env.getProcessId

// 记忆类型注册表测试：创建/查询/持久化恢复/校验（类型名 + 粒度链）。

@Test
func registry_createAndList() {
    let store = fileStore()
    let reg = MemoryTypeRegistry(store)
    reg.create(testMeta("worklog", dayWeekLevels()))
    reg.create(testMeta("proj/decisions", Timeline.defaultLevels()))

    @Expect(reg.has("worklog"), true)
    @Expect(reg.has("proj/decisions"), true)
    @Expect(reg.has("nope"), false)
    @Expect(reg.list().size, Int64(2))
    @Expect(MemoryTypeRegistry.summarySeriesOf("worklog"), "worklog.summary")

    // 初始 0 条 → append 后 1 条
    @Expect(reg.countEntries("worklog"), Int64(0))
    match (reg.timelineOf("worklog")) {
        case Some(tl) => tl.append(TEST_BASE, "e1", HashMap<String, String>())
        case None => @Fail("timelineOf 返回 None")
    }
    @Expect(reg.countEntries("worklog"), Int64(1))
    // summary series 句柄可用
    match (reg.summaryTimelineOf("worklog")) {
        case Some(tl) => @Expect(tl.seriesName(), "worklog.summary")
        case None => @Fail("summaryTimelineOf 返回 None")
    }
    store.close()
}

@Test
func registry_persistAndReload() {
    let path = "/tmp/chronomem_registry_test_" + getProcessId().toString()
    let store = TimelineStore.open(path)
    let reg = MemoryTypeRegistry(store)
    let meta = testMeta("worklog", dayWeekLevels())
    reg.create(meta)
    // 写一条数据（后续验证重开后物化桶链）
    match (reg.timelineOf("worklog")) {
        case Some(tl) => tl.append(TEST_BASE, "{\"task\":\"x\"}", HashMap<String, String>())
        case None => @Fail("timelineOf None")
    }
    store.close()

    // 重开 → 注册表从 __meta 恢复
    let store2 = TimelineStore.open(path)
    let reg2 = MemoryTypeRegistry(store2)
    @Expect(reg2.has("worklog"), true)
    match (reg2.get("worklog")) {
        case Some(m) =>
            @Expect(m.levels.size, Int64(2))
            @Expect(m.levels[0], "day")
            @Expect(m.description, "desc worklog")
        case None => @Fail("重开后类型丢失")
    }
    // 回归：重启后系列注册必须恢复（seriesLabels 内存态），
    // 否则物化桶链只覆盖启动时段注册的类型——旧类型永远不物化。
    match (reg2.timelineOf("worklog")) {
        case Some(tl) =>
            tl.materialize(TEST_BASE, "记忆类型 worklog")
            let metas = tl.listBucketMetas("day", None, None)
            @Expect(metas.size > 0, true)
            let dKey = tl.windowKeyOf(TEST_BASE, "day")
            var found = false
            for (m in metas) {
                if (m.bucketKey == dKey) { found = true }
            }
            @Expect(found, true)
        case None => @Fail("重开后 timelineOf None")
    }
    store2.close()
}

@Test
func registry_duplicateCreateRejected() {
    let store = fileStore()
    let reg = MemoryTypeRegistry(store)
    reg.create(testMeta("worklog", dayWeekLevels()))
    var threw = false
    try { reg.create(testMeta("worklog", dayWeekLevels())) } catch (_) { threw = true }
    @Expect(threw, true)
    store.close()
}

@Test
func registry_rejectsInvalidTypeName() {
    let store = fileStore()
    let reg = MemoryTypeRegistry(store)
    var threw = false
    try { reg.create(testMeta("../evil", dayWeekLevels())) } catch (_) { threw = true }
    @Expect(threw, true)
    threw = false
    try { reg.create(testMeta("/abs", dayWeekLevels())) } catch (_) { threw = true }
    @Expect(threw, true)
    threw = false
    try { reg.create(testMeta("bad name", dayWeekLevels())) } catch (_) { threw = true }
    @Expect(threw, true)
    threw = false
    try { reg.create(testMeta("", dayWeekLevels())) } catch (_) { threw = true }
    @Expect(threw, true)
    store.close()
}

@Test
func registry_rejectsInvalidLevels() {
    let store = fileStore()
    let reg = MemoryTypeRegistry(store)
    let bad = ArrayList<String>()
    bad.add("5min")
    var threw = false
    try { reg.create(testMeta("t", bad)) } catch (_) { threw = true }
    @Expect(threw, true)
    store.close()
}

@Test
func registry_rejectsInvalidSummaryGroupBy() {
    let store = fileStore()
    let reg = MemoryTypeRegistry(store)

    // 超过 2 维 → 拒绝
    let three = ArrayList<String>()
    three.add("proj")
    three.add("branch")
    three.add("phase")
    var threw = false
    try {
        reg.create(TypeMeta("t1", "", None, dayWeekLevels(), None, false, None, TEST_BASE,
            summaryGroupBy: Some(three)))
    } catch (_) { threw = true }
    @Expect(threw, true)

    // 空数组 → 拒绝
    let empty = ArrayList<String>()
    threw = false
    try {
        reg.create(TypeMeta("t2", "", None, dayWeekLevels(), None, false, None, TEST_BASE,
            summaryGroupBy: Some(empty)))
    } catch (_) { threw = true }
    @Expect(threw, true)

    // 重复维度 → 拒绝
    let dup = ArrayList<String>()
    dup.add("proj")
    dup.add("proj")
    threw = false
    try {
        reg.create(TypeMeta("t3", "", None, dayWeekLevels(), None, false, None, TEST_BASE,
            summaryGroupBy: Some(dup)))
    } catch (_) { threw = true }
    @Expect(threw, true)

    // 非法 tag 键（含空格）→ 拒绝
    let badKey = ArrayList<String>()
    badKey.add("bad key")
    threw = false
    try {
        reg.create(TypeMeta("t4", "", None, dayWeekLevels(), None, false, None, TEST_BASE,
            summaryGroupBy: Some(badKey)))
    } catch (_) { threw = true }
    @Expect(threw, true)

    // 合法 2 维 → 通过
    let ok = ArrayList<String>()
    ok.add("proj")
    ok.add("branch")
    reg.create(TypeMeta("t5", "", None, dayWeekLevels(), None, false, None, TEST_BASE,
        summaryGroupBy: Some(ok)))
    @Expect(reg.has("t5"), true)
    store.close()
}

// updateMeta 的写前校验：与 create 对齐（此前只校验 summary 配置，非法 levels / 类型名会被静默落库）。
@Test
func registry_updateMetaValidatesBeforeWrite() {
    let store = fileStore()
    let reg = MemoryTypeRegistry(store)
    reg.create(testMeta("worklog", dayWeekLevels()))

    // 非法粒度（5min 不是合法档位）→ 拒绝
    let badLevels = ArrayList<String>()
    badLevels.add("5min")
    var threw = false
    try {
        reg.updateMeta(testMeta("worklog", badLevels))
    } catch (e: Exception) { threw = true }
    @Expect(threw, true)

    // 非法类型名（路径穿越）→ 拒绝
    threw = false
    try {
        reg.updateMeta(testMeta("../evil", dayWeekLevels()))
    } catch (e: Exception) { threw = true }
    @Expect(threw, true)

    // 合法变更（描述 + 总结配置）→ 通过，且 levels 保持不变
    let upgraded = TypeMeta("worklog", "新描述", Some("docs"), dayWeekLevels(), None, true,
        Some(dayWeekLevels()), TEST_BASE)
    reg.updateMeta(upgraded)
    let m = reg.get("worklog").getOrThrow()
    @Expect(m.description, "新描述")
    @Expect(m.autoSummarize, true)
    @Expect(m.levels[0], "day")
    match (m.summaryLevels) {
        case Some(ls) => @Expect(ls.size, Int64(2))
        case None => @Fail("summaryLevels 未写入")
    }
    store.close()
}

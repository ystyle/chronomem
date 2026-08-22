package chronomem.core

import tsdb.*
import std.collection.*
import std.env.getProcessId

// 记忆类型注册表测试：创建/查询/持久化恢复/校验（类型名 + 粒度链）。

@Test
func registry_createAndList() {
    let store = inMemStore()
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
    reg.create(testMeta("worklog", dayWeekLevels()))
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
    store2.close()
}

@Test
func registry_duplicateCreateRejected() {
    let store = inMemStore()
    let reg = MemoryTypeRegistry(store)
    reg.create(testMeta("worklog", dayWeekLevels()))
    var threw = false
    try { reg.create(testMeta("worklog", dayWeekLevels())) } catch (_) { threw = true }
    @Expect(threw, true)
    store.close()
}

@Test
func registry_rejectsInvalidTypeName() {
    let store = inMemStore()
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
    let store = inMemStore()
    let reg = MemoryTypeRegistry(store)
    let bad = ArrayList<String>()
    bad.add("5min")
    var threw = false
    try { reg.create(testMeta("t", bad)) } catch (_) { threw = true }
    @Expect(threw, true)
    store.close()
}

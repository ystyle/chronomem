package chronomem.core

import tsdb.*
import std.collection.*

// 通用分层时间线测试：append/query/物化桶链/drillDown 精确回想/桶发现/校验。

@Test
func timeline_appendQueryCountAndTagFilter() {
    let store = inMemStore()
    let tl = store.timeline("t1", "测试", Timeline.defaultLevels())
    tl.append(TEST_BASE, "a", tagsOf([("role", "user")]))
    tl.append(TEST_BASE + 1000, "b", tagsOf([("role", "assistant")]))
    tl.append(TEST_BASE + 2000, "c", tagsOf([("role", "user")]))

    @Expect(tl.count(), Int64(3))
    // 全部（最新在前）
    let all = tl.queryPoints(0, 0, 0, None)
    @Expect(all.size, Int64(3))
    @Expect(all[0].payload, "c")
    // 按 tag 过滤
    let users = tl.queryPoints(0, 0, 0, Some(("role", "user")))
    @Expect(users.size, Int64(2))
    // limit
    let two = tl.queryPoints(0, 0, 2, None)
    @Expect(two.size, Int64(2))
    @Expect(two[0].payload, "c")
    @Expect(two[1].payload, "b")
    // 时间范围
    let ranged = tl.queryPoints(TEST_BASE + 1, TEST_BASE + 1000, 0, None)
    @Expect(ranged.size, Int64(1))
    @Expect(ranged[0].payload, "b")
    store.close()
}

@Test
func timeline_materializeAndDrillDown() {
    let store = inMemStore()
    let tl = store.timeline("t2", "测试", Timeline.defaultLevels())
    tl.append(TEST_BASE, "m1", tagsOf([]))
    tl.append(TEST_BASE + 1000, "m2", tagsOf([]))
    tl.append(TEST_BASE + 2000, "m3", tagsOf([]))
    tl.materialize(TEST_BASE, "测试")   // now = TEST_BASE 正好是 10min 窗口起点

    // 最细层 10min 桶下钻 → 原始 3 条
    let tenKey = tl.bucketKeyOf(TEST_BASE, Timeline.windowMs("10min"))
    let ten = tl.drillDown("10min", tenKey)
    @Expect(ten.size, Int64(3))
    // 逐层上钻：1h 桶下钻 → 同一 3 条（经 30min 桶链）
    let oneKey = tl.bucketKeyOf(TEST_BASE, Timeline.windowMs("1h"))
    let one = tl.drillDown("1h", oneKey)
    @Expect(one.size, Int64(3))
    // 桶摘要存在
    match (tl.bucketSummary("10min", tenKey)) {
        case Some(s) => @Expect(s.indexOf("3 条") != None, true)
        case None => @Fail("10min 桶摘要缺失")
    }
    store.close()
}

@Test
func timeline_bucketAtFallsBackToEarlierBucket() {
    let store = inMemStore()
    let tl = store.timeline("t3", "测试", Timeline.defaultLevels())
    tl.append(TEST_BASE, "x", tagsOf([]))
    tl.materialize(TEST_BASE, "测试")
    // 锚点在下一个 10min 窗口（未物化）→ 回退到 TEST_BASE 的桶
    let anchor = TEST_BASE + Timeline.windowMs("10min") + 1000
    match (tl.bucketAt("10min", anchor)) {
        case Some(key) => @Expect(key, tl.bucketKeyOf(TEST_BASE, Timeline.windowMs("10min")))
        case None => @Fail("bucketAt 应回退到更早桶")
    }
    store.close()
}

@Test
func timeline_listBuckets() {
    let store = inMemStore()
    let tl = store.timeline("t4", "测试", Timeline.defaultLevels())
    tl.append(TEST_BASE, "x", tagsOf([]))
    tl.materialize(TEST_BASE, "测试")
    let buckets = tl.listBuckets("10min", None, None)
    @Expect(buckets.size >= 1, true)
    @Expect(buckets[0].bucketKey, tl.bucketKeyOf(TEST_BASE, Timeline.windowMs("10min")))
    store.close()
}

@Test
func timeline_validateLevels() {
    // 合法：默认链 / 自定义子集
    Timeline.validateLevels(Timeline.defaultLevels())
    Timeline.validateLevels(dayWeekLevels())
    // 非法：空
    var threw = false
    try { Timeline.validateLevels(ArrayList<String>()) } catch (_) { threw = true }
    @Expect(threw, true)
    // 非法：未知粒度
    threw = false
    let bad = ArrayList<String>()
    bad.add("5min")
    try { Timeline.validateLevels(bad) } catch (_) { threw = true }
    @Expect(threw, true)
    // 非法：乱序
    threw = false
    let unordered = ArrayList<String>()
    unordered.add("1h")
    unordered.add("30min")
    try { Timeline.validateLevels(unordered) } catch (_) { threw = true }
    @Expect(threw, true)
}

@Test
func timeline_windowMsMapping() {
    @Expect(Timeline.windowMs("10min"), Int64(600000))
    @Expect(Timeline.windowMs("day"), Int64(86400000))
    @Expect(Timeline.windowMs("week"), Int64(604800000))
    @Expect(Timeline.windowMs("nope"), Int64(0))
}

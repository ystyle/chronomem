package chronomem.core

import cron.*
import tsdb.*
import std.collection.*

// 通用分层时间线测试：append/query/物化桶链/drillDown 精确回想/桶发现/校验。

@Test
func timeline_appendQueryCountAndTagFilter() {
    let store = fileStore()
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
    let store = fileStore()
    let tl = store.timeline("t2", "测试", Timeline.defaultLevels())
    tl.append(TEST_BASE, "m1", tagsOf([]))
    tl.append(TEST_BASE + 1000, "m2", tagsOf([]))
    tl.append(TEST_BASE + 2000, "m3", tagsOf([]))
    tl.materialize(TEST_BASE, "测试")   // now = TEST_BASE 正好是 10min 窗口起点

    // 最细层 10min 桶下钻 → 原始 3 条
    let tenKey = tl.windowKeyOf(TEST_BASE, "10min")
    let ten = tl.drillDown("10min", tenKey)
    @Expect(ten.size, Int64(3))
    // 逐层上钻：1h 桶下钻 → 同一 3 条（经 30min 桶链）
    let oneKey = tl.windowKeyOf(TEST_BASE, "1h")
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
    let store = fileStore()
    let tl = store.timeline("t3", "测试", Timeline.defaultLevels())
    tl.append(TEST_BASE, "x", tagsOf([]))
    tl.materialize(TEST_BASE, "测试")
    // 锚点在下一个 10min 窗口（未物化）→ 回退到 TEST_BASE 的桶
    let anchor = TEST_BASE + Timeline.windowMs("10min") + 1000
    match (tl.bucketAt("10min", anchor)) {
        case Some(key) => @Expect(key, tl.windowKeyOf(TEST_BASE, "10min"))
        case None => @Fail("bucketAt 应回退到更早桶")
    }
    store.close()
}

@Test
func timeline_listBuckets() {
    let store = fileStore()
    let tl = store.timeline("t4", "测试", Timeline.defaultLevels())
    tl.append(TEST_BASE, "x", tagsOf([]))
    tl.materialize(TEST_BASE, "测试")
    let buckets = tl.listBuckets("10min", None, None)
    @Expect(buckets.size >= 1, true)
    @Expect(buckets[0].bucketKey, tl.windowKeyOf(TEST_BASE, "10min"))
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

@Test
class TimelineBackfillTest {
    // 回归：重启后历史桶缺失——materializeAll(backWindows) 补齐已闭合窗口缺失桶，且幂等
    @TestCase
    func backfillsClosedWindows() {
        let store = fileStore()
        let tl = store.timeline("backfill", "测试", dayWeekLevels())
        let base = TEST_BASE
        let DAY = Int64(86400000)
        // 三个 day 窗口：两个已闭合历史 + 一个当窗（回溯 30 窗覆盖）
        let w0 = tl.windowStartOf(base - 2 * DAY - 1000, "day")
        let w1 = tl.windowStartOf(base - 1 * DAY - 1000, "day")
        let w2 = tl.windowStartOf(base, "day")
        let now = w2 + 5000
        // tsdb 严格时序：按序写
        tl.append(w0 + 1000, "p0", tagsOf([]))
        tl.append(w1 + 1000, "p1", tagsOf([]))
        tl.append(w2 + 1000, "p2", tagsOf([]))
        // 默认（不补）：只有当窗桶
        store.materializeAll(now)
        @Expect(dayBucketCountOf(tl, w0), Int64(0))
        @Expect(dayBucketCountOf(tl, w1), Int64(0))
        @Expect(dayBucketCountOf(tl, w2), Int64(1))
        // 补物化：历史桶出现（最旧到最新逐窗建链）
        store.materializeAll(now, backWindows: 30)
        @Expect(dayBucketCountOf(tl, w0), Int64(1))
        @Expect(dayBucketCountOf(tl, w1), Int64(1))
        @Expect(dayBucketCountOf(tl, w2), Int64(1))
        @Expect(tl.drillDown("day", tl.windowKeyOf(w0, "day")).size, Int64(1))
        @Expect(tl.drillDown("day", tl.windowKeyOf(w1, "day")).size, Int64(1))
        // 幂等：再跑计数不变（已有桶跳过，不重写）
        store.materializeAll(now, backWindows: 30)
        @Expect(dayBucketCountOf(tl, w0), Int64(1))
        @Expect(dayBucketCountOf(tl, w1), Int64(1))
        store.close()
    }
}

func dayBucketCountOf(tl: Timeline, ts: Int64): Int64 {
    let key = tl.windowKeyOf(ts, "day")
    var n = Int64(0)
    for (m in tl.listBucketMetas("day", None, None)) {
        if (m.bucketKey == key) { n += 1 }
    }
    n
}

@Test
func timeline_addCronEntrySupportsEveryAndCron() {
    let c = Cron()
    // @every <duration> → ConstantDelaySchedule；标准 cron 表达式 → 墙钟
    addCronEntry(c, "@every 1m", { => () })
    addCronEntry(c, "*/5 * * * *", { => () })
    @Expect(c.getEntries().size, Int64(2))
    c.stop()
}

package chronomem.core

import std.collection.*

// 物化恢复的一致性回归。
//
// 背景：`materializeMissingClosed` 原先对「桶已存在」的历史窗口直接跳过，不校验桶内容。
// 于是只要某窗口在其「当窗期」内没能跑完最后一次物化（服务挂死 / OOM / 崩溃），
// 该窗口的桶就永久停留在中断前的点数——窗口内后来写入的条目在精确下钻中
// **永远不可见**，且桶摘要与下钻结果一致（调用方无法察觉少了条目）。

// 辅助：读桶引用的点数（老格式回退 refs.size）。
// 注意 Timeline.bucketSummary 返回的是摘要文本（Option<String>），
// 带 refsCount 的 BucketRecord 在 tsdb 层，故经 rawTsdb() 取。
func bucketPointCount(store: TimelineStore, series: String, level: String, key: String): Int64 {
    match (store.rawTsdb().bucketSummary(series, level, key)) {
        case Some(rec) => if (rec.refsCount >= 0) { rec.refsCount } else { Int64(rec.refs.size) }
        case None => Int64(-1)
    }
}

func bucketCreatedAt(store: TimelineStore, series: String, level: String, key: String): Int64 {
    match (store.rawTsdb().bucketSummary(series, level, key)) {
        case Some(rec) => rec.createdAt
        case None => Int64(0)
    }
}

// 场景：先物化 → 同窗口再写入 → 服务重启后的补齐流程必须重算该陈旧桶。
@Test
func timeline_materializeMissingClosed_recomputesStaleBucket() {
    let store = fileStore()
    let tl = store.timeline("stale", "测试", dayWeekLevels())
    let day = TEST_BASE
    let key = tl.windowKeyOf(day, "day")
    // 第一批 3 条 → 物化（相当于中断前已经落盘的桶）
    tl.append(day, "a", tagsOf([]))
    tl.append(day + 1000, "b", tagsOf([]))
    tl.append(day + 2000, "c", tagsOf([]))
    tl.materialize(day, "测试")
    @Expect(bucketPointCount(store, "stale", "day", key), 3)
    // 第二批 2 条写入同一窗口，此后未再物化（模拟当窗期中断）
    tl.append(day + 3000, "d", tagsOf([]))
    tl.append(day + 4000, "e", tagsOf([]))
    // 重启后的补齐流程：now 落在下一窗口，使目标窗口已闭合
    let nextDay = tl.nextWindowStartMs(day, "day")
    tl.materializeMissingClosed(nextDay + 1, "测试", 5)
    // 桶必须被重算到 5 条，且下钻结果一致
    @Expect(bucketPointCount(store, "stale", "day", key), 5)
    @Expect(tl.drillDown("day", key).size, 5)
    store.close()
}

// 保护：内容未变的窗口不应被无谓重写（补齐流程仍须幂等，避免每分钟全量重写桶）。
@Test
func timeline_materializeMissingClosed_keepsFreshBucketUntouched() {
    let store = fileStore()
    let tl = store.timeline("fresh", "测试", dayWeekLevels())
    let day = TEST_BASE
    let key = tl.windowKeyOf(day, "day")
    tl.append(day, "a", tagsOf([]))
    tl.append(day + 1000, "b", tagsOf([]))
    tl.materialize(day, "测试")
    let created = bucketCreatedAt(store, "fresh", "day", key)
    let nextDay = tl.nextWindowStartMs(day, "day")
    tl.materializeMissingClosed(nextDay + 1, "测试", 5)
    // 点数不变 → 桶不应被重写（createdAt 不变）
    @Expect(bucketPointCount(store, "fresh", "day", key), 2)
    @Expect(bucketCreatedAt(store, "fresh", "day", key), created)
    store.close()
}

// bucketAt 默认必须严格：目标窗口未物化时不得静默给出更早窗口的数据。
@Test
func timeline_bucketAtStrictByDefault() {
    let store = fileStore()
    let tl = store.timeline("strict", "测试", Timeline.defaultLevels())
    tl.append(TEST_BASE, "x", tagsOf([]))
    tl.materialize(TEST_BASE, "测试")
    let anchor = TEST_BASE + Timeline.windowMs("10min") + 1000
    match (tl.bucketAt("10min", anchor)) {
        case Some(_) => @Fail("默认不应回退到更早窗口的桶")
        case None => ()
    }
    // 显式开启回退（浏览型用例：从最近有数据处开始看）
    match (tl.bucketAt("10min", anchor, allowFallback: true)) {
        case Some(key) => @Expect(key, tl.windowKeyOf(TEST_BASE, "10min"))
        case None => @Fail("allowFallback=true 应回退到更早桶")
    }
    store.close()
}

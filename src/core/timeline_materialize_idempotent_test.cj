package chronomem.core

import tsdb.*
import std.collection.*
import std.time.*

// —— 幂等物化回归（2026-09-15 生产写路径 OOM 事故）——
// 背景：materialize 由 cron 每 60s 跑一次，即使当窗**一条新数据都没有**也会重写同一份桶。
// 写放大直接变成每分钟一次 memtable rotate/flush/compaction：事故现场 LSM 文件编号
// 18 小时从 000148 涨到 001089（约 940 个文件），长跑堆压力与 OOM 概率都由此抬升
// （成因链见 docs/blog/2026-09-09-cangjie-service-oom-hunt.md；空 message 异常 = OOM 签名）。
// 本回归钉住两条：① 窗口内容未变 → 不重写（createdAt 不变）；② 上层链只在子桶集合变化时重写。
@Test
func timeline_materializeIsIdempotentWhenWindowUnchanged() {
    let store = fileStore()
    let tl = store.timeline("idem", "测试", dayWeekLevels())
    tl.append(TEST_BASE, "a", tagsOf([]))
    tl.materialize(TEST_BASE, "测试")

    let dayKey = tl.windowKeyOf(TEST_BASE, "day")
    let day1 = bucketRecord(store, "idem", "day", dayKey).getOrThrow()
    @Expect(day1.refsCount, Int64(1))
    let weekKey = tl.windowKeyOf(TEST_BASE, "week")
    let week1 = bucketRecord(store, "idem", "week", weekKey).getOrThrow()
    @Expect(week1.refsCount, Int64(1))

    // 零新增 → 再物化不得重写（createdAt 必须原样；先 sleep 保证"若重写则时间戳必变"）
    sleep(Duration.millisecond * 5)
    tl.materialize(TEST_BASE, "测试")
    let day2 = bucketRecord(store, "idem", "day", dayKey).getOrThrow()
    @Expect(day2.createdAt, day1.createdAt)
    @Expect(day2.refsCount, Int64(1))
    let week2 = bucketRecord(store, "idem", "week", weekKey).getOrThrow()
    @Expect(week2.createdAt, week1.createdAt)

    // 窗口内新增一条 → 最细层内容变了必须重写；子桶集合未变 → 上层链不重写
    tl.append(TEST_BASE + 1000, "b", tagsOf([]))
    sleep(Duration.millisecond * 5)
    tl.materialize(TEST_BASE, "测试")
    let day3 = bucketRecord(store, "idem", "day", dayKey).getOrThrow()
    @Expect(day3.refsCount, Int64(2))
    @Expect(day3.createdAt != day1.createdAt, true)
    let week3 = bucketRecord(store, "idem", "week", weekKey).getOrThrow()
    @Expect(week3.createdAt, week1.createdAt)

    // 新增一天（同一周里多一个 day 子桶）→ 上层链必须更新（refsCount 1 → 2）
    tl.append(TEST_BASE + 24 * 3600 * 1000, "c", tagsOf([]))
    tl.materialize(TEST_BASE + 24 * 3600 * 1000, "测试")
    let week4 = bucketRecord(store, "idem", "week", weekKey).getOrThrow()
    @Expect(week4.refsCount, Int64(2))
    store.close()
}

// 取桶记录（返回 Option，调用方 getOrThrow）
func bucketRecord(store: TimelineStore, series: String, level: String, key: String): ?BucketRecord {
    store.rawTsdb().bucketSummary(series, level, key)
}

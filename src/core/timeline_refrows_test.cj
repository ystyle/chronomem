package chronomem.core

import std.collection.*

// 表式引用行（`k:`）的清理回归。
//
// 背景：新格式物化桶把引用点逐行写进独立的 `k:<series>:<level>:<key>:<seq>`
// 前缀（避开单值尺寸上限），与桶记录 `b:` 是**两个独立 key 前缀**。tsdb 0.3.4
// 的 `clearSeries` / `deleteSeries` 只扫 `b:`，于是清空/删除后 `k:` 行永久残留：
//   - 存储只增不减（磁盘无谓膨胀，且清空操作看起来"没清干净"）；
//   - 重新物化同一桶时新旧行叠加 → `refsCount` 虚高（塔视图桶计数偏大）、
//     下钻可能出现幽灵引用。
// tsdb 0.3.5 修掉（`deleteAllBuckets` 同时清 `b:` 与 `k:`），本用例锁定该行为，
// 防止依赖回落或重新引入。

// 场景：TRUNCATE 后引用行必须一并清空，重新物化不得让计数虚高。
@Test
func timeline_truncateClearsRefRowsNoGhostRefs() {
    let store = fileStore()
    let tl = store.timeline("ghost", "测试", dayWeekLevels())
    let day = TEST_BASE
    let key = tl.windowKeyOf(day, "day")
    // 写入 4 条并物化 → 产生 4 行 `k:` 引用
    var i = Int64(0)
    while (i < 4) {
        tl.append(day + i * 1000, "p" + i.toString(), tagsOf([]))
        i += 1
    }
    tl.materialize(day, "测试")
    @Expect(store.rawTsdb().refRowsCount("ghost", "day", key), 4)
    @Expect(bucketPointCount(store, "ghost", "day", key), 4)
    // TRUNCATE：桶记录与引用行都应清空
    tl.clearAll()
    @Expect(store.rawTsdb().refRowsCount("ghost", "day", key), 0)
    @Expect(bucketPointCount(store, "ghost", "day", key), -1)
    // 重新物化同一桶：只写 1 条 → 引用行数必须是 1（残留会让它变成 5）
    tl.append(day + 10000, "only", tagsOf([]))
    tl.materialize(day, "测试")
    @Expect(store.rawTsdb().refRowsCount("ghost", "day", key), 1)
    @Expect(bucketPointCount(store, "ghost", "day", key), 1)
    // 下钻不得出现幽灵引用
    @Expect(tl.drillDown("day", key).size, 1)
    store.close()
}

// 场景：DROP（deleteSeries）后该系列不留任何 `k:` 痕迹。
@Test
func timeline_deleteAllClearsRefRows() {
    let store = fileStore()
    let tl = store.timeline("dropme", "测试", dayWeekLevels())
    let day = TEST_BASE
    let key = tl.windowKeyOf(day, "day")
    tl.append(day, "a", tagsOf([]))
    tl.append(day + 1000, "b", tagsOf([]))
    tl.materialize(day, "测试")
    @Expect(store.rawTsdb().refRowsCount("dropme", "day", key), 2)
    tl.deleteAll()
    // DROP 语义 = 不留痕迹：桶与引用行都不在
    @Expect(store.rawTsdb().refRowsCount("dropme", "day", key), 0)
    @Expect(bucketPointCount(store, "dropme", "day", key), -1)
    store.close()
}

// 场景：多次「清空 → 重灌 → 物化」循环，引用行数不累积
// （数据复位脚本反复重跑的真实形态）。
@Test
func timeline_repeatedClearAndRematerializeNoAccumulation() {
    let store = fileStore()
    let tl = store.timeline("cycle", "测试", dayWeekLevels())
    let day = TEST_BASE
    let key = tl.windowKeyOf(day, "day")
    var round = Int64(0)
    while (round < 3) {
        var i = Int64(0)
        while (i < 3) {
            tl.append(day + i * 1000, "r" + round.toString() + "-" + i.toString(), tagsOf([]))
            i += 1
        }
        tl.materialize(day, "测试")
        // 每轮引用行都应恰好等于本轮点数，不随轮次累积
        @Expect(store.rawTsdb().refRowsCount("cycle", "day", key), 3)
        @Expect(bucketPointCount(store, "cycle", "day", key), 3)
        tl.clearAll()
        @Expect(store.rawTsdb().refRowsCount("cycle", "day", key), 0)
        round += 1
    }
    store.close()
}

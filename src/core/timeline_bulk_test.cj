package chronomem.core

import tsdb.*
import std.collection.*

// 大桶压测回归（表式引用行）：
// 2000 条单 day 桶（>~800 条即超过 badger MemTable 64KB 值上限的旧格式临界）→
// 物化必须成功（引用独立 k 行存储）+ 下钻 2000 条 + 轻量计数一致 + 上层 week 链。
// 旧格式 refs 数组在 value 内会写入失败（物化静默失败 = Web UI 时间桶点不开的根因）。
@Test
func timeline_bulkDayBucketDrillAndMetas() {
    let store = fileStore()
    let tl = store.timeline("bulkday", "测试", dayWeekLevels())
    let base = TEST_BASE
    // 从 base 所在 day 窗口起点（北京时区日界）起写入：2000 × 20s = 11.1h，全在单窗口
    let dStart = tl.windowStartOf(base, "day")
    var ts = dStart
    for (i in 0..2000) {
        tl.append(ts, "{\"task\":\"bulk " + i.toString() + "\"}", tagsOf([]))
        ts += 20000
    }
    tl.materialize(base, "测试")

    let dKey = tl.windowKeyOf(base, "day")
    let metas = tl.listBucketMetas("day", None, None)
    var cnt = Int64(0)
    for (m in metas) {
        if (m.bucketKey == dKey) { cnt = m.refsCount }
    }
    @Expect(cnt, Int64(2000))
    println("BULKDIAG kRows=" + store.rawTsdb().refRowsCount("bulkday", "day", dKey).toString())
    let down = tl.drillDown("day", dKey)
    @Expect(down.size, Int64(2000))
    // week 层（上层）也应可下钻（经 day 子桶链）
    let wKey = tl.windowKeyOf(base, "week")
    let wDown = tl.drillDown("week", wKey)
    @Expect(wDown.size, Int64(2000))
    store.close()
}

// 表式行覆盖重写（幂等物化）：重写后计数不变、引用不累积
@Test
func timeline_bulkBucketIdempotentRewrite() {
    let store = fileStore()
    let tl = store.timeline("bulkidem", "测试", dayWeekLevels())
    let base = TEST_BASE
    let dStart = tl.windowStartOf(base, "day")
    var ts = dStart
    for (i in 0..1000) {
        tl.append(ts, "{\"task\":\"x " + i.toString() + "\"}", tagsOf([]))
        ts += 60000
    }
    tl.materialize(base, "测试")
    tl.materialize(base, "测试") // 重写（删旧 k 行再写，幂等）
    let dKey = tl.windowKeyOf(base, "day")
    let down = tl.drillDown("day", dKey)
    @Expect(down.size, Int64(1000))
    store.close()
}

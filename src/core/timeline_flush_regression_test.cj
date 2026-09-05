package chronomem.core

import std.collection.*

// —— memtable flush 回归（生产 OOM 根因，见 fix/memtable-size-oom）——
// 背景：生产曾用 memTableSize=16MB（arena=32MB）。memtable 攒满触发同步 flush 时，
// 峰值窗口（旧表 32MB arena 仍活 + 新表再分配 32MB + SSTable 全量构建多份拷贝）
// 在默认 256MB GC 堆下 OutOfMemoryError（GC 日志实测峰值活对象 ~170MB 收不动）：
//   → badger WritePipeline 整批 markFailed（空消息）→ 写路径全断、materialize 每轮
//     "Job 0 failed"、GC 风暴挂起（忆时塔生产两次事故，均靠重启清堆暂缓）。
// 修复：默认 memTableSize 降至 4MB（arena 8MB，单次 flush 峰值 ~50MB，堆内安全）。
// 本回归：默认配置下灌入总量 >2×memTableSize 的大条目，必须多次 flush 成功
// （flush 缺位会在 arena 溢出/写失败处暴露）、数据完整读回、重启后仍完整。
@Test
func timeline_defaultMemTableMultiFlushRoundTrip() {
    let dir = freshTestDir()
    // 走默认参数（修复后 = 4MB；曾为 16MB）
    let store = TimelineStore.open(dir)
    let tl = store.timeline("flushreg", "测试", dayWeekLevels())
    // 每条 ~600KB（< badger 1MB 内联阈值 → 走 memtable 不进 vlog）；20 条 ≈ 12MB
    // > 4MB×2：至少触发 2 次同步 flush（写路径上同步执行）
    let big = bigText(600000)
    var ts = TEST_BASE
    for (i in 0..20) {
        tl.append(ts, big, tagsOf([("i", i.toString())]))
        ts += 60000
    }
    // 读回完整（memtable/imm/sst 合并读路径）
    @Expect(tl.countIn(TEST_BASE, ts), Int64(20))
    store.close()
    // 重启读回：flush 落盘 + WAL 恢复均须完整（数据不能悬在内存）
    let store2 = TimelineStore.open(dir)
    let tl2 = store2.timeline("flushreg", "测试", dayWeekLevels())
    @Expect(tl2.countIn(TEST_BASE, ts), Int64(20))
    store2.close()
}

// 构造 size 字节的 ASCII 文本（测试大条目用）
func bigText(size: Int64): String {
    let sb = StringBuilder()
    for (i in 0..size) {
        sb.append("x")
    }
    sb.toString()
}

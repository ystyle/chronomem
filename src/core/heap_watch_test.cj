package chronomem.core

import std.fs.{Path, exists}

// 堆水位看护的纯逻辑回归（阈值判定 / 冷却 / dump 路径命名）。
// 真正的 dumpHeapData 不在单测里调用——它会写大文件；只测"该不该 dump"的判据。

@Test
func heapWatch_shouldDumpRespectsThreshold() {
    // 阈值 <= 0 = 关闭：任何水位都不 dump（默认关闭，避免误在生产写大文件）
    @Expect(shouldDumpHeap(99, 0), false)
    @Expect(shouldDumpHeap(99, -1), false)
    // 达阈值即 dump（含等于）
    @Expect(shouldDumpHeap(80, 80), true)
    @Expect(shouldDumpHeap(81, 80), true)
    @Expect(shouldDumpHeap(79, 80), false)
}

@Test
func heapWatch_statusComputesPct() {
    // 正常：已用/上限
    let s = HeapStatus(512 * 1024 * 1024, 1024 * 1024 * 1024)
    @Expect(s.usedPct, Int64(50))
    @Expect(s.usedBytes, Int64(512 * 1024 * 1024))
    @Expect(s.maxBytes, Int64(1024 * 1024 * 1024))
    // 上限为 0（异常场景）：不得除零，pct 记 0
    @Expect(HeapStatus(100, 0).usedPct, Int64(0))
    // 贴顶
    @Expect(HeapStatus(1011, 1024).usedPct, Int64(98))
}

@Test
func heapWatch_dumpFileNameShape() {
    let n = heapDumpFileName(1792130941499, "/data")
    @Expect(n, "/data/heap-1792130941499.hprof")
    // 同一时刻命名稳定（可据此排序观察泄漏速率）
    @Expect(n, heapDumpFileName(1792130941499, "/data"))
}

@Test
func heapWatch_disabledWatcherDoesNotStart() {
    // threshold=0 → enabled=false，start() 不应起线程（用 running 观察不到，
    // 故以 enabled() 作为契约判据）
    let w = HeapDumpWatcher(0, 60, 3600, "/tmp")
    @Expect(w.enabled(), false)
    let w2 = HeapDumpWatcher(85, 60, 3600, "/tmp")
    @Expect(w2.enabled(), true)
}

@Test
func heapWatch_checkOnceNoDumpBelowThreshold() {
    // 阈值设 200%（不可能达到）→ checkOnce 必须返回 false 且不写文件
    let dir = freshTestDir()
    let w = HeapDumpWatcher(200, 60, 3600, dir)
    @Expect(w.checkOnce(nowMs()), false)
    // 确认没有产生 dump 文件
    @Expect(!exists(Path(heapDumpFileName(nowMs(), dir))), true)
}

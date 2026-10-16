// 堆水位监控与主动 dump（诊断用，见 docs/incidents/2026-10-16-mcp-unresponsive.md）。
//
// 存在的理由：生产上那类内存问题表现为**堆贴顶摆动**（usedObjSize 在 800MB~1GB 之间
// 来回，GC 每 ~2s 一次却回收不动），而不是堆溢出 —— 于是 `cjHeapDumpOnOOM` 永远不触发，
// 最需要现场证据时反而没有 dump。本模块按水位主动取证。
//
// 设计约束：
// - 只在超过阈值时 dump，且带**冷却**（默认 1 小时）——dump 文件很大，连续 dump 会写满磁盘；
// - 检查线程常驻但开销可忽略（每 checkSeconds 读一次 runtime 计数）；
// - 阈值 0 = 关闭（默认关闭，避免误开在生产上写大文件）。
package chronomem.core

import std.runtime.*
import std.fs.*
import std.sync.Mutex
import std.collection.ArrayList

// 堆水位采样（供监控/告警/测试使用；纯函数无副作用）
public struct HeapStatus {
    public let usedBytes: Int64      // 已用堆（getAllocatedHeapSize）
    public let maxBytes: Int64       // 堆上限（getMaxHeapSize）
    public let usedPct: Int64        // 已用百分比（0-100；maxBytes<=0 时为 0）

    public init(usedBytes: Int64, maxBytes: Int64) {
        this.usedBytes = usedBytes
        this.maxBytes = maxBytes
        this.usedPct = if (maxBytes > 0) { usedBytes * 100 / maxBytes } else { 0 }
    }
}

public func heapStatus(): HeapStatus {
    HeapStatus(getAllocatedHeapSize(), getMaxHeapSize())
}

// 是否达到 dump 阈值（thresholdPct <= 0 表示关闭；用 >= 便于测试边界）
public func shouldDumpHeap(usedPct: Int64, thresholdPct: Int64): Bool {
    if (thresholdPct <= 0) { return false }
    usedPct >= thresholdPct
}

// dump 文件名：heap-<epochMs>.hprof（按时间排序即可看出泄漏速率）
public func heapDumpFileName(epochMs: Int64, dir: String): String {
    dir + "/heap-" + epochMs.toString() + ".hprof"
}

// 堆水位看护线程：按间隔检查，越过阈值且过了冷却则 dump。
// stop() 用于优雅退出（与其它后台执行器一致：退出前不留下无界等待的线程）。
public class HeapDumpWatcher {
    private let thresholdPct: Int64
    private let checkSeconds: Int64
    private let cooldownSeconds: Int64
    private let dir: String
    private let lock = Mutex()
    private var running = false
    private var spawned = false
    private var lastDumpMs: Int64 = 0

    public init(thresholdPct: Int64, checkSeconds: Int64, cooldownSeconds: Int64, dir: String) {
        this.thresholdPct = thresholdPct
        this.checkSeconds = checkSeconds
        this.cooldownSeconds = cooldownSeconds
        this.dir = dir
    }

    public func enabled(): Bool { this.thresholdPct > 0 }

    // 启动看护线程（幂等）
    public func start(): Unit {
        if (!this.enabled()) { return }
        let shouldSpawn = synchronized(this.lock) {
            this.running = true
            if (this.spawned) { false } else { this.spawned = true; true }
        }
        if (shouldSpawn) {
            spawn { => this.loop() }
        }
    }

    public func stop(): Unit {
        synchronized(this.lock) { this.running = false }
    }

    // 看护循环：不持锁睡眠（避免 stop() 被阻塞）
    private func loop(): Unit {
        while (this.isRunning()) {
            this.checkOnce(nowMs())
            // 分片睡眠：stop() 后最多等 1s 退出，而不是等整个 checkSeconds
            var slept = Int64(0)
            while (slept < this.checkSeconds && this.isRunning()) {
                sleep(Duration.second)
                slept += 1
            }
        }
    }

    private func isRunning(): Bool {
        synchronized(this.lock) { this.running }
    }

    // 单次检查（测试可直接调用）：达阈值且过冷却则 dump，返回是否 dump 了。
    // dump 失败不抛出——诊断钩子绝不能把主服务拖垮。
    public func checkOnce(now: Int64): Bool {
        let st = heapStatus()
        if (!shouldDumpHeap(st.usedPct, this.thresholdPct)) { return false }
        let allow = synchronized(this.lock) {
            if (this.lastDumpMs > 0 && now - this.lastDumpMs < this.cooldownSeconds * 1000) {
                false
            } else {
                this.lastDumpMs = now
                true
            }
        }
        if (!allow) { return false }
        let path = heapDumpFileName(now, this.dir)
        try {
            dumpHeapData(Path(path))
            println("chronomem heap dump written: " + path +
                "（usedPct=" + st.usedPct.toString() + "%, used=" +
                (st.usedBytes / 1048576).toString() + "MB/" + (st.maxBytes / 1048576).toString() + "MB）")
        } catch (e: Exception) {
            // 诊断钩子的失败不能影响服务本身
            println("chronomem heap dump failed: " + e.toString())
        }
        true
    }
}

package chronomem.mcp

import chronomem.core.*
import cron.*
import std.collection.*

// 定时自动语义总结（design.md §7.3）：对 auto_summarize 类型 × summary_levels 粒度，
// 总结「最新已闭合且未总结」的**自然时间窗口**。
// 成本护栏：per-type opt-in + 每轮上限 + 窗口沉降期 + 幂等（已总结不重跑）。
// 后台循环由 cron-cj 驱动（cron 表达式，默认 */10 * * * *，墙钟对齐）；runOnce 可注入 now 测试。
// 结构物化（MaterializeScheduler）仍独立自动跑；本调度只做语义总结（LLM）。
public class SummarizeScheduler {
    private let svc: MemoryService
    private let maxPerRun: Int64
    private let settleMs: Int64
    private var cron: Option<Cron> = None

    public init(svc: MemoryService, maxPerRun: Int64, settleMs: Int64) {
        this.svc = svc
        this.maxPerRun = maxPerRun
        this.settleMs = settleMs
    }

    public static func fromConfig(svc: MemoryService, cfg: ChronomemConfig): SummarizeScheduler {
        SummarizeScheduler(svc, cfg.summaryMaxPerRun, cfg.summarySettleMs)
    }

    // 单轮（now 注入便于测试）：返回本次实际执行的总结条数
    public func runOnce(now: Int64): Int64 {
        var count = Int64(0)
        for (m in this.svc.registry.list()) {
            if (count >= this.maxPerRun) { break }
            if (!m.autoSummarize) { continue }
            let levels = this.summaryLevelsOf(m)
            for (l in levels) {
                if (count >= this.maxPerRun) { break }
                if (this.summarizeDueWindow(m, l, now)) {
                    count += 1
                }
            }
        }
        count
    }

    // 目标粒度：显式 summaryLevels，或缺省 = 粒度链最粗 2 档（§7.3）
    public func summaryLevelsOf(m: TypeMeta): ArrayList<String> {
        match (m.summaryLevels) {
            case Some(ls) => ls
            case None => Timeline.coarsestLevels(m.levels, 2)
        }
    }

    // 总结「最新已闭合且未总结」的窗口；返回是否提交了一次后台总结任务
    private func summarizeDueWindow(m: TypeMeta, level: String, now: Int64): Bool {
        if (this.svc.summarizer.isNone()) { return false }
        match (this.svc.registry.timelineOf(m.name)) {
            case None => return false
            case Some(t) =>
                // 当前窗口起点 → 上一个（刚闭合的）自然时间窗口
                let curStart = t.windowStartOf(now, level)
                let prevStart = t.windowStartOf(curStart - 1, level)
                let prevEnd = t.nextWindowStartMs(prevStart, level) - 1
                // 沉降：窗口结束 settleMs 以上才总结（防漏窗口末尾的条目）
                if (now - prevEnd < this.settleMs) { return false }
                // 幂等：窗口内所有分组（含未分组）都已有总结则跳过
                if (allGroupsSummarized(this.svc, m, prevStart, prevEnd)) { return false }
                // 该窗口已有后台任务在跑（提交后未完成）→ 跳过，避免重复提交
                if (this.svc.summarizeRunner.getOrThrow().isWindowActive(m.name, prevStart)) { return false }
                // 有条目才总结（空窗口零成本）
                let points = t.queryPoints(prevStart, prevEnd, 0, None)
                if (points.size == 0) { return false }
                // 提交后台任务（LLM 由 SummarizeJobRunner 串行执行，不阻塞任何线程）
                _ = this.svc.summarizeRunner.getOrThrow().submit(m.name, prevStart, prevEnd, "", true)
                true
        }
    }

    // 窗口内所有分组（含未分组）都已有覆盖总结则视为已总结（幂等）。
    // 分组维度为空（整窗总结）时：只要有任一覆盖总结即视为已总结。
    private func allGroupsSummarized(svc: MemoryService, m: TypeMeta, winFrom: Int64, winTo: Int64): Bool {
        match (m.summaryGroupBy) {
            case None => latestOverlappingSummary(svc, m.name, winFrom, winTo, None).isSome()
            case Some(dims) =>
                // 收集窗口内实际存在的分组（含未分组）
                let tl = svc.registry.timelineOf(m.name).getOrThrow()
                let points = tl.queryPoints(winFrom, winTo, 0, None)
                if (points.size == 0) { return true }   // 空窗口视为已处理
                let seen = HashSet<Option<String>>()
                for (p in points) {
                    seen.add(groupKeyOf(m, p))
                }
                // 每个存在的分组都须有覆盖总结
                for (k in seen) {
                    if (latestOverlappingSummary(svc, m.name, winFrom, winTo, k).isNone()) {
                        return false
                    }
                }
                true
        }
    }

    // 启动后台自动总结（cron 表达式或 @every <duration>，缺省 */10 * * * *；与自然窗口时区对齐）
    public func start(spec!: String = "*/10 * * * *"): Unit {
        let c = Cron()
        c.setLocation(this.svc.store.timeZoneOf())
        addCronEntry(c, spec, { => this.runOnce(nowMs()) })
        c.start()
        this.cron = Some(c)
    }

    public func stop(): Unit {
        match (this.cron) {
            case Some(c) => c.stop()
            case None => ()
        }
    }
}

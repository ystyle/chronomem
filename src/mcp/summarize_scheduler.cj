package chronomem.mcp

import chronomem.core.*
import cron.*
import std.collection.*

// 定时自动语义总结（design.md §7.3）：对 auto_summarize 类型 × summary_levels 粒度，
// 总结「最新已闭合且未总结」的**自然时间窗口**。
// 成本护栏：per-type opt-in + 每轮上限 + 窗口沉降期 + 幂等（已总结不重跑）
//          + **有限重试/退避**（fix/summarize-budget）。
//
// 为什么需要有限重试：失败窗口不落库 → 幂等判据永远为假 → 每 10 分钟重试一次，
// 直到永远。任何"重试也不会成功"的失败（如输入超端点上下文）都会变成常态烧钱。
// 故：同一窗口连续失败 maxAttempts 次后停止自动重试，并把原因留在 abandoned 里可见；
// 手动 recompute 成功（窗口变得"已总结"）后计数自然清零。
//
// 后台循环由 cron-cj 驱动（cron 表达式，默认 */10 * * * *，墙钟对齐）；runOnce 可注入 now 测试。
// 结构物化（MaterializeScheduler）仍独立自动跑；本调度只做语义总结（LLM）。
public class SummarizeScheduler {
    private let svc: MemoryService
    private let maxPerRun: Int64
    private let settleMs: Int64
    private let maxAttempts: Int64
    // 窗口 → 已失败次数 / 上次提交时刻 / 放弃原因（key = type|winFrom）
    private let attempts = HashMap<String, Int64>()
    private let lastTryAt = HashMap<String, Int64>()
    private let abandoned = HashMap<String, String>()
    private var cron: Option<Cron> = None

    public init(svc: MemoryService, maxPerRun: Int64, settleMs: Int64, maxAttempts!: Int64 = 3) {
        this.svc = svc
        this.maxPerRun = maxPerRun
        this.settleMs = settleMs
        this.maxAttempts = if (maxAttempts < 1) { Int64(1) } else { maxAttempts }
    }

    public static func fromConfig(svc: MemoryService, cfg: ChronomemConfig): SummarizeScheduler {
        SummarizeScheduler(svc, cfg.summaryMaxPerRun, cfg.summarySettleMs,
            maxAttempts: cfg.summaryMaxAttempts)
    }

    // 单轮（now 注入便于测试）：返回本次实际提交的总结任务数
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

    // 已放弃自动重试的窗口（可见性：日志之外还能被测试/控制台读到）
    public func abandonedReport(): ArrayList<String> {
        let out = ArrayList<String>()
        for ((k, v) in this.abandoned) { out.add(k + " :: " + v) }
        out
    }

    // 某窗口已失败次数（测试/诊断用）
    public func attemptsOf(typeName: String, winFrom: Int64): Int64 {
        match (this.attempts.get(this.windowKey(typeName, winFrom))) {
            case Some(v) => v
            case None => Int64(0)
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
                let key = this.windowKey(m.name, prevStart)
                // 幂等：窗口内所有分组（含未分组）都已有总结则跳过，并清掉该窗口的重试账
                if (SummarizeScheduler.allGroupsSummarized(this.svc, m, prevStart, prevEnd)) {
                    this.clearRetryState(key)
                    return false
                }
                // 该窗口已有后台任务在跑（提交后未完成）→ 跳过，避免重复提交
                if (this.svc.summarizeRunner.getOrThrow().isWindowActive(m.name, prevStart)) { return false }
                // 上次该窗口的任务**成功**过（可能只覆盖了当时存在的分组）→ 现在没总结完说明是
                // 又有新分组，属正常补总结，不能算"失败重试"（否则退避会挡住新分组的总结）
                match (this.svc.summarizeRunner.getOrThrow().lastOutcome(m.name, prevStart)) {
                    case Some(v) => if (v == "done") { this.clearRetryState(key) }
                    case None => ()
                }
                // 有条目才总结（空窗口零成本；key-only count，不读 payload）
                if (t.countIn(prevStart, prevEnd) == 0) {
                    this.clearRetryState(key)
                    return false
                }
                // 有限重试：连续失败到上限后停止自动重试（避免 10 分钟一轮的永久白烧）
                let failed = match (this.attempts.get(key)) {
                    case Some(v) => v
                    case None => Int64(0)
                }
                if (failed >= this.maxAttempts) {
                    if (!this.abandoned.contains(key)) {
                        let msg = "已连续失败 " + failed.toString() + " 次，停止自动重试；"
                            + "修因后可用 mem/summarize 带 recompute=true 手动补总结"
                        this.abandoned[key] = msg
                        eprintln("[summarize] " + m.name + " 窗口 " + prevStart.toString() + " " + msg)
                    }
                    return false
                }
                // 退避：失败后要等够间隔再试（首轮不等）
                match (this.lastTryAt.get(key)) {
                    case Some(last) =>
                        if (now - last < backoffMs(failed)) { return false }
                    case None => ()
                }
                // 提交后台任务（LLM 由 SummarizeJobRunner 串行执行，不阻塞任何线程）
                _ = this.svc.summarizeRunner.getOrThrow().submit(m.name, prevStart, prevEnd, "", true)
                this.attempts[key] = failed + 1
                this.lastTryAt[key] = now
                true
        }
    }

    private func windowKey(typeName: String, winFrom: Int64): String {
        typeName + "|" + winFrom.toString()
    }

    private func clearRetryState(key: String): Unit {
        this.attempts.remove(key)
        this.lastTryAt.remove(key)
        this.abandoned.remove(key)
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

    // 窗口内所有分组（含未分组）都已有覆盖总结则视为已总结（幂等）。
    // 分组维度为空（整窗总结）时：只要有任一覆盖总结即视为已总结。
    private static func allGroupsSummarized(svc: MemoryService, m: TypeMeta, winFrom: Int64, winTo: Int64): Bool {
        match (m.summaryGroupBy) {
            case None => latestOverlappingSummary(svc, m.name, winFrom, winTo, None).isSome()
            case Some(dims) =>
                // 分批遍历收集窗口内实际存在的分组（含未分组）——只取 groupKey，
                // 点对象每批即弃，避免整窗驻留
                let tl = svc.registry.timelineOf(m.name).getOrThrow()
                let seen = GroupKeyCollector()
                let any = tl.forEachWindowPoint(winFrom, winTo, 200, { points =>
                    for (p in points) {
                        seen.add(groupKeyOf(m, p))
                    }
                })
                if (!any) { return true }   // 空窗口视为已处理
                // 每个存在的分组都须有覆盖总结
                for (k in seen.all()) {
                    if (latestOverlappingSummary(svc, m.name, winFrom, winTo, k).isNone()) {
                        return false
                    }
                }
                true
        }
    }
}

// 失败退避阶梯（按已失败次数）：首轮不等；之后 20 分钟、60 分钟（cron 默认 10 分钟一轮，
// 故实际表现为第 2 次尝试在第 20 分钟、第 3 次在第 80 分钟附近，之后放弃）。
func backoffMs(failedAttempts: Int64): Int64 {
    match (failedAttempts) {
        case 0 => Int64(0)
        case 1 => Int64(20 * 60 * 1000)
        case _ => Int64(60 * 60 * 1000)
    }
}

// lambda 不能捕获可变局部变量——收集器对象（捕获引用、改内部字段）
class GroupKeyCollector {
    private let seen = HashSet<Option<String>>()

    public func add(key: Option<String>): Unit {
        this.seen.add(key)
    }

    public func all(): ArrayList<Option<String>> {
        let out = ArrayList<Option<String>>()
        for (k in this.seen) { out.add(k) }
        out
    }
}

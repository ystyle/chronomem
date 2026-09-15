package chronomem.mcp

import chronomem.core.*
import jsonvalue.*
import mcp.*
import std.collection.*
import std.core.Duration
import std.sync.*

// 后台语义总结任务（mem/summarize 与 mem/recall mode=summary + summarize_on_miss 共用）。
// LLM 调用在独立后台线程串行执行，**绝不阻塞 MCP 接收循环**：
// submit() 立即返回 jobId；任务完成后结果落 <type>.summary（store=true）或暂存内存（store=false），
// 客户端稍后用 mem/summaries / mem/recall / mem/summarize_status 取回。
public class SummarizeJob {
    public let id: Int64
    public let typeName: String
    public let winFrom: Int64
    public let winTo: Int64
    public let instructions: String
    public let store: Bool
    public let recompute: Bool

    public init(id: Int64, typeName: String, winFrom: Int64, winTo: Int64, instructions: String, store: Bool,
        recompute!: Bool = false) {
        this.id = id
        this.typeName = typeName
        this.winFrom = winFrom
        this.winTo = winTo
        this.instructions = instructions
        this.store = store
        this.recompute = recompute
    }
}

// 单后台线程 + FIFO 队列：任务串行执行（LLM 并发有限，串行最稳且结果有序、无并发写库压力）。
// 线程安全：queue/states/results 全部在 lock 保护下访问。
public class SummarizeJobRunner {
    private let svc: MemoryService
    private let lock = Mutex()
    private let cond: Condition
    private let queue = ArrayList<SummarizeJob>()
    private let states = HashMap<Int64, String>()
    private let results = HashMap<Int64, String>()
    // 进行中的窗口（type|winFrom → id）：任务提交加入、进入终态移除。
    // 供调度器判断「该窗口是否已有后台任务在跑」（避免同窗口重复提交；任务完成后自动解除，允许补总结）。
    private let activeWindows = HashMap<String, Int64>()
    // 最近一次进入终态的该窗口任务结果（"done" / "failed"）：调度器据此区分
    // 「失败要退避」与「上次已成功、只是又出现了新分组需要补总结」。
    private let lastOutcomes = HashMap<String, String>()
    private var nextId = Int64(0)
    private var running = false
    private var spawned = false

    public init(svc: MemoryService) {
        this.svc = svc
        this.cond = synchronized(this.lock) { this.lock.condition() }
    }

    // 提交后台总结任务，立即返回 jobId（不执行 LLM 调用）
    public func submit(typeName: String, winFrom: Int64, winTo: Int64, instructions: String, store: Bool,
        recompute!: Bool = false): Int64 {
        synchronized(this.lock) {
            this.nextId += 1
            let id = this.nextId
            this.queue.add(SummarizeJob(id, typeName, winFrom, winTo, instructions, store, recompute: recompute))
            this.states[id] = "pending"
            this.activeWindows[this.windowKey(typeName, winFrom)] = id
            this.cond.notifyAll()
            id
        }
    }

    // 该窗口是否已有提交后尚未完成的后台任务（pending/running 均算）
    public func isWindowActive(typeName: String, winFrom: Int64): Bool {
        synchronized(this.lock) { this.activeWindows.contains(this.windowKey(typeName, winFrom)) }
    }

    // 最近一次该窗口任务的终态（None = 还没有过终态任务）
    public func lastOutcome(typeName: String, winFrom: Int64): Option<String> {
        synchronized(this.lock) { this.lastOutcomes.get(this.windowKey(typeName, winFrom)) }
    }

    private func windowKey(typeName: String, winFrom: Int64): String {
        typeName + "|" + winFrom.toString()
    }

    // 启动后台执行线程（幂等）
    public func start(): Unit {
        let shouldSpawn = synchronized(this.lock) {
            this.running = true
            if (this.spawned) { false } else { this.spawned = true; true }
        }
        if (shouldSpawn) {
            spawn { => this.loop() }
        }
    }

    public func stop(): Unit {
        synchronized(this.lock) {
            this.running = false
            this.cond.notifyAll()
        }
    }

    // 任务状态：pending / running / done / failed / unknown
    public func status(id: Int64): String {
        synchronized(this.lock) {
            match (this.states.get(id)) {
                case Some(s) => s
                case None => "unknown"
            }
        }
    }

    // store=false 的任务结果文本（store=true 的结果已落库，用 mem/summaries 查）
    public func getResult(id: Int64): Option<String> {
        synchronized(this.lock) { this.results.get(id) }
    }

    // 当前在队列/执行中的任务数（含 pending + running）
    public func activeJobs(): Int64 {
        synchronized(this.lock) {
            var n = Int64(0)
            for ((_, st) in this.states) {
                if (st == "pending" || st == "running") { n += 1 }
            }
            n
        }
    }

    // 最近一次提交的任务号（测试/客户端便捷取回用）
    public func lastJobId(): Int64 {
        synchronized(this.lock) { this.nextId }
    }

    // 等待全部后台任务进入终态（队列清空且无执行中任务）
    public func waitIdle(timeout!: Duration = 30 * Duration.second): Bool {
        let deadline = nowMs() + timeout.toMilliseconds()
        while (nowMs() < deadline) {
            if (this.activeJobs() == 0) { return true }
            synchronized(this.lock) { this.cond.wait(timeout: 100 * Duration.millisecond) }
        }
        this.activeJobs() == 0
    }

    // 等待任务进入终态（pending/running 之外），返回终态；超时返回当前状态。测试/客户端轮询用。
    public func waitFor(id: Int64, timeout!: Duration = 30 * Duration.second): String {
        let deadline = nowMs() + timeout.toMilliseconds()
        while (nowMs() < deadline) {
            let st = this.status(id)
            if (st != "pending" && st != "running") { return st }
            synchronized(this.lock) { this.cond.wait(timeout: 100 * Duration.millisecond) }
        }
        this.status(id)
    }

    private func loop(): Unit {
        while (true) {
            let jobOpt: Option<SummarizeJob> = synchronized(this.lock) {
                while (this.queue.size == 0 && this.running) {
                    this.cond.wait()
                }
                if (this.queue.size > 0) {
                    Some(this.queue.remove(at: 0))
                } else {
                    Option<SummarizeJob>.None
                }
            }
            match (jobOpt) {
                case Some(j) => this.execute(j)
                case None => if (!this.running) { return }
            }
        }
    }

    private func execute(j: SummarizeJob): Unit {
        synchronized(this.lock) { this.states[j.id] = "running" }
        var finalStatus = "done"
        var finalText = ""
        try {
            let r = doSummarize(this.svc, j.typeName, j.winFrom, j.winTo, j.instructions, j.store,
                recompute: j.recompute)
            if (r.isError) {
                finalStatus = "failed"
                finalText = resultText(r)
            } else if (!j.store) {
                finalText = resultText(r)
            }
        } catch (e: Exception) {
            finalStatus = "failed"
            finalText = e.message
        }
        synchronized(this.lock) {
            this.states[j.id] = finalStatus
            // 任务进入终态 → 解除窗口占用（允许调度器对该窗口重新评估/补总结）
            this.activeWindows.remove(this.windowKey(j.typeName, j.winFrom))
            this.lastOutcomes[this.windowKey(j.typeName, j.winFrom)] = finalStatus
            // failed 时总是暂存错误文本（便于 mem/summarize_status 定位）；成功且 store=false 才暂存结果
            if (finalStatus == "failed") {
                this.results[j.id] = "ERROR: " + finalText
            } else if (finalText != "" && !j.store) {
                this.results[j.id] = finalText
            }
            this.cond.notifyAll()
        }
    }
}

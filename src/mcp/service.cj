package chronomem.mcp

import chronomem.core.*
import std.collection.*
import std.fs.*
import std.time.TimeZone

// 忆时塔内存引擎：类型注册表 + 时序库 + 可选语义总结器。
// 存储根 = cfg.dir/tsdb（一个 tsdb 库承载全部 <type> 与 <type>.summary）。
// 自然时间窗口时区由 cfg.timeZoneId 决定（空 = 本地时区，§5.2）。
public class MemoryService {
    public let store: TimelineStore
    public let registry: MemoryTypeRegistry
    public let summarizer: Option<Summarizer>
    // 后台总结执行器（LLM 在独立线程跑，绝不阻塞 MCP 接收循环；open 后创建并 start）
    public var summarizeRunner: ?SummarizeJobRunner = None

    private init(store: TimelineStore, registry: MemoryTypeRegistry, summarizer: Option<Summarizer>) {
        this.store = store
        this.registry = registry
        this.summarizer = summarizer
    }

    // 从配置打开磁盘库
    public static func open(cfg: ChronomemConfig): MemoryService {
        let tsdbDir = cfg.dir + "/tsdb"
        if (!exists(Path(tsdbDir))) {
            Directory.create(Path(tsdbDir), recursive: true)
        }
        let tz = resolveTimeZone(cfg.timeZoneId)
        // syncWrites: true —— 记忆服务写低频，同步落盘换「进程被 SIGTERM/SIGKILL 也不丢数据」
        let store = TimelineStore.open(tsdbDir, timeZone: tz, syncWrites: true)
        let registry = MemoryTypeRegistry(store)
        // 开箱即用：默认播种 worklog 类型（幂等；CHRONOLOG_SEED_WORKLOG=false 可关）
        if (cfg.seedWorklog) {
            seedWorklog(registry)
        }
        let summarizer = Summarizer.fromSettings(
            LlmSettings(cfg.llmBaseUrl, cfg.llmApiKey, cfg.llmModel, cfg.llmProvider))
        let svc = MemoryService(store, registry, summarizer)
        svc.initSummarizeRunner()
        svc
    }

    // 内存库（测试用）
    public static func openInMemory(summarizer!: Option<Summarizer> = None, timeZone!: TimeZone = TimeZone.Local): MemoryService {
        let store = TimelineStore.openInMemory(timeZone: timeZone)
        let registry = MemoryTypeRegistry(store)
        let svc = MemoryService(store, registry, summarizer)
        svc.initSummarizeRunner()
        svc
    }

    // 创建并启动后台总结执行器（幂等）
    public func initSummarizeRunner(): Unit {
        if (this.summarizeRunner.isNone()) {
            let runner = SummarizeJobRunner(this)
            runner.start()
            this.summarizeRunner = Some(runner)
        }
    }

    public func close(): Unit {
        match (this.summarizeRunner) {
            case Some(r) => r.stop()
            case None => ()
        }
        this.store.close()
    }
}

// 时区 ID → TimeZone（空 = 本地时区；非法 ID 回退本地）
func resolveTimeZone(id: String): TimeZone {
    if (id == "") { return TimeZone.Local }
    try {
        TimeZone.load(id)
    } catch (_) {
        TimeZone.Local
    }
}

// 开箱即用默认类型：worklog 工作日志（levels [day,week] + auto_summarize + 按 proj 分组总结）。
// 幂等：已存在则跳过（但缺 summaryGroupBy 的旧类型会升级补齐）；任务阶段/任务完成时追加一条 + 总结。
func seedWorklog(registry: MemoryTypeRegistry): Unit {
    let levels = ArrayList<String>()
    levels.add("day")
    levels.add("week")
    let groupBy = ArrayList<String>()
    groupBy.add("proj")
    let meta = TypeMeta(
        "worklog",
        "工作日志（默认类型）：任务阶段/任务完成时追加一条工作日志，按天+按项目分组总结",
        Some("{\"payload\":{\"task\":\"string\",\"status\":\"string\",\"outcome\":\"string\",\"decisions\":\"string\",\"next\":\"string\"},\"tags\":{\"proj\":\"string\",\"branch\":\"string\"}}"),
        levels, None, true, None, nowMs(), summaryGroupBy: Some(groupBy))
    if (registry.has("worklog")) {
        // 旧版本 worklog 缺 summaryGroupBy → 升级补齐（保留原 levels/描述等字段）
        match (registry.get("worklog")) {
            case Some(old) =>
                if (old.summaryGroupBy.isNone()) {
                    registry.updateMeta(meta)
                }
            case None => ()
        }
        return
    }
    registry.create(meta)
}

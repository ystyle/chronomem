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

    // 磁盘库（测试/嵌入用；与 open 不同：不播种 worklog、不做 LLM 装配）
    // memTableSize 4MB（arena 8MB）：测试并发多库，默认 16MB 会在默认 256MB GC 堆下 OOM
    public static func openFile(dir: String, summarizer!: Option<Summarizer> = None, timeZone!: TimeZone = TimeZone.Local): MemoryService {
        let store = TimelineStore.open(dir, timeZone: timeZone, memTableSize: 4 * 1024 * 1024u64)
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

    // 注册优雅退出（docker stop / Ctrl+C）：SIGINT/SIGTERM → 先停后台总结执行器
    // （防止其继续写已关闭的 tsdb），再由 badger 信号路径优雅关闭 tsdb（flush 全部
    // memtable 落盘，数据不丢），exitAfterClose=true（默认）时 close 后退出进程
    // （docker stop 语义）。
    // 与 atExit（仅正常退出路径触发）互补——容器场景 atExit 不执行，靠这里兜底。
    // 库不主动注册——main 入口调用一次即可；非 Linux 平台 no-op（badger-cj 条件编译）。
    public func registerSignalShutdown(exitAfterClose!: Bool = true): Unit {
        let tsdb = this.store.rawTsdb()
        tsdb.registerShutdownHook({ =>
            println("chronomem: signal shutdown, stopping summarize runner")
            match (this.summarizeRunner) {
                case Some(r) => r.stop()
                case None => ()
            }
        })
        tsdb.registerSignalShutdown(exitAfterClose: exitAfterClose)
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

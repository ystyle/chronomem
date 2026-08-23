package chronomem.mcp

import chronomem.core.*
import std.fs.*
import std.time.TimeZone

// 忆时塔内存引擎：类型注册表 + 时序库 + 可选语义总结器。
// 存储根 = cfg.dir/tsdb（一个 tsdb 库承载全部 <type> 与 <type>.summary）。
// 自然时间窗口时区由 cfg.timeZoneId 决定（空 = 本地时区，§5.2）。
public class MemoryService {
    public let store: TimelineStore
    public let registry: MemoryTypeRegistry
    public let summarizer: Option<Summarizer>

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
        let summarizer = Summarizer.fromSettings(
            LlmSettings(cfg.llmBaseUrl, cfg.llmApiKey, cfg.llmModel, cfg.llmProvider))
        MemoryService(store, registry, summarizer)
    }

    // 内存库（测试用）
    public static func openInMemory(summarizer!: Option<Summarizer> = None, timeZone!: TimeZone = TimeZone.Local): MemoryService {
        let store = TimelineStore.openInMemory(timeZone: timeZone)
        let registry = MemoryTypeRegistry(store)
        MemoryService(store, registry, summarizer)
    }

    public func close(): Unit { this.store.close() }
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

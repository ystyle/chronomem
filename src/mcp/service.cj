package chronomem.mcp

import chronomem.core.*
import std.fs.*

// 忆时塔内存引擎：类型注册表 + 时序库 + 可选语义总结器。
// 存储根 = cfg.dir/tsdb（一个 tsdb 库承载全部 <type> 与 <type>.summary）。
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
        let store = TimelineStore.open(tsdbDir)
        let registry = MemoryTypeRegistry(store)
        let summarizer = Summarizer.fromSettings(
            LlmSettings(cfg.llmBaseUrl, cfg.llmApiKey, cfg.llmModel, cfg.llmProvider))
        MemoryService(store, registry, summarizer)
    }

    // 内存库（测试用）
    public static func openInMemory(summarizer!: Option<Summarizer> = None): MemoryService {
        let store = TimelineStore.openInMemory()
        let registry = MemoryTypeRegistry(store)
        MemoryService(store, registry, summarizer)
    }

    public func close(): Unit { this.store.close() }
}

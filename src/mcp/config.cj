package chronomem.mcp

import std.env.*
import std.fs.*
import std.convert.*

// 忆时塔配置：环境变量解析（CHRONOLOG_DIR / CHRONOLOG_ADDR / CHRONOLOG_PORT / LLM_*）。
// 默认值：目录 ~/.chronolog，绑定 127.0.0.1（本地安全；容器/远程需 CHRONOLOG_ADDR=0.0.0.0），端口 8900，
// LLM 走 OpenAI 兼容端点（LLM_PROVIDER=openai/anthropic/ollama）。
public class ChronomemConfig {
    public let dir: String
    public let addr: String
    public let port: UInt16
    public let llmBaseUrl: String
    public let llmApiKey: String
    public let llmModel: String
    public let llmProvider: String
    public let timeZoneId: String
    public let materializeCron: String
    public let summaryCron: String
    public let summaryMaxPerRun: Int64
    public let summarySettleMs: Int64
    public let seedWorklog: Bool
    public let uiPort: UInt16
    public let uiEnabled: Bool
    public let gcThresholdMb: Int64
    // badger memTableSize（MB）：4MB → arena 8MB，同步 flush 峰值 ~50MB，默认 256MB
    // GC 堆内安全。曾默认 16MB（arena 32MB）：flush 峰值实测 ~170MB 活对象顶爆堆
    // → OOM → 写路径全断（忆时塔两次生产事故，见 fix/memtable-size-oom）。
    public let memTableSizeMb: Int64
    // 总结请求口径（透传给 core 的 LlmSettings，见 core/summarizer.cj 的说明）：
    // noThink=关推理模型的思考（默认 true），summaryMaxTokens=输出上限（默认 4096）。
    public let summaryNoThink: Bool
    public let summaryMaxTokens: Int64
    // 输入预算（见 core/summarizer.cj 的 DEFAULT_SUMMARY_*）：端点上下文是每模型 preset
    // 决定的（qwen3.5-9b-mtp=32768、qwen3.5-4b=131072），客户端必须知道才能不撞 400。
    public let summaryContextTokens: Int64
    public let summarySafetyTokens: Int64
    public let summaryBytesPerToken: Int64
    public let summaryMaxCalls: Int64
    // 单次调用的输入上限（token）：上下文大 ≠ 一次调用就能做那么大——
    // 实测 4b prefill ~317 tok/s，205K 字节的块（≈68K token）会撞 llm_api 的 300s 读超时。
    public let summaryCallTokens: Int64
    // llm_api 单次读超时（秒）
    public let summaryReadTimeoutSeconds: Int64
    // 调度器护栏：同一窗口连续失败多少次后停止自动重试（10 分钟一轮无限重试会白烧 LLM）
    public let summaryMaxAttempts: Int64
    // 堆水位 dump 钩子：堆占用超过该百分比时主动 dumpHeapData（0 = 关闭）。
    // 存在的理由：生产上观察到的是「堆贴顶摆动」而非溢出——cjHeapDumpOnOOM 不会触发，
    // 于是内存泄漏最需要证据时反而没有 dump。此钩子按水位主动取证。
    public let heapDumpThresholdPct: Int64
    // dump 检查间隔（秒）与冷却（秒）：冷却避免连续 dump 把磁盘写满
    public let heapDumpCheckSeconds: Int64
    public let heapDumpCooldownSeconds: Int64

    public init(dir: String, addr: String, port: UInt16, llmBaseUrl: String,
        llmApiKey: String, llmModel: String, llmProvider: String,
        timeZoneId: String, materializeCron: String, summaryCron: String,
        summaryMaxPerRun: Int64, summarySettleMs: Int64, seedWorklog: Bool,
        uiPort!: UInt16 = 8901, uiEnabled!: Bool = true, gcThresholdMb!: Int64 = 64,
        memTableSizeMb!: Int64 = 4, summaryNoThink!: Bool = true,
        summaryMaxTokens!: Int64 = 4096, summaryContextTokens!: Int64 = 32768,
        summarySafetyTokens!: Int64 = 1024, summaryBytesPerToken!: Int64 = 2,
        summaryMaxCalls!: Int64 = 8, summaryMaxAttempts!: Int64 = 3,
        summaryCallTokens!: Int64 = 40000, summaryReadTimeoutSeconds!: Int64 = 300,
        heapDumpThresholdPct!: Int64 = 0, heapDumpCheckSeconds!: Int64 = 60,
        heapDumpCooldownSeconds!: Int64 = 3600) {
        this.dir = dir
        this.addr = addr
        this.port = port
        this.llmBaseUrl = llmBaseUrl
        this.llmApiKey = llmApiKey
        this.llmModel = llmModel
        this.llmProvider = llmProvider
        this.timeZoneId = timeZoneId
        this.materializeCron = materializeCron
        this.summaryCron = summaryCron
        this.summaryMaxPerRun = summaryMaxPerRun
        this.summarySettleMs = summarySettleMs
        this.seedWorklog = seedWorklog
        this.uiPort = uiPort
        this.uiEnabled = uiEnabled
        this.gcThresholdMb = gcThresholdMb
        this.memTableSizeMb = memTableSizeMb
        this.summaryNoThink = summaryNoThink
        this.summaryMaxTokens = summaryMaxTokens
        this.summaryContextTokens = summaryContextTokens
        this.summarySafetyTokens = summarySafetyTokens
        this.summaryBytesPerToken = summaryBytesPerToken
        this.summaryMaxCalls = summaryMaxCalls
        this.summaryMaxAttempts = summaryMaxAttempts
        this.summaryCallTokens = summaryCallTokens
        this.summaryReadTimeoutSeconds = summaryReadTimeoutSeconds
        this.heapDumpThresholdPct = heapDumpThresholdPct
        this.heapDumpCheckSeconds = heapDumpCheckSeconds
        this.heapDumpCooldownSeconds = heapDumpCooldownSeconds
    }

    // 从进程环境变量构造（测试可通过 setVariable/removeVariable 控制）
    public static func fromEnv(): ChronomemConfig {
        let dir = envOr("CHRONOLOG_DIR", defaultDir())
        var port = UInt16(8900)
        match (getVariable("CHRONOLOG_PORT")) {
            case Some(v) => port = UInt16(Int64.parse(v))
            case None => ()
        }
        ChronomemConfig(
            dir,
            envOr("CHRONOLOG_ADDR", "127.0.0.1"),
            port,
            envOr("LLM_BASE_URL", ""),
            envOr("LLM_API_KEY", ""),
            envOr("LLM_MODEL", ""),
            envOr("LLM_PROVIDER", "openai"),
            envOr("CHRONOLOG_TIMEZONE", ""),
            envOr("CHRONOLOG_MATERIALIZE_CRON", "@every 1m"),
            envOr("CHRONOLOG_SUMMARY_CRON", "*/10 * * * *"),
            envIntOr("CHRONOLOG_SUMMARY_MAX_PER_RUN", 5),
            envIntOr("CHRONOLOG_SUMMARY_SETTLE", 600000),
            envBoolOr("CHRONOLOG_SEED_WORKLOG", true),
            uiPort: envUInt16Or("CHRONOLOG_UI_PORT", 8901),
            uiEnabled: envBoolOr("CHRONOLOG_UI_ENABLED", true),
            gcThresholdMb: envIntOr("CHRONOLOG_GC_THRESHOLD_MB", 64),
            memTableSizeMb: envIntOr("CHRONOLOG_MEMTABLE_SIZE_MB", 4),
            summaryNoThink: envBoolOr("CHRONOLOG_SUMMARY_NO_THINK", true),
            summaryMaxTokens: envIntOr("CHRONOLOG_SUMMARY_MAX_TOKENS", 4096),
            summaryContextTokens: envIntOr("CHRONOLOG_SUMMARY_CONTEXT_TOKENS", 32768),
            summarySafetyTokens: envIntOr("CHRONOLOG_SUMMARY_SAFETY_TOKENS", 1024),
            summaryBytesPerToken: envIntOr("CHRONOLOG_SUMMARY_BYTES_PER_TOKEN", 2),
            summaryMaxCalls: envIntOr("CHRONOLOG_SUMMARY_MAX_CALLS", 8),
            summaryMaxAttempts: envIntOr("CHRONOLOG_SUMMARY_MAX_ATTEMPTS", 3),
            summaryCallTokens: envIntOr("CHRONOLOG_SUMMARY_CALL_TOKENS", 40000),
            summaryReadTimeoutSeconds: envIntOr("CHRONOLOG_SUMMARY_READ_TIMEOUT", 300),
            heapDumpThresholdPct: envIntOr("CHRONOLOG_HEAP_DUMP_THRESHOLD_PCT", 0),
            heapDumpCheckSeconds: envIntOr("CHRONOLOG_HEAP_DUMP_CHECK_SECONDS", 60),
            heapDumpCooldownSeconds: envIntOr("CHRONOLOG_HEAP_DUMP_COOLDOWN_SECONDS", 3600))
    }

    // 语义总结可用性：未配置 baseURL/model 时 summarize 应报错（其余工具不依赖 LLM）
    public func hasLlmConfig(): Bool {
        this.llmBaseUrl != "" && this.llmModel != ""
    }
}

func envUInt16Or(name: String, fallback: UInt16): UInt16 {
    match (getVariable(name)) {
        case Some(v) =>
            if (v == "") { fallback } else { try { UInt16(Int64.parse(v)) } catch (_) { fallback } }
        case None => fallback
    }
}

func envIntOr(name: String, fallback: Int64): Int64 {
    match (getVariable(name)) {
        case Some(v) =>
            if (v == "") { fallback } else { try { Int64.parse(v) } catch (_) { fallback } }
        case None => fallback
    }
}

func envBoolOr(name: String, fallback: Bool): Bool {
    match (getVariable(name)) {
        case Some(v) =>
            if (v == "true" || v == "1" || v == "yes") { true }
            else if (v == "false" || v == "0" || v == "no") { false }
            else { fallback }
        case None => fallback
    }
}

func envOr(name: String, fallback: String): String {
    match (getVariable(name)) {
        case Some(v) => if (v == "") { fallback } else { v }
        case None => fallback
    }
}

func defaultDir(): String {
    match (getVariable("HOME")) {
        case Some(h) => h + "/.chronolog"
        case None => ".chronolog"
    }
}

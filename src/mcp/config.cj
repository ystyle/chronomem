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

    public init(dir: String, addr: String, port: UInt16, llmBaseUrl: String,
        llmApiKey: String, llmModel: String, llmProvider: String,
        timeZoneId: String, materializeCron: String, summaryCron: String,
        summaryMaxPerRun: Int64, summarySettleMs: Int64, seedWorklog: Bool) {
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
            envBoolOr("CHRONOLOG_SEED_WORKLOG", true))
    }

    // 语义总结可用性：未配置 baseURL/model 时 summarize 应报错（其余工具不依赖 LLM）
    public func hasLlmConfig(): Bool {
        this.llmBaseUrl != "" && this.llmModel != ""
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

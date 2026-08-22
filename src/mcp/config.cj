package chronomem.mcp

import std.env.*
import std.fs.*
import std.convert.*

// 忆时塔配置：环境变量解析（CHRONOLOG_DIR / CHRONOLOG_PORT / LLM_*）。
// 默认值：目录 ~/.chronolog，端口 8900，LLM 走 OpenAI 兼容端点（LLM_PROVIDER=openai/anthropic/ollama）。
public class ChronomemConfig {
    public let dir: String
    public let port: UInt16
    public let llmBaseUrl: String
    public let llmApiKey: String
    public let llmModel: String
    public let llmProvider: String

    public init(dir: String, port: UInt16, llmBaseUrl: String,
        llmApiKey: String, llmModel: String, llmProvider: String) {
        this.dir = dir
        this.port = port
        this.llmBaseUrl = llmBaseUrl
        this.llmApiKey = llmApiKey
        this.llmModel = llmModel
        this.llmProvider = llmProvider
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
            dir, port,
            envOr("LLM_BASE_URL", ""),
            envOr("LLM_API_KEY", ""),
            envOr("LLM_MODEL", ""),
            envOr("LLM_PROVIDER", "openai"))
    }

    // 语义总结可用性：未配置 baseURL/model 时 summarize 应报错（其余工具不依赖 LLM）
    public func hasLlmConfig(): Bool {
        this.llmBaseUrl != "" && this.llmModel != ""
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

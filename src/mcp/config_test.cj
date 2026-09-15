package chronomem.mcp

import std.env.*

// 配置解析单测：默认值 / 覆盖 / LLM 可用性判定。
// 注意：setVariable 会改进程 env，测试结尾 removeVariable 清理，避免影响其它用例。

@Test
func chronomem_config_defaults() {
    removeVariable("CHRONOLOG_DIR")
    removeVariable("CHRONOLOG_ADDR")
    removeVariable("CHRONOLOG_PORT")
    removeVariable("LLM_BASE_URL")
    removeVariable("LLM_API_KEY")
    removeVariable("LLM_MODEL")
    removeVariable("LLM_PROVIDER")
    removeVariable("CHRONOLOG_TIMEZONE")
    removeVariable("CHRONOLOG_MATERIALIZE_CRON")
    removeVariable("CHRONOLOG_SUMMARY_CRON")
    removeVariable("CHRONOLOG_SUMMARY_MAX_PER_RUN")
    removeVariable("CHRONOLOG_SUMMARY_SETTLE")
    removeVariable("CHRONOLOG_SEED_WORKLOG")
    removeVariable("CHRONOLOG_GC_THRESHOLD_MB")
    removeVariable("CHRONOLOG_MEMTABLE_SIZE_MB")
    removeVariable("CHRONOLOG_SUMMARY_NO_THINK")
    removeVariable("CHRONOLOG_SUMMARY_MAX_TOKENS")
    removeVariable("CHRONOLOG_SUMMARY_CONTEXT_TOKENS")
    removeVariable("CHRONOLOG_SUMMARY_SAFETY_TOKENS")
    removeVariable("CHRONOLOG_SUMMARY_BYTES_PER_TOKEN")
    removeVariable("CHRONOLOG_SUMMARY_MAX_CALLS")
    removeVariable("CHRONOLOG_SUMMARY_MAX_ATTEMPTS")

    let cfg = ChronomemConfig.fromEnv()
    @Expect(cfg.port, UInt16(8900))
    @Expect(cfg.addr, "127.0.0.1")
    @Expect(cfg.llmProvider, "openai")
    @Expect(cfg.hasLlmConfig(), false)
    @Expect(cfg.timeZoneId, "")
    @Expect(cfg.materializeCron, "@every 1m")
    @Expect(cfg.summaryCron, "*/10 * * * *")
    @Expect(cfg.summaryMaxPerRun, Int64(5))
    @Expect(cfg.summarySettleMs, Int64(600000))
    @Expect(cfg.seedWorklog, true)
    @Expect(cfg.gcThresholdMb, Int64(64))
    // memTableSize 默认 4MB：16MB（arena 32MB）同步 flush 峰值在默认 256MB GC 堆下
    // OOM（忆时塔两次生产事故根因，见 fix/memtable-size-oom）
    @Expect(cfg.memTableSizeMb, Int64(4))
    // 总结口径默认：关思考 + 4096 输出上限（本地推理端点：开思考时大窗口会撞 300s 读超时）
    @Expect(cfg.summaryNoThink, true)
    @Expect(cfg.summaryMaxTokens, Int64(4096))
    // 输入预算默认：按 9b-mtp 的 ctx=32768 保守取值（4b 的 131072 由部署侧 env 覆盖）
    @Expect(cfg.summaryContextTokens, Int64(32768))
    @Expect(cfg.summarySafetyTokens, Int64(1024))
    @Expect(cfg.summaryBytesPerToken, Int64(2))
    @Expect(cfg.summaryMaxCalls, Int64(8))
    @Expect(cfg.summaryMaxAttempts, Int64(3))
    match (getVariable("HOME")) {
        case Some(h) => @Expect(cfg.dir, h + "/.chronolog")
        case None => @Expect(cfg.dir, ".chronolog")
    }
}

@Test
func chronomem_config_override() {
    setVariable("CHRONOLOG_DIR", "/tmp/chronomem_cfg")
    setVariable("CHRONOLOG_ADDR", "0.0.0.0")
    setVariable("CHRONOLOG_PORT", "9100")
    setVariable("LLM_BASE_URL", "http://127.0.0.1:11434/v1")
    setVariable("LLM_API_KEY", "k")
    setVariable("LLM_MODEL", "qwen3")
    setVariable("CHRONOLOG_TIMEZONE", "Asia/Shanghai")
    setVariable("CHRONOLOG_MATERIALIZE_CRON", "@every 30s")
    setVariable("CHRONOLOG_SUMMARY_CRON", "0 0 * * *")
    setVariable("CHRONOLOG_SUMMARY_MAX_PER_RUN", "2")
    setVariable("CHRONOLOG_SUMMARY_SETTLE", "30000")
    setVariable("CHRONOLOG_SEED_WORKLOG", "false")
    setVariable("CHRONOLOG_GC_THRESHOLD_MB", "128")
    setVariable("CHRONOLOG_MEMTABLE_SIZE_MB", "8")
    setVariable("CHRONOLOG_SUMMARY_NO_THINK", "false")
    setVariable("CHRONOLOG_SUMMARY_MAX_TOKENS", "8192")
    setVariable("CHRONOLOG_SUMMARY_CONTEXT_TOKENS", "131072")
    setVariable("CHRONOLOG_SUMMARY_SAFETY_TOKENS", "2048")
    setVariable("CHRONOLOG_SUMMARY_BYTES_PER_TOKEN", "3")
    setVariable("CHRONOLOG_SUMMARY_MAX_CALLS", "12")
    setVariable("CHRONOLOG_SUMMARY_MAX_ATTEMPTS", "5")

    let cfg = ChronomemConfig.fromEnv()
    @Expect(cfg.dir, "/tmp/chronomem_cfg")
    @Expect(cfg.addr, "0.0.0.0")
    @Expect(cfg.port, UInt16(9100))
    @Expect(cfg.llmBaseUrl, "http://127.0.0.1:11434/v1")
    @Expect(cfg.llmApiKey, "k")
    @Expect(cfg.llmModel, "qwen3")
    @Expect(cfg.hasLlmConfig(), true)
    @Expect(cfg.timeZoneId, "Asia/Shanghai")
    @Expect(cfg.materializeCron, "@every 30s")
    @Expect(cfg.summaryCron, "0 0 * * *")
    @Expect(cfg.summaryMaxPerRun, Int64(2))
    @Expect(cfg.summarySettleMs, Int64(30000))
    @Expect(cfg.seedWorklog, false)
    @Expect(cfg.gcThresholdMb, Int64(128))
    @Expect(cfg.memTableSizeMb, Int64(8))
    @Expect(cfg.summaryNoThink, false)
    @Expect(cfg.summaryMaxTokens, Int64(8192))
    @Expect(cfg.summaryContextTokens, Int64(131072))
    @Expect(cfg.summarySafetyTokens, Int64(2048))
    @Expect(cfg.summaryBytesPerToken, Int64(3))
    @Expect(cfg.summaryMaxCalls, Int64(12))
    @Expect(cfg.summaryMaxAttempts, Int64(5))

    removeVariable("CHRONOLOG_DIR")
    removeVariable("CHRONOLOG_ADDR")
    removeVariable("CHRONOLOG_PORT")
    removeVariable("LLM_BASE_URL")
    removeVariable("LLM_API_KEY")
    removeVariable("LLM_MODEL")
    removeVariable("CHRONOLOG_TIMEZONE")
    removeVariable("CHRONOLOG_MATERIALIZE_CRON")
    removeVariable("CHRONOLOG_SUMMARY_CRON")
    removeVariable("CHRONOLOG_SUMMARY_MAX_PER_RUN")
    removeVariable("CHRONOLOG_SUMMARY_SETTLE")
    removeVariable("CHRONOLOG_SEED_WORKLOG")
    removeVariable("CHRONOLOG_GC_THRESHOLD_MB")
    removeVariable("CHRONOLOG_MEMTABLE_SIZE_MB")
    removeVariable("CHRONOLOG_SUMMARY_NO_THINK")
    removeVariable("CHRONOLOG_SUMMARY_MAX_TOKENS")
    removeVariable("CHRONOLOG_SUMMARY_CONTEXT_TOKENS")
    removeVariable("CHRONOLOG_SUMMARY_SAFETY_TOKENS")
    removeVariable("CHRONOLOG_SUMMARY_BYTES_PER_TOKEN")
    removeVariable("CHRONOLOG_SUMMARY_MAX_CALLS")
    removeVariable("CHRONOLOG_SUMMARY_MAX_ATTEMPTS")
}

@Test
func chronomem_config_llm_missing_any_is_not_ready() {
    // 只有 baseURL 没有 model → 不可用
    setVariable("LLM_BASE_URL", "http://x")
    removeVariable("LLM_MODEL")
    let cfg = ChronomemConfig.fromEnv()
    @Expect(cfg.hasLlmConfig(), false)
    removeVariable("LLM_BASE_URL")
}

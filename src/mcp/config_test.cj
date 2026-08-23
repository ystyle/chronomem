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

package chronomem.mcp

import std.env.*

// 配置解析单测：默认值 / 覆盖 / LLM 可用性判定。
// 注意：setVariable 会改进程 env，测试结尾 removeVariable 清理，避免影响其它用例。

@Test
func chronomem_config_defaults() {
    removeVariable("CHRONOLOG_DIR")
    removeVariable("CHRONOLOG_PORT")
    removeVariable("LLM_BASE_URL")
    removeVariable("LLM_API_KEY")
    removeVariable("LLM_MODEL")
    removeVariable("LLM_PROVIDER")

    let cfg = ChronomemConfig.fromEnv()
    @Expect(cfg.port, UInt16(8900))
    @Expect(cfg.llmProvider, "openai")
    @Expect(cfg.hasLlmConfig(), false)
    match (getVariable("HOME")) {
        case Some(h) => @Expect(cfg.dir, h + "/.chronolog")
        case None => @Expect(cfg.dir, ".chronolog")
    }
}

@Test
func chronomem_config_override() {
    setVariable("CHRONOLOG_DIR", "/tmp/chronomem_cfg")
    setVariable("CHRONOLOG_PORT", "9100")
    setVariable("LLM_BASE_URL", "http://127.0.0.1:11434/v1")
    setVariable("LLM_API_KEY", "k")
    setVariable("LLM_MODEL", "qwen3")

    let cfg = ChronomemConfig.fromEnv()
    @Expect(cfg.dir, "/tmp/chronomem_cfg")
    @Expect(cfg.port, UInt16(9100))
    @Expect(cfg.llmBaseUrl, "http://127.0.0.1:11434/v1")
    @Expect(cfg.llmApiKey, "k")
    @Expect(cfg.llmModel, "qwen3")
    @Expect(cfg.hasLlmConfig(), true)

    removeVariable("CHRONOLOG_DIR")
    removeVariable("CHRONOLOG_PORT")
    removeVariable("LLM_BASE_URL")
    removeVariable("LLM_API_KEY")
    removeVariable("LLM_MODEL")
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

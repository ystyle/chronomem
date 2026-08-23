package chronomem.mcp

import chronomem.core.*
import std.env.getProcessId

// 开箱即用默认类型测试：worklog 启动自动播种（幂等）+ CHRONOLOG_SEED_WORKLOG=false 可关。

func seedCfgOf(dir: String): ChronomemConfig {
    ChronomemConfig(dir, "127.0.0.1", UInt16(8900), "", "", "", "openai",
        "", "@every 1m", "*/10 * * * *", 5, 600000, true)
}

@Test
func service_openSeedsWorklog() {
    let path = "/tmp/chronomem_seed_test_" + getProcessId().toString()
    let svc = MemoryService.open(seedCfgOf(path))
    @Expect(svc.registry.has("worklog"), true)
    match (svc.registry.get("worklog")) {
        case Some(m) =>
            @Expect(m.levels.size, Int64(2))
            @Expect(m.levels[0], "day")
            @Expect(m.levels[1], "week")
            @Expect(m.autoSummarize, true)
        case None => @Fail("worklog 未播种")
    }
    svc.close()
    // 幂等：重开不重复播种
    let svc2 = MemoryService.open(seedCfgOf(path))
    @Expect(svc2.registry.has("worklog"), true)
    @Expect(svc2.registry.list().size, Int64(1))
    svc2.close()
}

@Test
func service_seedDisabled() {
    let path = "/tmp/chronomem_seed_off_" + getProcessId().toString()
    let cfg = ChronomemConfig(path, "127.0.0.1", UInt16(8900), "", "", "", "openai",
        "", "@every 1m", "*/10 * * * *", 5, 600000, false)
    let svc = MemoryService.open(cfg)
    @Expect(svc.registry.has("worklog"), false)
    svc.close()
}

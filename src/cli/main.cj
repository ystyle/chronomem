package chronomem.cli

import chronomem.core.{MaterializeScheduler, HeapDumpWatcher}
import chronomem.mcp.*
import mcp.*
import mcp.transport.*
import std.env.atExit
import std.runtime.*
import stdx.log.LogLevel
import stdx.net.http.*
import tang.compose.ComposeDistributor

// 忆时塔入口：`chronomem.cli serve` —— 常驻 streamable HTTP MCP 守护进程。
// 单端口合并：MCP 挂 /mcp，Web UI（cjxt）占根路径空间（fallback）。
main() {
    let cfg = ChronomemConfig.fromEnv()
    // GC 阈值调优（防长期运行堆逼近 256MB 上限导致写路径 OOM，见 fix/gc-heap-oom）：
    // 默认 64MB —— GC 提前触发回收，堆水位稳定在低位（实测 125~135MB，余量 120MB+），
    // 不再依赖"堆逼近上限才 GC"的默认策略。setGCThreshold 单位 KB。
    setGCThreshold(UInt64(cfg.gcThresholdMb) * 1024)
    let svc = MemoryService.open(cfg)
    // 启动一次性堆配置日志（诊断用，不打日志的进程可忽略；验证 GC 阈值生效）
    println("chronomem gcThreshold=" + cfg.gcThresholdMb.toString() + "MB maxHeap=" +
        (getMaxHeapSize() / 1048576).toString() + "MB")
    // 优雅退出（docker stop / Ctrl+C 语义，badger-cj ≥ 1.6.8）：SIGTERM → 停后台总结
    // 执行器 → tsdb close（flush 落盘）→ exit(0)。容器场景 atExit 不触发，靠这里兜底；
    // 数据持久化另有 syncWrites=true 兜底（SIGKILL 也不丢）。
    svc.registerSignalShutdown()
    // 正常退出路径兜底（main 返回 / std.env.exit，close 幂等）
    atExit({ =>
        println("chronomem atExit: closing store")
        svc.close()
    })
    // 后台结构物化（cron 墙钟，默认 @every 1m；零 LLM、幂等、空窗口零成本）
    let scheduler = MaterializeScheduler(svc.store)
    scheduler.start(spec: cfg.materializeCron)
    // 后台自动语义总结（cron，默认 */10 * * * *；仅 opt-in 类型；未配置 LLM 或 maxPerRun<=0 时不开）
    if (svc.summarizer.isSome() && cfg.summaryMaxPerRun > 0) {
        let sumScheduler = SummarizeScheduler.fromConfig(svc, cfg)
        sumScheduler.start(spec: cfg.summaryCron)
    }
    // 堆水位看护（默认关闭；CHRONOLOG_HEAP_DUMP_THRESHOLD_PCT>0 开启）：
    // 堆贴顶摆动不会触发 cjHeapDumpOnOOM，内存问题最需要现场时反而没有 dump，
    // 故按水位主动取证。见 docs/incidents/2026-10-16-mcp-unresponsive.md。
    let heapWatcher = HeapDumpWatcher(cfg.heapDumpThresholdPct, cfg.heapDumpCheckSeconds,
        cfg.heapDumpCooldownSeconds, cfg.dir)
    if (heapWatcher.enabled()) {
        heapWatcher.start()
        println("chronomem heapDump: threshold=" + cfg.heapDumpThresholdPct.toString() +
            "%, check=" + cfg.heapDumpCheckSeconds.toString() + "s, cooldown=" +
            cfg.heapDumpCooldownSeconds.toString() + "s, dir=" + cfg.dir)
    }
    // 组合分发器：MCP 挂 /mcp，UI（如启用）占根路径
    let transport = SessionHttpServerTransport()
    let compose = ComposeDistributor()
        .mount("/mcp", McpRouteDistributor(transport))
    if (cfg.uiEnabled) {
        // UI 与 MCP 同端口：页面/静态/WS 走根路径，MCP 走 /mcp（页面直接调 svc，无 HTTP 开销）
        let uiApp = buildUiApp(svc, cfg)
        compose.setFallback(uiApp.router())
    }
    let httpServer = ServerBuilder()
        .addr(cfg.addr)
        .port(cfg.port)
        .distributor(compose)
        .build()
    // 关闭 stdx http server 的 WARN 级连接日志（Socket is closed / Broken pipe 等噪音，
    // 其它语言 HTTP 服务器不打这类日志；仅保留 ERROR/FATAL）
    httpServer.logger.level = LogLevel.ERROR
    let mcpServer = buildServer(transport, svc)
    mcpServer.start()
    if (cfg.uiEnabled) {
        println("忆时塔 chronomem 监听 http://" + cfg.addr + ":" + cfg.port.toString() + "（MCP: /mcp, UI: /）存储 " + cfg.dir)
    } else {
        println("忆时塔 chronomem 监听 http://" + cfg.addr + ":" + cfg.port.toString() + "/mcp（存储 " + cfg.dir + "）")
    }
    httpServer.serve()
}

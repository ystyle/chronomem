package chronomem.cli

import chronomem.core.MaterializeScheduler
import chronomem.mcp.*
import mcp.*
import mcp.transport.*
import std.env.atExit
import stdx.log.LogLevel
import stdx.net.http.*
import tang.compose.ComposeDistributor

// 忆时塔入口：`chronomem.cli serve` —— 常驻 streamable HTTP MCP 守护进程。
// 单端口合并：MCP 挂 /mcp，Web UI（cjxt）占根路径空间（fallback）。
main() {
    let cfg = ChronomemConfig.fromEnv()
    let svc = MemoryService.open(cfg)
    // 优雅关闭尝试：atExit 只在正常退出/部分信号时触发（docker SIGTERM 是否触发待实测），
    // 数据持久化已由 syncWrites=true 兜底（SIGKILL 也不丢）
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
    // 组合分发器：MCP 挂 /mcp，UI（如启用）占根路径
    let transport = SessionHttpServerTransport()
    let compose = ComposeDistributor()
        .mount("/mcp", McpRouteDistributor(transport))
    if (cfg.uiEnabled) {
        // UI 与 MCP 同端口：页面/静态/WS 走根路径，MCP 走 /mcp（页面直接调 svc，无 HTTP 开销）
        let uiApp = buildUiApp(svc, cfg.addr)
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

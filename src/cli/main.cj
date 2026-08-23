package chronomem.cli

import chronomem.core.MaterializeScheduler
import chronomem.mcp.*
import mcp.*
import mcp.transport.*
import std.env.atExit
import stdx.net.http.*

// 忆时塔入口：`chronomem.cli serve` —— 常驻 streamable HTTP MCP 守护进程。
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
    let httpServer = ServerBuilder()
        .addr(cfg.addr)
        .port(cfg.port)
        .build()
    let transport = SessionHttpServerTransport()
    transport.registerRoutes(httpServer.distributor)
    let mcpServer = buildServer(transport, svc)
    mcpServer.start()
    println("忆时塔 chronomem 监听 http://" + cfg.addr + ":" + cfg.port.toString() + "（存储 " + cfg.dir + "）")
    httpServer.serve()
}

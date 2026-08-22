package chronomem.cli

import chronomem.core.MaterializeScheduler
import chronomem.mcp.*
import mcp.*
import mcp.transport.*
import stdx.net.http.*

// 忆时塔入口：`chronomem.cli serve` —— 常驻 streamable HTTP MCP 守护进程。
main() {
    let cfg = ChronomemConfig.fromEnv()
    let svc = MemoryService.open(cfg)
    // 后台结构物化（每 60s，零 LLM；幂等、空窗口零成本）
    let scheduler = MaterializeScheduler(svc.store)
    spawn { => scheduler.run() }
    let httpServer = ServerBuilder()
        .addr("127.0.0.1")
        .port(cfg.port)
        .build()
    let transport = SessionHttpServerTransport()
    transport.registerRoutes(httpServer.distributor)
    let mcpServer = buildServer(transport, svc)
    mcpServer.start()
    println("忆时塔 chronomem 监听 http://127.0.0.1:" + cfg.port.toString() + "（存储 " + cfg.dir + "）")
    httpServer.serve()
}

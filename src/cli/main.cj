package chronomem.cli

import chronomem.mcp.*
import mcp.*
import mcp.transport.*
import stdx.net.http.*

// 忆时塔入口：`chronomem.cli serve` —— 常驻 streamable HTTP MCP 守护进程。
main() {
    let cfg = ChronomemConfig.fromEnv()
    let httpServer = ServerBuilder()
        .addr("127.0.0.1")
        .port(cfg.port)
        .build()
    let transport = SessionHttpServerTransport()
    transport.registerRoutes(httpServer.distributor)
    let mcpServer = buildServer(transport, cfg)
    mcpServer.start()
    println("忆时塔 chronomem 监听 http://127.0.0.1:" + cfg.port.toString())
    httpServer.serve()
}

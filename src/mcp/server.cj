package chronomem.mcp

import mcp.*
import mcp.transport.*

// 构建 MCP 服务器：注册 mem/* 工具（see handlers.registerTools）+ 挂 streamable HTTP 路由。
public func buildServer(transport: SessionHttpServerTransport, svc: MemoryService): McpServer {
    let server = McpServer("chronomem", "0.1.0", transport)
    server.instructions = "忆时塔：分层时间记忆（回想 + 语义总结）"
    registerTools(server, svc)
    server
}

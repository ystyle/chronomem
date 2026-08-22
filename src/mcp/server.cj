package chronomem.mcp

import jsonvalue.*
import mcp.*
import mcp.transport.*
import std.collection.*

// 构建 MCP 服务器：注册 mem/* 工具 + 挂 streamable HTTP 路由。
// Phase 0：占位 mem/ping 验证连通；后续 Phase 3 在此注册完整工具集。
public func buildServer(transport: SessionHttpServerTransport, cfg: ChronomemConfig): McpServer {
    let server = McpServer("chronomem", "0.1.0", transport)
    server.instructions = "忆时塔：分层时间记忆（回想 + 语义总结）"

    let schema = ToolInputSchema("object", HashMap<String, JsonValue>(), [])
    let ping = Tool("mem/ping", "连通性检查：返回 pong", schema)
    server.addTool(ping, { params =>
        CallToolResult.text("pong")
    })
    server
}

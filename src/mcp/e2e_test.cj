package chronomem.mcp

import jsonvalue.*
import mcp.*
import mcp.transport.*
import ystyle::jsonrpc.Result
import std.collection.*
import std.sync.*
import stdx.net.http.*

// 端口占位（afterBind 回填临时端口）
class PortHolder {
    var value: UInt16 = 0
}

// Phase 0 连通性 e2e：起 streamable HTTP server → MCP client 连接 → tools/list 拿到 mem/ping。
@Test
func chronomem_e2e_connectAndListTools() {
    let portLock = Mutex()
    let portCond = synchronized(portLock) { portLock.condition() }
    let holder = PortHolder()

    let httpServer = ServerBuilder()
        .addr("127.0.0.1")
        .port(0)
        .build()
    httpServer.afterBind({ =>
        synchronized(portLock) {
            holder.value = httpServer.port
            portCond.notifyAll()
        }
    })

    let transport = SessionHttpServerTransport()
    transport.registerRoutes(httpServer.distributor)
    let cfg = ChronomemConfig("/tmp/chronomem_e2e", UInt16(8900), "", "", "", "openai")
    let mcpServer = buildServer(transport, cfg)
    mcpServer.start()
    spawn { => httpServer.serve() }

    synchronized(portLock) {
        while (holder.value == 0) {
            portCond.wait(timeout: 5 * Duration.second)
        }
    }

    let baseUrl = "http://127.0.0.1:" + holder.value.toString()
    let client = McpClient(SessionHttpClientTransport(baseUrl))
    match (client.connect(Implementation("chronomem-test", "1.0.0"))) {
        case Result.Ok(initResult) => @Expect(initResult.serverInfo.name, "chronomem")
        case Result.Err(e) => @Fail("connect 失败: " + e.toString())
    }
    match (client.listTools()) {
        case Result.Ok(result) =>
            var found = false
            for (t in result.tools) {
                if (t.name == "mem/ping") { found = true }
            }
            @Expect(found, true)
        case Result.Err(e) => @Fail("listTools 失败: " + e.toString())
    }
    // 顺手验证 mem/ping 可调用
    match (client.callTool("mem/ping", arguments: HashMap<String, JsonValue>())) {
        case Result.Ok(result) =>
            var text = ""
            for (c in result.content) {
                match (c) {
                    case ContentBlock.Text(tc) => text = tc.text
                    case _ => ()
                }
            }
            @Expect(text, "pong")
        case Result.Err(e) => @Fail("callTool(mem/ping) 失败: " + e.toString())
    }

    client.close()
    transport.close()
    httpServer.close()
}

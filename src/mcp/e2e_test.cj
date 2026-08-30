package chronomem.mcp

import chronomem.core.*
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

// Phase 0 连通性 e2e：起 streamable HTTP server → MCP client 连接 → tools/list → type_create 往返。
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
    let svc = MemoryService.openFile(freshTestDir())
    let mcpServer = buildServer(transport, svc)
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
    // tools/list：真实工具集已注册
    match (client.listTools()) {
        case Result.Ok(result) =>
            var foundCreate = false
            var foundRecall = false
            var foundSummarize = false
            for (t in result.tools) {
                if (t.name == "mem/type_create") { foundCreate = true }
                if (t.name == "mem/recall") { foundRecall = true }
                if (t.name == "mem/summarize") { foundSummarize = true }
            }
            @Expect(foundCreate, true)
            @Expect(foundRecall, true)
            @Expect(foundSummarize, true)
        case Result.Err(e) => @Fail("listTools 失败: " + e.toString())
    }
    // type_create → list_types 往返
    let createArgs = HashMap<String, JsonValue>()
    createArgs.add("name", JsonValue.String("e2e/worklog"))
    createArgs.add("levels", JsonValue.parse("[\"day\",\"week\"]"))
    match (client.callTool("mem/type_create", arguments: createArgs)) {
        case Result.Ok(result) =>
            var text = ""
            for (c in result.content) {
                match (c) {
                    case ContentBlock.Text(tc) => text = tc.text
                    case _ => ()
                }
            }
            @Expect(text.indexOf("已创建") != None, true)
        case Result.Err(e) => @Fail("type_create 失败: " + e.toString())
    }
    match (client.callTool("mem/list_types", arguments: HashMap<String, JsonValue>())) {
        case Result.Ok(result) =>
            var text = ""
            for (c in result.content) {
                match (c) {
                    case ContentBlock.Text(tc) => text = tc.text
                    case _ => ()
                }
            }
            @Expect(text.indexOf("e2e/worklog") != None, true)
        case Result.Err(e) => @Fail("list_types 失败: " + e.toString())
    }

    client.close()
    transport.close()
    httpServer.close()
}

package chronomem.mcp

import chronomem.core.*
import jsonvalue.*
import mcp.*
import mcp.transport.*
import ystyle::jsonrpc.Result
import std.collection.*
import std.sync.*
import stdx.net.http.*
import tang.compose.ComposeDistributor

class FullPortHolder {
    var value: UInt16 = 0
}

func callAndText(client: McpClient, name: String, args: HashMap<String, JsonValue>): String {
    match (client.callTool(name, arguments: args)) {
        case Result.Ok(result) =>
            let sb = StringBuilder()
            for (c in result.content) {
                match (c) {
                    case ContentBlock.Text(tc) => sb.append(tc.text)
                    case _ => ()
                }
            }
            sb.toString()
        case Result.Err(e) => "ERROR: " + e.toString()
    }
}

// Phase 4 全链路 e2e：type_create → append → query → recall(exact/summary) → buckets → summarize → summaries。
@Test
func chronomem_e2e_fullFlow() {
    let portLock = Mutex()
    let portCond = synchronized(portLock) { portLock.condition() }
    let holder = FullPortHolder()

    // 与生产一致：ComposeDistributor 组合，MCP 挂 /mcp
    let transport = SessionHttpServerTransport()
    let compose = ComposeDistributor()
        .mount("/mcp", McpRouteDistributor(transport))
    let httpServer = ServerBuilder()
        .addr("127.0.0.1")
        .port(0)
        .distributor(compose)
        .build()
    httpServer.afterBind({ =>
        synchronized(portLock) {
            holder.value = httpServer.port
            portCond.notifyAll()
        }
    })
    let svc = MemoryService.openFile(freshTestDir(), 
        summarizer: Some(Summarizer(FakeSummarizerProvider("决策：A\n结论：B"), "fake")))
    let mcpServer = buildServer(transport, svc)
    mcpServer.start()
    spawn { => httpServer.serve() }

    synchronized(portLock) {
        while (holder.value == 0) {
            portCond.wait(timeout: 5 * Duration.second)
        }
    }

    let client = McpClient(SessionHttpClientTransport("http://127.0.0.1:" + holder.value.toString() + "/mcp"))
    match (client.connect(Implementation("chronomem-e2e", "1.0.0"))) {
        case Result.Ok(_) => ()
        case Result.Err(e) => @Fail("connect 失败: " + e.toString())
    }

    // 1. type_create
    let create = callAndText(client, "mem/type_create", argsFromJson("{\"name\":\"e2e/log\"}"))
    @Expect(create.indexOf("已创建类型 e2e/log") != None, true)

    // 2. append 3 条（同一 10min 窗口）
    callAndText(client, "mem/append", argsFromJson("{\"type\":\"e2e/log\",\"payload\":{\"step\":1},\"ts\":1704110400000}"))
    callAndText(client, "mem/append", argsFromJson("{\"type\":\"e2e/log\",\"payload\":{\"step\":2},\"ts\":1704110460000}"))
    callAndText(client, "mem/append", argsFromJson("{\"type\":\"e2e/log\",\"payload\":{\"step\":3},\"ts\":1704110520000}"))
    @Expect(svc.registry.countEntries("e2e/log"), Int64(3))

    // 3. query（结构回想，零 LLM）
    let q = callAndText(client, "mem/query", argsFromJson("{\"type\":\"e2e/log\",\"limit\":2}"))
    @Expect(q.indexOf("step") != None, true)

    // 4. 物化（测试直调；生产由 MaterializeScheduler 每 60s 自动）
    svc.store.materializeAll(TEST_BASE)

    // 5. recall exact（精确下钻）
    let rec = callAndText(client, "mem/recall",
        argsFromJson("{\"type\":\"e2e/log\",\"granularity\":\"10min\",\"windowStartMs\":1704110400000}"))
    @Expect(rec.indexOf("step") != None, true)

    // 6. buckets（物化桶发现）
    let buckets = callAndText(client, "mem/buckets", argsFromJson("{\"type\":\"e2e/log\",\"granularity\":\"10min\"}"))
    @Expect(buckets.indexOf("10min") != None, true)

    // 7. summarize（异步提交后台任务 → fake LLM → 落 summary series）
    let sum = callAndText(client, "mem/summarize",
        argsFromJson("{\"type\":\"e2e/log\",\"from\":1704110400000,\"to\":1704110999999}"))
    @Expect(sum.indexOf("已提交后台总结任务") != None, true)
    @Expect(svc.summarizeRunner.getOrThrow().waitIdle(), true)

    // 8. recall mode=summary（语义回顾 → 返回已生成摘要）
    let sumRec = callAndText(client, "mem/recall",
        argsFromJson("{\"type\":\"e2e/log\",\"granularity\":\"10min\",\"windowStartMs\":1704110400000,\"mode\":\"summary\"}"))
    @Expect(sumRec.indexOf("决策：A") != None, true)

    // 9. summaries（总结记录列表）
    let sums = callAndText(client, "mem/summaries", argsFromJson("{\"type\":\"e2e/log\"}"))
    @Expect(sums.indexOf("决策：A") != None, true)

    client.close()
    transport.close()
    httpServer.close()
}

// HTTP 报文总长预检（fix/append-size-limit）：>MAX_MCP_BODY_BYTES 的 POST 在
// distributor 层凭 Content-Length 直接 413（零 body 读零解析）——病态大报文
// 即使被业务限长拒绝，parse 阶段的瞬时分配仍会顶爆 256MB GC 堆（生产 OOM
// 卡死防线）。业务限长（256KB 单条 payload）见 handlers_appendSizeLimit。
@Test
func chronomem_e2e_bodyLimitReject413() {
    let portLock = Mutex()
    let portCond = synchronized(portLock) { portLock.condition() }
    let holder = FullPortHolder()

    let transport = SessionHttpServerTransport()
    let compose = ComposeDistributor()
        .mount("/mcp", McpRouteDistributor(transport))
    let httpServer = ServerBuilder()
        .addr("127.0.0.1")
        .port(0)
        .distributor(compose)
        .build()
    httpServer.afterBind({ =>
        synchronized(portLock) {
            holder.value = httpServer.port
            portCond.notifyAll()
        }
    })
    let svc = MemoryService.openFile(freshTestDir())
    let mcpServer = buildServer(transport, svc)
    mcpServer.start()
    spawn { => httpServer.serve() }

    synchronized(portLock) {
        while (holder.value == 0) {
            portCond.wait(timeout: 5 * Duration.second)
        }
    }

    let client = ClientBuilder().build()
    // 超限（600KB > 512KB）：413 快速拒绝
    let big = StringBuilder()
    for (i in 0..(MAX_MCP_BODY_BYTES + 100 * 1024)) {
        big.append("x")
    }
    let req413 = HttpRequestBuilder()
        .url("http://127.0.0.1:" + holder.value.toString() + "/mcp")
        .header("content-type", "application/json")
        .body(big.toString())
        .post()
        .build()
    let resp413 = client.send(req413)
    @Expect(resp413.status, 413)
    // 未超限（300KB < 512KB）：放行到 MCP（无效 jsonrpc 也走处理 → 非 413）
    let mid = StringBuilder()
    for (i in 0..(300 * 1024)) {
        mid.append("x")
    }
    let reqOk = HttpRequestBuilder()
        .url("http://127.0.0.1:" + holder.value.toString() + "/mcp")
        .header("content-type", "application/json")
        .body(mid.toString())
        .post()
        .build()
    let respOk = client.send(reqOk)
    @Expect(respOk.status != 413, true)

    transport.close()
    httpServer.close()
    svc.close()
}

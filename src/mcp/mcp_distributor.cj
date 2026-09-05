package chronomem.mcp

import mcp.transport.SessionHttpServerTransport
import std.convert.*
import stdx.net.http.{HttpRequestDistributor, HttpRequestHandler, HttpContext, FuncHandler}

// MCP HTTP 报文总上限（字节，Content-Length 预检用）：业务单条 payload 限长 256KB
// （MAX_APPEND_PAYLOAD_BYTES）+ JSON/MCP 包装后 ~300KB 内，512KB 留足余量。超过即
// 413——不读 body 不解析，防病态大报文顶爆 GC 堆（见 McpRouteDistributor 注释）。
public let MAX_MCP_BODY_BYTES = Int64(512 * 1024)

/// MCP transport → HttpRequestDistributor 适配
///
/// `StreamableHttpServer` 的单一入口 handler 按 method 分发（GET→SSE、POST→POST、DELETE→DELETE），
/// 不匹配路径。本适配把 transport 包装成 `HttpRequestDistributor`，
/// `distribute()` 总是返回其单一入口 handler，供
/// `tang.compose.ComposeDistributor` 组合（MCP 挂 `/mcp` 前缀、UI 等占其余路径）。
public class McpRouteDistributor <: HttpRequestDistributor {
    let transport: SessionHttpServerTransport

    public init(transport: SessionHttpServerTransport) {
        this.transport = transport
    }

    public func register(path: String, handler: HttpRequestHandler): Unit {
        ()
    }

    public func register(path: String, handler: (HttpContext) -> Unit): Unit {
        ()
    }

    public func distribute(path: String): HttpRequestHandler {
        let inner = this.transport.asHandler()
        FuncHandler({ ctx => this.dispatchBodyLimited(ctx, inner) })
    }

    // Content-Length 预检（生产 OOM 防线，fix/append-size-limit）：病态大 body
    // （950KB 级）即使被业务限长拒绝，其 parse/拷贝仍会瞬时顶爆默认 256MB GC 堆
    // （实测 GCReason:oom allocated ~210MB）→ OOM → 请求悬挂。仅读请求头即快速
    // 413，零 body 读取、零 JSON 解析。业务层另有单条 payload 256KB 限长
    // （MAX_APPEND_PAYLOAD_BYTES），此处 512KB 为 HTTP 报文总上限（含 JSON 包装）。
    private func dispatchBodyLimited(ctx: HttpContext, inner: HttpRequestHandler): Unit {
        match (ctx.request.headers.getFirst("Content-Length")) {
            case Some(v) =>
                var len: Int64 = 0
                try {
                    len = Int64.parse(v)
                } catch (_: Exception) {
                    len = 0
                }
                if (len > MAX_MCP_BODY_BYTES) {
                    ctx.responseBuilder.status(413)
                        .header("content-type", "text/plain")
                        .body("Request body too large (max " + (MAX_MCP_BODY_BYTES / 1024).toString() + "KB)")
                    return
                }
            case None => ()
        }
        inner.handle(ctx)
    }
}

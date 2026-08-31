package chronomem.mcp

import mcp.transport.SessionHttpServerTransport
import stdx.net.http.{HttpRequestDistributor, HttpRequestHandler, HttpContext}

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
        this.transport.asHandler()
    }
}

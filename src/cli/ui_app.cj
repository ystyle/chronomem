// 忆时塔 Web UI · App 装配（package chronomem.cli）
// 与 MCP 服务同进程、同端口（单端口合并）：UI 占根路径空间，MCP 挂 /mcp。
// 页面渲染/动作直接调用 MemoryService（同进程直连，不经 HTTP）。
package chronomem.cli

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import chronomem.mcp.MemoryService

// UI 静态资源目录（构建期由 @importCSS/手工维护；运行时相对 cwd = chronomem/）
public let UI_CSS_DIR = "public/css"
public let UI_CSS = "/css/ui.css?v=2"

/// 构建 UI App（注册全部路由到 tang Router），不 serve —— 供单端口合并使用
/// （tang.compose.ComposeDistributor：UI 作为 fallback 占根路径）
public func buildUiApp(svc: MemoryService, host: String): App {
    uiSvc = Some(svc)
    let app = App()
        .configure(AppConfig(
            title: "忆时塔 chronomem · Web 控制台",
            primaryColor: "#3ec5e8",
            fontFamily: "-apple-system, \"PingFang SC\", \"Noto Sans SC\", \"Microsoft YaHei\", sans-serif",
            borderRadius: "7px",
            cssBundle: UI_CSS))
        .UseComponent()
        .serveStatic("/css", "public/css")
        .host(host)
    app.setupRoutes()
    app
}

/// 独立端口模式（旧）：构建并启动 UI 服务（阻塞，供 spawn 线程调用）
public func serveUi(svc: MemoryService, host: String, port: UInt16): Unit {
    let app = buildUiApp(svc, host)
    app.port(port)
    println("忆时塔 UI 监听 http://" + host + ":" + port.toString())
    app.serve()
}

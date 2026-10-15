// 忆时塔 Web UI · App 装配（package chronomem.cli）
// 与 MCP 服务同进程、同端口（单端口合并）：UI 占根路径空间，MCP 挂 /mcp。
// 页面渲染/动作直接调用 MemoryService（同进程直连，不经 HTTP）。
package chronomem.cli

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import chronomem.mcp.MemoryService
import chronomem.mcp.ChronomemConfig
import std.env.getVariable

// UI 静态资源目录（构建期由 @importCSS/手工维护；运行时相对 cwd = chronomem/）
public let UI_CSS_DIR = "public/css"
public let UI_CSS = "/css/ui.css?v=9"

/// 构建 UI App（注册全部路由到 tang Router），不 serve —— 供单端口合并使用
/// （tang.compose.ComposeDistributor：UI 作为 fallback 占根路径）
public func buildUiApp(svc: MemoryService, cfg: ChronomemConfig): App {
    uiSvc = Some(svc)
    // 运行时信息注入：头部端点与侧栏存储目录取真实配置。
    // 硬编码会在非默认端口（隔离测试实例、容器映射）下显示错误信息。
    uiRuntimeInfo = Some((cfg.addr + ":" + cfg.port.toString(), shortenHome(cfg.dir)))
    let app = App()
        .configure(AppConfig(
            title: "忆时塔 chronomem · Web 控制台",
            primaryColor: "#3ec5e8",
            fontFamily: "-apple-system, \"PingFang SC\", \"Noto Sans SC\", \"Microsoft YaHei\", sans-serif",
            borderRadius: "7px",
            cssBundle: UI_CSS))
        .UseComponent()
        .serveStatic("/css", "public/css")
        .host(cfg.addr)
    app.setupRoutes()
    app
}

/// 把 HOME 前缀缩写为 ~（侧栏展示用）
func shortenHome(dir: String): String {
    match (getVariable("HOME")) {
        case Some(h) => if (h != "" && dir.startsWith(h)) { "~" + dir[h.size..dir.size] } else { dir }
        case None => dir
    }
}

/// 独立端口模式（旧）：构建并启动 UI 服务（阻塞，供 spawn 线程调用）
public func serveUi(svc: MemoryService, cfg: ChronomemConfig): Unit {
    let app = buildUiApp(svc, cfg)
    app.port(cfg.uiPort)
    println("忆时塔 UI 监听 http://" + cfg.addr + ":" + cfg.uiPort.toString())
    app.serve()
}

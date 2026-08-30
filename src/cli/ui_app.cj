// 忆时塔 Web UI · App 装配（package chronomem.cli）
// 与 MCP 服务同进程：spawn 独立线程跑 cjxt App（UI 端口 CHRONOLOG_UI_PORT，默认 8901），
// 页面渲染/动作直接调用 MemoryService（同进程直连，不经 HTTP）。
package chronomem.cli

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import chronomem.mcp.MemoryService

// UI 静态资源目录（构建期由 @importCSS/手工维护；运行时相对 cwd = chronomem/）
public let UI_CSS_DIR = "public/css"
public let UI_CSS = "/css/ui.css?v=1"

// 构建并启动 UI 服务（阻塞，供 spawn 线程调用）
public func serveUi(svc: MemoryService, host: String, port: UInt16): Unit {
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
        .port(port)
    println("忆时塔 UI 监听 http://" + host + ":" + port.toString())
    app.serve()
}

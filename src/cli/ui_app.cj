// 忆时塔 Web UI · App 装配（package chronomem.cli）
// 与 MCP 服务同进程、同端口（单端口合并）：UI 占根路径空间，MCP 挂 /mcp。
// 页面渲染/动作直接调用 MemoryService（同进程直连，不经 HTTP）。
package chronomem.cli

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import chronomem.mcp.MemoryService
import chronomem.mcp.ChronomemConfig
import embed.macros.*
import std.env.getVariable

// 控制台样式：编译期嵌入二进制。
//
// 此前是 `.serveStatic("/css", "public/css")` —— 相对路径按**进程 cwd** 解析。
// 从仓库根跑 target/release/bin 时成立，但发行版装到 ~/.local/bin 之后，
// 从任意目录启动都找不到 public/css：控制台白屏（页面框架在、样式全丢），
// 而 MCP 端点照常可用，症状很像"服务坏了"。
//
// 用 @EmbedString 而不是 cjxt 的 @importCSS：后者会给每个类名加 `<hash>` 后缀
// 并返回 CssModule 映射，而本项目的 UI 里类名全是字面量（a("ui-card")），
// 不查映射，套上去 244 个选择器与 105 处引用会同时失效。
// 内嵌后是单文件分发：不需要 public/ 伴生目录，发行产物从两个 tar 减到一个。
let UI_CSS_TEXT = @EmbedString("public/css/ui.css")

/// 构建 UI App（注册全部路由到 tang Router），不 serve —— 供单端口合并使用
/// （tang.compose.ComposeDistributor：UI 作为 fallback 占根路径）
public func buildUiApp(svc: MemoryService, cfg: ChronomemConfig): App {
    uiSvc = Some(svc)
    // 运行时信息注入：头部端点与侧栏监听项取真实配置。
    // 硬编码会在非默认端口（隔离测试实例、容器映射）下显示错误信息。
    // 存的是**绑定地址**（0.0.0.0 = 所有网卡），展示由 listenDisplay 按绑定语义渲染
    // —— 0.0.0.0 不是可访问目标，不能直接当服务地址显示。
    uiRuntimeInfo = Some((cfg.addr, cfg.port, shortenHome(cfg.dir)))
    let app = App()
        .configure(AppConfig(
            title: "忆时塔 chronomem · Web 控制台",
            primaryColor: "#3ec5e8",
            fontFamily: "-apple-system, \"PingFang SC\", \"Noto Sans SC\", \"Microsoft YaHei\", sans-serif",
            borderRadius: "7px"))
        .UseComponent()
        .addCSS(UI_CSS_TEXT)
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

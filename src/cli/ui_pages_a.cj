// 忆时塔 Web UI · 页面（1/2）：布局导航 + 总览 + 塔视图 + 回想（双模式）
// @Page 类必须在主包（chronomem.cli，含 main）——RouteRegistry 顶层注册只会在主包执行。
// 交互状态一律 Signal<T>（cjxt 脏追踪只认 Signal 订阅；普通字段+ReRender 不会产生补丁）。

package chronomem.cli

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import chronomem.ui.*
import chronomem.core.*
import chronomem.mcp.MemoryService
import tsdb.{Point, BucketMeta, BucketRecord}
import std.collection.{ArrayList, HashMap, HashSet}
import std.time.TimeZone
import std.convert.*
import std.sort.*

// ==================== 布局 ====================

public let UI_VERSION = "1.1"

public let UI_NAV: Array<(String, String, String)> = [
    ("/", "overview", "总览"),
    ("/tower", "tower", "塔视图"),
    ("/recall", "recall", "回想"),
    ("/summary", "summary", "语义总结"),
    ("/types", "types", "记忆类型"),
    ("/append", "append", "追加条目"),
]

public func uiNoGuard(_: HashMap<String, String>): Option<String> { None }

// 布局 = 页面内调用：页面 render() 顶层包 uiLayout(activePath, content)，
// 重渲染整树自带 header/侧栏（框架 @Page layout 参数会在发送时二次套层，替换根时丢菜单）
public func uiLayout(activePath: String, page: IComponent): IComponent {
    let children = ArrayList<IComponent>()
    children.add(uiHeader())
    children.add(uiSide(activePath))
    children.add(div([div([page], attrs: Some(a("ui-page")))], attrs: Some(a("ui-main"))))
    div(children.toArray(), attrs: Some(a("ui-shell")))
}

// 运行时信息（UI 头部/侧栏展示）：由 buildUiApp 注入，
// 不再硬编码 —— 端口挡位/存储目录在测试实例、容器部署下与默认值不同，
// 写死会误导使用者（曾在隔离实例上显示生产端口）。
public var uiRuntimeInfo: ?(String, String) = None   // (endpoint, storageDir)

func uiEndpointText(): String {
    match (uiRuntimeInfo) {
        case Some((ep, _)) => ep
        case None => "127.0.0.1:8900"
    }
}

func uiStorageText(): String {
    match (uiRuntimeInfo) {
        case Some((_, dir)) => dir
        case None => "~/.chronolog"
    }
}

func uiHeader(): IComponent {
    let svc = svc()
    let llmLive = uiLlmLive(svc)
    let llmModel = uiLlmModel(svc)
    let status = ArrayList<IComponent>()
    status.add(htmlSpan("<span class=\"ui-pill\"><span class=\"dot ok\"></span>服务 " + esc(uiEndpointText()) + " · MCP 在线</span>"))
    if (llmLive) {
        status.add(htmlSpan("<span class=\"ui-pill\"><span class=\"dot ok\"></span>LLM " + esc(llmModel) + " 已配置</span>"))
    } else {
        status.add(htmlSpan("<span class=\"ui-pill\"><span class=\"dot warn\"></span>LLM 未配置（总结不可用）</span>"))
    }
    status.add(htmlSpan("<span class=\"ui-pill\">UI v" + UI_VERSION + "</span>"))
    let brand = ArrayList<IComponent>()
    brand.add(htmlSpan("<svg width=\"30\" height=\"30\" viewBox=\"0 0 30 30\" fill=\"none\"><path d=\"M15 2 L19 7 H11 Z\" fill=\"#3ec5e8\"/><rect x=\"7\" y=\"9\" width=\"16\" height=\"5\" rx=\"1.4\" fill=\"#5a8df0\"/><rect x=\"4\" y=\"16\" width=\"22\" height=\"6\" rx=\"1.6\" fill=\"#8a7af0\"/><rect x=\"1\" y=\"24\" width=\"28\" height=\"6\" rx=\"1.8\" fill=\"#e0a15a\"/></svg>"))
    brand.add(htmlSpan("<span class=\"cn\">忆时塔</span> <span class=\"en\">chronomem</span><div class=\"sub\">分层时间记忆 · Web 控制台</div>"))
    div([
        div(brand.toArray(), attrs: Some(a("ui-brand"))),
        div(status.toArray(), attrs: Some(a("ui-head-status"))),
    ], attrs: Some(a("ui-header")))
}

func uiSide(activePath0: String): IComponent {
    let children = ArrayList<IComponent>()
    for ((path, key, label) in UI_NAV) {
        let active = activePath0 == key
        var cls = "ui-nav"
        if (active) { cls = "ui-nav active" }
        var icon = "◈"
        match (key) {
            case "tower" => icon = "▲"
            case "recall" => icon = "⌕"
            case "summary" => icon = "☰"
            case "types" => icon = "▤"
            case "append" => icon = "＋"
            case _ => icon = "◈"
        }
        let m = HashMap<String, String>()
        m.add("class", cls)
        let nav = div([
            htmlSpan("<span style=\"width:17px;text-align:center;flex:none\">" + icon + "</span>"),
            text(label),
        ], attrs: Some(m))
        let handled = nav.onClick({ ctx =>
            ctx.route.push(path)
            PatchResult.ReRender
        })
        children.add(handled)
    }
    let info = ArrayList<IComponent>()
    info.add(htmlSpan("<div class=\"row\"><span>存储目录</span><b title=\"" + esc(uiStorageText()) + "\">" + esc(uiStorageText()) + "</b></div>"))
    info.add(htmlSpan("<div class=\"row\"><span>结构物化</span><b>@every 1m</b></div>"))
    info.add(htmlSpan("<div class=\"row\"><span>自动总结</span><b>*/10 * * * *</b></div>"))
    children.add(div(info.toArray(), attrs: Some(a("ui-side-info"))))
    div(children.toArray(), attrs: Some(a("ui-side")))
}

// ==================== 总览 ====================

@Page["/", "总览", uiNoGuard]
public class OverviewPage <: Component {
    public init() {}

    public func render(): IComponent {
        let svc = svc()
        let types = uiListTypes(svc)
        var totalEntries = Int64(0)
        var totalSummaries = Int64(0)
        for (m in types) {
            totalEntries += uiCount(svc, m.name)
            totalSummaries += uiSummaries(svc, m.name, 1).size
        }
        let llmLive = uiLlmLive(svc)
        let stats = ArrayList<IComponent>()
        stats.add(statCard("记忆类型", types.size.toString(), "独立 series", "#3ec5e8"))
        stats.add(statCard("原始条目", totalEntries.toString(), "append 累积", "#5a8df0"))
        stats.add(statCard("语义总结", totalSummaries.toString(), "分组窗口摘要", "#8a7af0"))
        stats.add(statCard("LLM 能力", if (llmLive) { "在线" } else { "未配置" }, if (llmLive) { uiLlmModel(svc) } else { "总结不可用" }, "#e0a15a"))

        let children = ArrayList<IComponent>()
        for (__it in pageTitle("总览", "忆时塔替你的工具保存时序记忆：一条条经历按时间堆叠成塔，越久越粗、越久越高；需要时沿塔层精确下钻（零 LLM）或调用语义回顾（LLM 摘要）。")) { children.add(__it) }
        children.add(statRow(stats))
        let typeChildren = ArrayList<IComponent>()
        typeChildren.add(cardTitle("记忆类型", "type = 一条独立 series，各自建塔"))
        if (types.size == 0) {
            typeChildren.add(emptyBox("暂无记忆类型，去「记忆类型」页创建"))
        } else {
            for (m in types) {
                typeChildren.add(typeCard(m, uiCount(svc, m.name)))
            }
        }
        children.add(div(typeChildren.toArray(), attrs: Some(a("ui-card"))))
        let flow = ArrayList<IComponent>()
        flow.add(cardTitle("最近条目流", "最新 10 条 · 点击进入塔视图下钻"))
        var added = Int64(0)
        for (m in types) {
            if (added >= 10) { break }
            let pts = uiQuery(svc, m.name, 0, 0, 10 - added, "", "")
            for (p in pts) {
                if (added >= 10) { break }
                let meta = payloadMeta(p.payload)
                let tags2 = parseTags(p.tags)
                var proj = ""
                for ((k, v) in tags2) {
                    if (k == "proj") { proj = v }
                }
                flow.add(timeflowItem(p.ts, meta, proj, tags2))
                added += 1
            }
        }
        children.add(div(flow.toArray(), attrs: Some(a("ui-card"))))
        uiLayout("overview", div(children.toArray(), attrs: Some(a("ui-page"))))
    }
}

// ==================== 塔视图 ====================

@Page["/tower", "塔视图", uiNoGuard]
public class TowerPage <: Component {
    var selType = Signal<String>("")
    var selGran = Signal<String>("day")
    var selBucket = Signal<String>("")
    // 选中条目的详情（全字段视图）；None = 未打开
    var detailPoint = Signal<Option<Point>>(Option<Point>.None)

    public init() {}

    func ensureSel(svc: MemoryService): Unit {
        if (this.selType.get() == "") {
            let types = uiListTypes(svc)
            if (types.size > 0) { this.selType.set(types[0].name) }
        }
        match (uiGetType(svc, this.selType.get())) {
            case Some(m) =>
                let levels = sortLevels(m.levels)
                if (levels.size > 0 && !levels.contains(this.selGran.get())) {
                    this.selGran.set(levels[0])
                }
            case None => ()
        }
    }

    public func render(): IComponent {
        let svc = svc()
        this.ensureSel(svc)
        if (this.selType.get() == "") {
            return uiLayout("tower", div([
                htmlSpan("<div class=\"ui-title\">塔视图</div>"),
                emptyBox("暂无记忆类型，无法建塔"),
            ], attrs: Some(a("ui-page"))))
        }
        let meta = uiGetType(svc, this.selType.get()).getOrThrow()
        let levels = sortLevels(meta.levels)

        // 类型选择（EP Select）
        let typeOptions = ArrayList<IComponent>()
        for (t in uiListTypes(svc)) {
            typeOptions.add(SelectOption([text(t.name)], t.name))
        }
        let typeSelect = Select(typeOptions.toArray())
            .placeholder("选择记忆类型")
            .bind(this.selType)

        // 塔层（全链展示：未配置层禁用；桶统计走轻量 metas，不构造 refs 对象）
        let layers = ArrayList<IComponent>()
        let revOrder = ["week", "day", "1h", "30min", "10min"]
        for (level in revOrder) {
            let enabled = levels.contains(level)
            let bucketCount = if (enabled) { uiListBucketMetas(svc, this.selType.get(), level).size } else { Int64(0) }
            let active = enabled && level == this.selGran.get()
            let h: Option<ActionHandler> = if (enabled) {
                Some({ ctx =>
                    this.selGran.set(level)
                    this.selBucket.set("")
                    PatchResult.ReRender
                })
            } else { None }
            layers.add(towerLayer(level, levelLabel(level), levelSub(level),
                if (enabled) { bucketCount.toString() } else { "未配置" }, enabled, active, h))
        }

        // 桶（轻量 metas：refsCount 来自解码计数，零 extra 查询）
        let buckets = if (levels.contains(this.selGran.get())) { uiListBucketMetas(svc, this.selType.get(), this.selGran.get()) } else { ArrayList<BucketMeta>() }
        let bucketChildren = ArrayList<IComponent>()
        bucketChildren.add(cardTitle(this.selGran.get() + " · 时间桶", "点击下钻原始条目"))
        if (buckets.size == 0) {
            bucketChildren.add(emptyBox("该粒度暂无物化桶（结构物化每分钟跑一次，空窗口不建桶）"))
        } else {
            let grid = ArrayList<IComponent>()
            for (b in buckets) {
                // 桶条数 = refsCount（PointRef 直点 / BucketRef 子桶），轻量解码零对象构造
                let cnt = b.refsCount
                grid.add(bucketCard(b.bucketKey, this.selGran.get(), cnt, b.bucketKey == this.selBucket.get(), { ctx =>
                    this.selBucket.set(b.bucketKey)
                    PatchResult.ReRender
                }))
            }
            bucketChildren.add(div(grid.toArray(), attrs: Some(a("ui-bucket-grid"))))
        }

        let mainCol = ArrayList<IComponent>()
        for (__it in pageTitle("塔视图", "沿粒度层下钻时间桶 → 精确回想原始条目")) { mainCol.add(__it) }
        let pick = ArrayList<IComponent>()
        pick.add(div([typeSelect], attrs: Some(a("ui-field"))))
        mainCol.add(div(pick.toArray(), attrs: Some(a("ui-card"))))
        mainCol.add(div([
            htmlSpan("<div class=\"ui-tower-cap\">时间之塔 · TIME MEMORY TOWER</div>"),
            htmlSpan("<div class=\"ui-tower-top\"></div>"),
            div(layers.toArray(), attrs: Some(a("ui-tower-center"))),
            htmlSpan("<div class=\"ui-tower-base\"></div>"),
            htmlSpan("<div class=\"ui-tower-legend\"><span>越久越粗</span><span>·</span><span>越久越高</span><span>·</span><span>层间可下钻</span></div>"),
        ], attrs: Some(a("ui-tower"))))
        mainCol.add(div(bucketChildren.toArray(), attrs: Some(a("ui-card"))))

        let drill = this.drillPanel(svc, meta, buckets)
        let pageChildren = ArrayList<IComponent>()
        pageChildren.add(div([
            div(mainCol.toArray(), attrs: Some(a("ui-tower-left"))),
            drill,
        ], attrs: Some(a("ui-tower-grid"))))
        // 条目详情弹窗（全字段）
        match (this.detailPoint.get()) {
            case Some(_) => pageChildren.add(this.detailDialog())
            case None => ()
        }
        uiLayout("tower", div(pageChildren.toArray(), attrs: Some(a("ui-page"))))
    }

    func drillPanel(svc: MemoryService, meta: TypeMeta, buckets: ArrayList<BucketMeta>): IComponent {
        let children = ArrayList<IComponent>()
        if (this.selBucket.get() == "") {
            children.add(htmlSpan("<div class=\"ui-crumb\">← 点击左侧时间桶，下钻原始条目</div>"))
            children.add(emptyBox("选择桶后，此处展示该窗口内的原始条目（按引用链精确下钻，零 LLM）"))
        } else {
            let points = uiDrillDown(svc, this.selType.get(), this.selGran.get(), this.selBucket.get())
            let label = bucketLocalLabel(this.selBucket.get(), this.selGran.get(), svc.store.timeZoneOf())
            children.add(htmlSpan("<div class=\"ui-crumb\"><b>" + esc(this.selType.get()) + "</b> › <b>" + esc(this.selGran.get()) + "</b> › 桶 " + esc(label) +
                " · <span class=\"ui-mono\">" + esc(this.selBucket.get()) + "</span> · <b style=\"color:var(--accent)\">" + points.size.toString() + " 条</b></div>"))
            for (p in points) {
                children.add(this.drillPointCard(p))
            }
            if (points.size == 0) {
                children.add(emptyBox("该桶暂无原始条目"))
            }
        }
        div(children.toArray(), attrs: Some(a("ui-drill")))
    }

    // 下钻条目：卡片 + 「详情」入口（全字段/全文；面板窄，长内容必须有出口）
    func drillPointCard(p: Point): IComponent {
        let card = ArrayList<IComponent>()
        card.add(pointCard(p))
        card.add(div([
            modalButton("详情 · 全部字段", "sm ghost", { ctx =>
                this.detailPoint.set(Some(p))
                PatchResult.ReRender
            }),
        ], attrs: Some(a("ui-point-actions"))))
        div(card.toArray(), attrs: Some(a("ui-point-wrap")))
    }

    // 条目详情弹窗（与回想页共用同一 Signal 语义）
    func detailDialog(): IComponent {
        match (this.detailPoint.get()) {
            case Some(p) =>
                let close = modalButton("关闭", "ghost", { ctx =>
                    this.detailPoint.set(Option<Point>.None)
                    PatchResult.ReRender
                })
                modalShell("条目详情 · " + payloadTaskOf(p), itemDetailBody(p), [close], true)
            case None => EmptyVNode()
        }
    }
}

// ==================== 回想（双模式） ====================

@Page["/recall", "回想", uiNoGuard]
public class RecallPage <: Component {
    var mode = Signal<String>("raw")
    var qType = Signal<String>("")
    var sGran = Signal<String>("day")
    var sBucket = Signal<String>("")
    var sGroup = Signal<String>("all")
    var qFrom = Signal<String>("")
    var qTo = Signal<String>("")
    var qTag = Signal<String>("")
    var qLimit = Signal<String>("20")
    // 选中条目的详情（全字段视图）；None = 未打开
    var detailPoint = Signal<Option<Point>>(Option<Point>.None)

    public init() {}

    func ensureType(svc: MemoryService): Unit {
        if (this.qType.get() == "") {
            let types = uiListTypes(svc)
            if (types.size > 0) { this.qType.set(types[0].name) }
        }
    }

    public func render(): IComponent {
        let svc = svc()
        this.ensureType(svc)
        let children = ArrayList<IComponent>()
        for (__it in pageTitle("回想", "两档回想：精确回想直查原始条目（零 LLM）；语义回顾按粒度窗口读语义摘要（决策/结论/待办），依赖该窗口已总结过。")) { children.add(__it) }
        let rawPane = TabPane([this.renderRaw(svc)], "raw", "精确回想 · 原始条目")
        let sumPane = TabPane([this.renderSummaryMode(svc)], "summary", "语义回顾 · 窗口摘要")
        children.add(div([Tabs([rawPane, sumPane]).bind(this.mode)], attrs: Some(a("ui-tabs-wrap"))))
        // 条目详情弹窗（全字段 + 全文展开）
        match (this.detailPoint.get()) {
            case Some(p) =>
                let close = modalButton("关闭", "ghost", { ctx =>
                    this.detailPoint.set(Option<Point>.None)
                    PatchResult.ReRender
                })
                children.add(modalShell("条目详情 · " + payloadTaskOf(p), itemDetailBody(p), [close], true))
            case None => ()
        }
        uiLayout("recall", div(children.toArray(), attrs: Some(a("ui-page"))))
    }

    // ---------- 精确回想 ----------

    func renderRaw(svc: MemoryService): IComponent {
        let fromMs = parseEpochArg(this.qFrom.get())
        let toMs = parseEpochArg(this.qTo.get())
        var tagKey = ""
        var tagVal = ""
        if (this.qTag.get().contains("=")) {
            let idx = this.qTag.get().indexOf("=")
            match (idx) {
                case Some(i) => tagKey = this.qTag.get()[0..i]; tagVal = this.qTag.get()[i + 1..this.qTag.get().size]
                case None => ()
            }
        }
        var limit = Int64(20)
        try { limit = Int64.parse(this.qLimit.get(), radix: 10) } catch (_) { }
        let pts = uiQuery(svc, this.qType.get(), fromMs, toMs, limit, tagKey, tagVal)

        let typeOptions = ArrayList<IComponent>()
        for (t in uiListTypes(svc)) {
            typeOptions.add(SelectOption([text(t.name)], t.name))
        }

        let filter = ArrayList<IComponent>()
        filter.add(div([FormItem([Select(typeOptions.toArray()).placeholder("记忆类型").bind(this.qType)]).label("记忆类型")], attrs: Some(a("ui-fcell"))))
        filter.add(div([FormItem([Input().placeholder("epoch ms，空=不限").bind(this.qFrom)]).label("时间范围 · 从")], attrs: Some(a("ui-fcell"))))
        filter.add(div([FormItem([Input().placeholder("epoch ms，空=不限").bind(this.qTo)]).label("时间范围 · 至")], attrs: Some(a("ui-fcell"))))
        filter.add(div([FormItem([Input().placeholder("key=value，如 proj=cjreg").bind(this.qTag)]).label("tag 过滤")], attrs: Some(a("ui-fcell"))))
        let limitOptions = ArrayList<IComponent>()
        limitOptions.add(SelectOption([text("10")], "10"))
        limitOptions.add(SelectOption([text("20")], "20"))
        limitOptions.add(SelectOption([text("50")], "50"))
        limitOptions.add(SelectOption([text("100")], "100"))
        filter.add(div([FormItem([Select(limitOptions.toArray()).bind(this.qLimit)]).label("limit")], attrs: Some(a("ui-fcell"))))
        filter.add(div([this.queryBtn("查询")], attrs: Some(a("ui-fcell ui-fcell-btn"))))

        let results = ArrayList<IComponent>()
        results.add(cardTitle("查询结果", pts.size.toString() + " 条 · 结构回想（零 LLM）"))
        if (pts.size == 0) {
            results.add(emptyBox("无匹配条目"))
        } else {
            var i = Int64(0)
            for (p in pts) {
                i += 1
                let meta = payloadMeta(p.payload)
                let tags2 = parseTags(p.tags)
                results.add(this.resRow(i, meta, tags2, p))
            }
        }
        div([
            div(filter.toArray(), attrs: Some(a("ui-filter-bar"))),
            div(results.toArray(), attrs: Some(a("ui-card"))),
        ], attrs: Some(a("ui-stack")))
    }

    func queryBtn(label: String): IComponent {
        let btn = div([text(label)], attrs: Some(a("ui-btn primary")))
        btn.onClick({ ctx =>
            PatchResult.ReRender
        })
    }

    func resRow(idx: Int64, meta: PayloadMeta, tags2: ArrayList<(String, String)>, p: Point): IComponent {
        let head = ArrayList<IComponent>()
        head.add(htmlSpan("<span class=\"ui-mono ui-faint\" style=\"font-size:11px\">" + fmtTime(p.ts, svc().store.timeZoneOf()) + "</span>"))
        head.add(statusSpan(meta.status))
        head.add(htmlSpan("<b style=\"font-size:13px\">" + esc(meta.task) + "</b>"))
        // 「详情」入口：长内容与任意自定义字段都能看全（只靠预览必然看不全）
        let detailBtn = modalButton("详情", "sm", { ctx =>
            this.detailPoint.set(Some(p))
            PatchResult.ReRender
        })
        head.add(div([detailBtn], attrs: Some(a("r-actions"))))
        let body = ArrayList<IComponent>()
        body.add(div(head.toArray(), attrs: Some(a("res-head"))))
        body.add(previewBlock(meta, 220))
        let tc = ArrayList<IComponent>()
        for ((k, v) in tags2) { tc.add(badge(k + "=" + v, "ui-mono")) }
        body.add(div(tc.toArray(), attrs: Some(a("tf-tags"))))
        div([
            htmlSpan("<div class=\"r-idx\">" + idx.toString() + "</div>"),
            div(body.toArray(), attrs: Some(a("r-body"))),
        ], attrs: Some(a("ui-res-row")))
    }

    // ---------- 语义回顾 ----------

    func renderSummaryMode(svc: MemoryService): IComponent {
        let meta = uiGetType(svc, this.qType.get())
        let levels: ArrayList<String> = match (meta) {
            case Some(m) => sortLevels(m.levels)
            case None => ArrayList<String>()
        }
        if (this.sGran.get() == "" || !levels.contains(this.sGran.get())) {
            this.sGran.set(if (levels.size > 0) { levels[0] } else { "day" })
        }

        let granRadio = ArrayList<IComponent>()
        for (l in levels) {
            granRadio.add(Radio([text(l)], l))
        }

        let buckets = uiListBucketMetas(svc, this.qType.get(), this.sGran.get())
        let groupOptions = ArrayList<IComponent>()
        groupOptions.add(SelectOption([text("全部")], "all"))
        if (this.sBucket.get() != "") {
            let sums = uiSummariesOfWindow(svc, this.qType.get(), this.bucketFromMs(buckets), this.bucketToMs(buckets))
            let seen = HashSet<String>()
            for (s0 in sums) {
                let g = match (s0.groupKey) { case Some(x) => x case None => "未分组" }
                if (!seen.contains(g)) {
                    seen.add(g)
                    groupOptions.add(SelectOption([text("【" + g + "】")], g))
                }
            }
        }

        let form = ArrayList<IComponent>()
        form.add(div([FormItem([RadioGroup(granRadio.toArray()).bind(this.sGran)]).label("粒度（类型 levels 内）")], attrs: Some(a("ui-gcell"))))
        form.add(div([FormItem([Select(groupOptions.toArray()).bind(this.sGroup)]).label("分组过滤（summary_group_by）")], attrs: Some(a("ui-gcell"))))

        let bucketChildren = ArrayList<IComponent>()
        bucketChildren.add(cardTitle("选择窗口（物化桶 = 已闭合自然窗口）", ""))
        if (buckets.size == 0) {
            bucketChildren.add(emptyBox("该粒度暂无物化桶"))
        } else {
            let grid = ArrayList<IComponent>()
            for (b in buckets) {
                let bk = b.bucketKey
                let cnt = b.refsCount
                grid.add(bucketCard(bk, this.sGran.get(), cnt, bk == this.sBucket.get(), { ctx =>
                    this.sBucket.set(bk)
                    this.sGroup.set("all")
                    PatchResult.ReRender
                }))
            }
            bucketChildren.add(div(grid.toArray(), attrs: Some(a("ui-bucket-grid"))))
        }

        let res = ArrayList<IComponent>()
        let title = if (this.sBucket.get() == "") { "当前窗口摘要" } else { "窗口 " + bucketLocalLabel(this.sBucket.get(), this.sGran.get(), svc.store.timeZoneOf()) + " · " + this.sGran.get() }
        let sums = if (this.sBucket.get() != "") { uiSummariesOfWindow(svc, this.qType.get(), this.bucketFromMs(buckets), this.bucketToMs(buckets)) } else { ArrayList<UiSummaryItem>() }
        let shown = ArrayList<UiSummaryItem>()
        if (this.sGroup.get() == "all") {
            for (s0 in sums) { shown.add(s0) }
        } else {
            for (s0 in sums) {
                let g = match (s0.groupKey) { case Some(x) => x case None => "未分组" }
                if (g == this.sGroup.get()) { shown.add(s0) }
            }
        }
        res.add(cardTitle(title, sums.size.toString() + " 条总结记录 · 语义回顾（读已生成摘要）"))
        if (this.sBucket.get() == "") {
            res.add(emptyBox("← 选择左侧时间窗口，查看该窗口的语义摘要"))
        } else if (sums.size == 0) {
            let empty = ArrayList<IComponent>()
            empty.add(emptyBox("该窗口尚无语义摘要（窗口未闭合或未触发总结）"))
            let btn = div([text("为当前窗口触发总结 · 后台异步")], attrs: Some(a("ui-btn primary")))
            empty.add(div([btn.onClick({ ctx =>
                uiTriggerSummarize(svc, this.qType.get(), this.bucketFromMs(buckets), this.bucketToMs(buckets), "")
                PatchResult.ReRender
            })], attrs: Some(a("ui-empty-action"))))
            for (__it in empty) { res.add(__it) }
        } else if (shown.size == 0) {
            res.add(emptyBox("该分组暂无摘要"))
        } else {
            let sorted = ArrayList<UiSummaryItem>()
            for (s0 in shown) { sorted.add(s0) }
            sort(sorted, by: { x, y => y.ts.compare(x.ts) })
            for (s0 in sorted) { res.add(summaryCard(s0)) }
        }
        div([
            div(form.toArray(), attrs: Some(a("ui-grid3"))),
            div(bucketChildren.toArray(), attrs: Some(a("ui-card"))),
            div(res.toArray(), attrs: Some(a("ui-card"))),
        ], attrs: Some(a("ui-stack")))
    }

    func bucketFromMs(buckets: ArrayList<BucketMeta>): Int64 {
        for (b in buckets) {
            if (b.bucketKey == this.sBucket.get()) {
                let tl = svc().registry.timelineOf(this.qType.get()).getOrThrow()
                let anchor = parseIsoUtcMs(b.bucketKey)
                if (anchor > 0) {
                    let win = tl.windowRangeOf(anchor, this.sGran.get())
                    return win[0]
                }
            }
        }
        0
    }

    func bucketToMs(buckets: ArrayList<BucketMeta>): Int64 {
        for (b in buckets) {
            if (b.bucketKey == this.sBucket.get()) {
                let tl = svc().registry.timelineOf(this.qType.get()).getOrThrow()
                let anchor = parseIsoUtcMs(b.bucketKey)
                if (anchor > 0) {
                    let win = tl.windowRangeOf(anchor, this.sGran.get())
                    return win[1]
                }
            }
        }
        0
    }
}

// epoch 文本解析（空 → 0）
public func parseEpochArg(s: String): Int64 {
    let t = trimSpace(s)
    if (t == "") { return 0 }
    try {
        Int64.parse(t, radix: 10)
    } catch (_) {
        0
    }
}

// 条目标题文案（详情弹窗标题用；task 为空时回退 ts）
func payloadTaskOf(p: Point): String {
    let m = payloadMeta(p.payload)
    if (m.task != "") { m.task.clone() } else { fmtTime(p.ts, svc().store.timeZoneOf()) }
}

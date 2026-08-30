// 忆时塔 Web UI · 页面（1/2）：布局导航 + 总览 + 塔视图 + 回想（双模式）
// @Page 类必须在主包（chronomem.cli，含 main）——RouteRegistry 顶层注册只会在主包执行。

package chronomem.cli

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import chronomem.ui.*
import chronomem.core.*
import chronomem.mcp.MemoryService
import tsdb.{Point, BucketRecord}
import std.collection.{ArrayList, HashMap, HashSet}
import std.time.TimeZone
import std.convert.*

// ==================== 布局 ====================

public let UI_NAV: Array<(String, String, String)> = [
    ("/", "overview", "总览"),
    ("/tower", "tower", "塔视图"),
    ("/recall", "recall", "回想"),
    ("/summary", "summary", "语义总结"),
    ("/types", "types", "记忆类型"),
    ("/append", "append", "追加条目"),
]

public var uiNavActive: String = "overview"

public func setNav(key: String): Unit {
    uiNavActive = key
}

public func uiNoGuard(_: HashMap<String, String>): Option<String> { None }

public func UiLayout(page: IComponent): IComponent {
    let children = ArrayList<IComponent>()
    children.add(uiHeader())
    children.add(uiSide())
    children.add(div([div([page], attrs: Some(a("ui-page")))], attrs: Some(a("ui-main"))))
    div(children.toArray(), attrs: Some(a("ui-shell")))
}

func uiHeader(): IComponent {
    let svc = svc()
    let llmLive = uiLlmLive(svc)
    let llmModel = uiLlmModel(svc)
    let status = ArrayList<IComponent>()
    status.add(htmlSpan("<span class=\"ui-pill\"><span class=\"dot ok\"></span>服务 127.0.0.1:8900 · MCP 在线</span>"))
    if (llmLive) {
        status.add(htmlSpan("<span class=\"ui-pill\"><span class=\"dot ok\"></span>LLM " + llmModel + " 已配置</span>"))
    } else {
        status.add(htmlSpan("<span class=\"ui-pill\"><span class=\"dot warn\"></span>LLM 未配置（总结不可用）</span>"))
    }
    let brand = ArrayList<IComponent>()
    brand.add(htmlSpan("<svg width=\"30\" height=\"30\" viewBox=\"0 0 30 30\" fill=\"none\"><path d=\"M15 2 L19 7 H11 Z\" fill=\"#3ec5e8\"/><rect x=\"7\" y=\"9\" width=\"16\" height=\"5\" rx=\"1.4\" fill=\"#5a8df0\"/><rect x=\"4\" y=\"16\" width=\"22\" height=\"6\" rx=\"1.6\" fill=\"#8a7af0\"/><rect x=\"1\" y=\"24\" width=\"28\" height=\"6\" rx=\"1.8\" fill=\"#e0a15a\"/></svg>"))
    brand.add(htmlSpan("<span class=\"cn\">忆时塔</span> <span class=\"en\">chronomem</span><div class=\"sub\">分层时间记忆 · Web 控制台</div>"))
    div([
        div(brand.toArray(), attrs: Some(a("ui-brand"))),
        div(status.toArray(), attrs: Some(a("ui-head-status"))),
    ], attrs: Some(a("ui-header")))
}

func uiSide(): IComponent {
    let children = ArrayList<IComponent>()
    for ((path, key, label) in UI_NAV) {
        let active = uiNavActive == key
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
    let svc = svc()
    let info = ArrayList<IComponent>()
    info.add(htmlSpan("<div class=\"row\"><span>存储目录</span><b>~/.chronolog</b></div>"))
    info.add(htmlSpan("<div class=\"row\"><span>结构物化</span><b>@every 1m</b></div>"))
    info.add(htmlSpan("<div class=\"row\"><span>自动总结</span><b>*/10 * * * *</b></div>"))
    children.add(div(info.toArray(), attrs: Some(a("ui-side-info"))))
    div(children.toArray(), attrs: Some(a("ui-side")))
}

// ==================== 总览 ====================

@Page["/", "总览", uiNoGuard, UiLayout]
public class OverviewPage <: Component {
    public init() {}

    public func render(): IComponent {
        setNav("overview")
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
        // 类型卡
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
        // 最近条目流
        let flow = ArrayList<IComponent>()
        flow.add(cardTitle("最近条目流", "最新 10 条 · 点击进入塔视图下钻"))
        var shown = Int64(0)
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
                flow.add(timeflowItem(p.ts, meta.task, meta.status, proj, outcomePreview(meta), tags2))
                added += 1
            }
            shown += 1
        }
        children.add(div(flow.toArray(), attrs: Some(a("ui-card"))))
        div(children.toArray(), attrs: Some(a("ui-page")))
    }
}

// ==================== 塔视图 ====================

public let GRAN_ORDER: Array<String> = ["10min", "30min", "1h", "day", "week"]

@Page["/tower", "塔视图", uiNoGuard, UiLayout]
public class TowerPage <: Component {
    var selType: String = ""
    var selGran: String = "day"
    var selBucket: String = ""

    public init() {}

    func ensureSel(svc: MemoryService): Unit {
        if (this.selType == "") {
            let types = uiListTypes(svc)
            if (types.size > 0) { this.selType = types[0].name }
        }
        match (uiGetType(svc, this.selType)) {
            case Some(m) =>
                let levels = sortLevels(m.levels)
                if (levels.size > 0 && !levels.contains(this.selGran)) {
                    this.selGran = levels[0]
                }
            case None => ()
        }
    }

    public func render(): IComponent {
        setNav("tower")
        let svc = svc()
        this.ensureSel(svc)
        if (this.selType == "") {
            return div([
                htmlSpan("<div class=\"ui-title\">塔视图</div>"),
                emptyBox("暂无记忆类型，无法建塔"),
                div([text("")], attrs: Some(a("ui-page"))),
            ], attrs: Some(a("ui-page")))
        }
        let meta = uiGetType(svc, this.selType).getOrThrow()
        let levels = sortLevels(meta.levels)

        // 类型切换
        let switchRow = ArrayList<IComponent>()
        for (t in uiListTypes(svc)) {
            let active = t.name == this.selType
            switchRow.add(this.typeButton(t.name, active))
        }
        // 塔层（全链展示：未配置层禁用）
        let layers = ArrayList<IComponent>()
        let revOrder = ["week", "day", "1h", "30min", "10min"]
        for (level in revOrder) {
            let enabled = levels.contains(level)
            let bucketCount = if (enabled) { uiListBuckets(svc, this.selType, level).size } else { Int64(0) }
            let active = enabled && level == this.selGran
            let h: Option<ActionHandler> = if (enabled) {
                Some({ ctx =>
                    this.selGran = level
                    this.selBucket = ""
                    PatchResult.ReRender
                })
            } else { None }
            layers.add(towerLayer(level, levelLabel(level), levelSub(level),
                if (enabled) { bucketCount.toString() } else { "未配置" }, enabled, active, h))
        }
        // 桶
        let buckets = if (levels.contains(this.selGran)) { uiListBuckets(svc, this.selType, this.selGran) } else { ArrayList<BucketRecord>() }
        let bucketChildren = ArrayList<IComponent>()
        bucketChildren.add(cardTitle(this.selGran + " · 时间桶", "点击下钻原始条目"))
        if (buckets.size == 0) {
            bucketChildren.add(emptyBox("该粒度暂无物化桶（结构物化每分钟跑一次，空窗口不建桶）"))
        } else {
            let grid = ArrayList<IComponent>()
            for (b in buckets) {
                let cnt = uiDrillDown(svc, this.selType, this.selGran, b.bucketKey).size
                grid.add(bucketCard(b.bucketKey, this.selGran, cnt, b.bucketKey == this.selBucket, { ctx =>
                    this.selBucket = b.bucketKey
                    PatchResult.ReRender
                }))
            }
            bucketChildren.add(div(grid.toArray(), attrs: Some(a("ui-bucket-grid"))))
        }

        let mainCol = ArrayList<IComponent>()
        for (__it in pageTitle("塔视图", "沿粒度层下钻时间桶 → 精确回想原始条目")) { mainCol.add(__it) }
        mainCol.add(div([
            div(switchRow.toArray(), attrs: Some(a("ui-type-switch"))),
        ], attrs: Some(a("ui-card"))))
        mainCol.add(div([
            htmlSpan("<div class=\"ui-tower-cap\">时间之塔 · TIME MEMORY TOWER</div>"),
            htmlSpan("<div class=\"ui-tower-top\"></div>"),
            div(layers.toArray(), attrs: Some(a("ui-tower-center"))),
            htmlSpan("<div class=\"ui-tower-base\"></div>"),
            htmlSpan("<div class=\"ui-tower-legend\"><span>越久越粗</span><span>·</span><span>越久越高</span><span>·</span><span>层间可下钻</span></div>"),
        ], attrs: Some(a("ui-tower"))))
        mainCol.add(div(bucketChildren.toArray(), attrs: Some(a("ui-card"))))

        // 下钻面板
        let drill = this.drillPanel(svc, meta, buckets)
        div([
            div([
                div(mainCol.toArray(), attrs: Some(a("ui-tower-left"))),
                drill,
            ], attrs: Some(a("ui-tower-grid"))),
        ], attrs: Some(a("ui-page")))
    }

    func typeButton(name: String, active: Bool): IComponent {
        let btn = div([
            text(name),
        ], attrs: Some(a(if (active) { "ui-btn primary" } else { "ui-btn" })))
        btn.onClick({ ctx =>
            this.selType = name
            this.selGran = "day"
            this.selBucket = ""
            PatchResult.ReRender
        })
    }

    func drillPanel(svc: MemoryService, meta: TypeMeta, buckets: ArrayList<BucketRecord>): IComponent {
        let children = ArrayList<IComponent>()
        if (this.selBucket == "") {
            children.add(htmlSpan("<div class=\"ui-crumb\">← 点击左侧时间桶，下钻原始条目</div>"))
            children.add(emptyBox("选择桶后，此处展示该窗口内的原始条目（按引用链精确下钻，零 LLM）"))
        } else {
            let points = uiDrillDown(svc, this.selType, this.selGran, this.selBucket)
            let label = bucketLocalLabel(this.selBucket, this.selGran, svc.store.timeZoneOf())
            children.add(htmlSpan("<div class=\"ui-crumb\"><b>" + this.selType + "</b> › <b>" + this.selGran + "</b> › 桶 " + label +
                " · <span class=\"ui-mono\">" + this.selBucket + "</span> · <b style=\"color:var(--accent)\">" + points.size.toString() + " 条</b></div>"))
            for (p in points) {
                children.add(pointCard(p))
            }
            if (points.size == 0) {
                children.add(emptyBox("该桶暂无原始条目"))
            }
        }
        div(children.toArray(), attrs: Some(a("ui-drill")))
    }
}

// ==================== 回想（双模式） ====================

@Page["/recall", "回想", uiNoGuard, UiLayout]
public class RecallPage <: Component {
    var mode: String = "raw"
    var qType: String = ""
    var qFrom: String = ""
    var qTo: String = ""
    var qTag: String = ""
    var qLimit: String = "20"
    var sGran: String = "day"
    var sBucket: String = ""
    var sGroup: String = "all"

    public init() {}

    func ensureType(svc: MemoryService): Unit {
        if (this.qType == "") {
            let types = uiListTypes(svc)
            if (types.size > 0) { this.qType = types[0].name }
        }
    }

    public func render(): IComponent {
        setNav("recall")
        let svc = svc()
        this.ensureType(svc)
        let children = ArrayList<IComponent>()
        for (__it in pageTitle("回想", "两档回想：精确回想直查原始条目（零 LLM）；语义回顾按粒度窗口读语义摘要（决策/结论/待办），依赖该窗口已总结过。")) { children.add(__it) }
        // 模式切换
        let modeRow = ArrayList<IComponent>()
        modeRow.add(this.modeChip("raw", "精确回想 · 原始条目"))
        modeRow.add(this.modeChip("summary", "语义回顾 · 窗口摘要"))
        children.add(div([
            div(modeRow.toArray(), attrs: Some(a("ui-chips"))),
        ], attrs: Some(a("ui-card"))))
        if (this.mode == "raw") {
            for (__it in this.renderRaw(svc)) { children.add(__it) }
        } else {
            for (__it in this.renderSummaryMode(svc)) { children.add(__it) }
        }
        div(children.toArray(), attrs: Some(a("ui-page")))
    }

    func modeChip(key: String, label: String): IComponent {
        let c = div([text(label)], attrs: Some(a(if (this.mode == key) { "ui-chip-sel on" } else { "ui-chip-sel" })))
        c.onClick({ ctx =>
            this.mode = key
            this.sGroup = "all"
            PatchResult.ReRender
        })
    }

    func renderRaw(svc: MemoryService): Array<IComponent> {
        let out = ArrayList<IComponent>()
        let fromMs = parseEpochArg(this.qFrom)
        let toMs = parseEpochArg(this.qTo)
        // tag key=value
        var tagKey = ""
        var tagVal = ""
        if (this.qTag.contains("=")) {
            let idx = this.qTag.indexOf("=")
            match (idx) {
                case Some(i) => tagKey = this.qTag[0..i]; tagVal = this.qTag[i + 1..this.qTag.size]
                case None => ()
            }
        }
        var limit = Int64(20)
        try { limit = Int64.parse(this.qLimit, radix: 10) } catch (_) { }
        let pts = uiQuery(svc, this.qType, fromMs, toMs, limit, tagKey, tagVal)
        let filter = ArrayList<IComponent>()
        filter.add(this.field("记忆类型", this.typeSelect()))
        filter.add(this.inpField("时间范围 · 从（epoch ms，空=不限）", this.qFrom, { ctx => this.qFrom = paramStr(ctx.params, "value"); PatchResult.ReRender }))
        filter.add(this.inpField("时间范围 · 至", this.qTo, { ctx => this.qTo = paramStr(ctx.params, "value"); PatchResult.ReRender }))
        filter.add(this.inpField("tag 过滤（key=value）", this.qTag, { ctx => this.qTag = paramStr(ctx.params, "value"); PatchResult.ReRender }))
        filter.add(this.inpField("limit", this.qLimit, { ctx => this.qLimit = paramStr(ctx.params, "value"); PatchResult.ReRender }))
        filter.add(this.actionBtn("查询", { ctx => PatchResult.ReRender }))
        out.add(div(filter.toArray(), attrs: Some(a("ui-filter-bar"))))
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
        out.add(div(results.toArray(), attrs: Some(a("ui-card"))))
        out.toArray()
    }

    func resRow(idx: Int64, meta: PayloadMeta, tags2: ArrayList<(String, String)>, p: Point): IComponent {
        let head = ArrayList<IComponent>()
        head.add(htmlSpan("<span class=\"ui-mono ui-faint\" style=\"font-size:11px\">" + fmtTime(p.ts, svc().store.timeZoneOf()) + "</span>"))
        head.add(statusSpan(meta.status))
        head.add(htmlSpan("<b style=\"font-size:13px\">" + meta.task + "</b>"))
        let body = ArrayList<IComponent>()
        body.add(div(head.toArray(), attrs: Some(a("res-head"))))
        body.add(div([text(outcomePreview(meta))], attrs: Some(a("ui-muted res-out"))))
        let tc = ArrayList<IComponent>()
        for ((k, v) in tags2) { tc.add(badge(k + "=" + v, "ui-mono")) }
        body.add(div(tc.toArray(), attrs: Some(a("tf-tags"))))
        div([
            htmlSpan("<div class=\"r-idx\">" + idx.toString() + "</div>"),
            div(body.toArray(), attrs: Some(a("r-body"))),
        ], attrs: Some(a("ui-res-row")))
    }

    // ---- 语义回顾 ----
    func renderSummaryMode(svc: MemoryService): Array<IComponent> {
        let out = ArrayList<IComponent>()
        let meta = uiGetType(svc, this.qType)
        let levels: ArrayList<String> = match (meta) {
            case Some(m) => sortLevels(m.levels)
            case None => ArrayList<String>()
        }
        if (this.sGran == "" || !levels.contains(this.sGran)) {
            this.sGran = if (levels.size > 0) { levels[0] } else { "day" }
        }
        let form = ArrayList<IComponent>()
        form.add(this.field("记忆类型", this.typeSelect()))
        // 粒度 chips
        let granRow = ArrayList<IComponent>()
        for (l in levels) {
            let c = div([text(l)], attrs: Some(a(if (this.sGran == l) { "ui-chip-sel on" } else { "ui-chip-sel" })))
            let g = l
            let handled = c.onClick({ ctx =>
                this.sGran = g
                this.sBucket = ""
                this.sGroup = "all"
                PatchResult.ReRender
            })
            granRow.add(handled)
        }
        form.add(this.field("粒度（类型 levels 内）", div(granRow.toArray(), attrs: Some(a("ui-chips")))))
        // 分组过滤
        let buckets = uiListBuckets(svc, this.qType, this.sGran)
        let groupRow = ArrayList<IComponent>()
        if (this.sBucket != "") {
            let sums = uiSummariesOfWindow(svc, this.qType, this.bucketFromMs(buckets), this.bucketToMs(buckets))
            let seen = HashSet<String>()
            let groups = ArrayList<String>()
            for (s0 in sums) {
                let g = match (s0.groupKey) { case Some(x) => x case None => "未分组" }
                if (!seen.contains(g)) { seen.add(g); groups.add(g) }
            }
            groupRow.add(this.groupChip("all", "全部"))
            for (g in groups) { groupRow.add(this.groupChip(g, g)) }
        } else {
            groupRow.add(this.groupChip("all", "全部"))
        }
        form.add(this.field("分组过滤（summary_group_by）", div(groupRow.toArray(), attrs: Some(a("ui-chips")))))

        let bucketChildren = ArrayList<IComponent>()
        bucketChildren.add(cardTitle("选择窗口（物化桶 = 已闭合自然窗口）", ""))
        if (buckets.size == 0) {
            bucketChildren.add(emptyBox("该粒度暂无物化桶"))
        } else {
            let grid = ArrayList<IComponent>()
            for (b in buckets) {
                let bk = b.bucketKey
                let cnt = uiDrillDown(svc, this.qType, this.sGran, bk).size
                grid.add(bucketCard(bk, this.sGran, cnt, bk == this.sBucket, { ctx =>
                    this.sBucket = bk
                    this.sGroup = "all"
                    PatchResult.ReRender
                }))
            }
            bucketChildren.add(div(grid.toArray(), attrs: Some(a("ui-bucket-grid"))))
        }
        out.add(div([
            div(form.toArray(), attrs: Some(a("ui-grid3"))),
        ], attrs: Some(a("ui-card"))))
        out.add(div(bucketChildren.toArray(), attrs: Some(a("ui-card"))))

        // 结果
        let res = ArrayList<IComponent>()
        let title = if (this.sBucket == "") { "当前窗口摘要" } else { "窗口 " + bucketLocalLabel(this.sBucket, this.sGran, svc.store.timeZoneOf()) + " · " + this.sGran }
        let sums = if (this.sBucket != "") { uiSummariesOfWindow(svc, this.qType, this.bucketFromMs(buckets), this.bucketToMs(buckets)) } else { ArrayList<UiSummaryItem>() }
        var shown = ArrayList<UiSummaryItem>()
        if (this.sGroup == "all") {
            shown = sums
        } else {
            for (s0 in sums) {
                let g = match (s0.groupKey) { case Some(x) => x case None => "未分组" }
                if (g == this.sGroup) { shown.add(s0) }
            }
        }
        res.add(cardTitle(title, sums.size.toString() + " 条总结记录 · 语义回顾（读已生成摘要）"))
        if (this.sBucket == "") {
            res.add(emptyBox("← 选择左侧时间窗口，查看该窗口的语义摘要"))
        } else if (sums.size == 0) {
            let empty = ArrayList<IComponent>()
            empty.add(emptyBox("该窗口尚无语义摘要（窗口未闭合或未触发总结）"))
            empty.add(div([
                this.actionBtn("为当前窗口触发总结 · 后台异步", { ctx =>
                    uiTriggerSummarize(svc, this.qType, this.bucketFromMs(buckets), this.bucketToMs(buckets), "")
                    PatchResult.ReRender
                }),
            ], attrs: Some(a("ui-empty-action"))))
            for (__it in empty) { res.add(__it) }
        } else if (shown.size == 0) {
            res.add(emptyBox("该分组暂无摘要"))
        } else {
            for (s0 in shown) { res.add(summaryCard(s0)) }
        }
        out.add(div(res.toArray(), attrs: Some(a("ui-card"))))
        out.toArray()
    }

    func bucketFromMs(buckets: ArrayList<BucketRecord>): Int64 {
        for (b in buckets) {
            if (b.bucketKey == this.sBucket) {
                let tl = svc().registry.timelineOf(this.qType).getOrThrow()
                let anchor = parseIsoUtcMs(b.bucketKey)
                if (anchor > 0) {
                    let win = tl.windowRangeOf(anchor, this.sGran)
                    return win[0]
                }
            }
        }
        0
    }

    func bucketToMs(buckets: ArrayList<BucketRecord>): Int64 {
        for (b in buckets) {
            if (b.bucketKey == this.sBucket) {
                let tl = svc().registry.timelineOf(this.qType).getOrThrow()
                let anchor = parseIsoUtcMs(b.bucketKey)
                if (anchor > 0) {
                    let win = tl.windowRangeOf(anchor, this.sGran)
                    return win[1]
                }
            }
        }
        0
    }

    func groupChip(key: String, label: String): IComponent {
        let c = div([text(if (key == "all") { "全部" } else { "【" + label + "】" })], attrs: Some(a(if (this.sGroup == key) { "ui-chip-sel on" } else { "ui-chip-sel" })))
        c.onClick({ ctx =>
            this.sGroup = key
            PatchResult.ReRender
        })
    }

    func typeSelect(): IComponent {
        let types = uiListTypes(svc())
        let chips = ArrayList<IComponent>()
        for (t in types) {
            let c = div([text(t.name)], attrs: Some(a(if (this.qType == t.name) { "ui-chip-sel on" } else { "ui-chip-sel" })))
            let name = t.name
            let handled = c.onClick({ ctx =>
                this.qType = name
                this.sBucket = ""
                this.sGroup = "all"
                PatchResult.ReRender
            })
            chips.add(handled)
        }
        div(chips.toArray(), attrs: Some(a("ui-chips")))
    }

    func field(label: String, inner: IComponent): IComponent {
        div([
            htmlSpan("<label>" + label + "</label>"),
            inner,
        ], attrs: Some(a("ui-field")))
    }

    func inpField(label: String, value: String, onInput: ActionHandler): IComponent {
        let input0 = input(attrs: Some(a("ui-inp")))
        // 输入事件：blur/enter 时回传 value；附上当前 value
        let handled = input0.on("blur", onInput).attr("value", value)
        div([
            htmlSpan("<label>" + label + "</label>"),
            handled,
        ], attrs: Some(a("ui-field")))
    }

    func actionBtn(label: String, h: ActionHandler): IComponent {
        let btn = div([text(label)], attrs: Some(a("ui-btn primary")))
        let handled = btn.onClick(h)
        var outer = div([handled], attrs: Some(a("ui-inline-btn")))
        if (label.startsWith("查询")) {
            outer = div([handled], attrs: Some(a("ui-filter-btn")))
        }
        outer
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

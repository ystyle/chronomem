// 忆时塔 Web UI · 页面（2/2）：语义总结 + 记忆类型管理 + 追加条目

package chronomem.cli

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import chronomem.ui.*
import chronomem.core.*
import chronomem.mcp.MemoryService
import jsonvalue.*
import std.collection.{ArrayList, HashMap, HashSet}
import std.time.TimeZone
import std.convert.*

// ==================== 语义总结 ====================

@Page["/summary", "语义总结", uiNoGuard, UiLayout]
public class SummaryPage <: Component {
    var typeName: String = ""
    var mode: String = "granularity"
    var gran: String = "day"
    var fromMs: String = ""
    var toMs: String = ""
    var instructions: String = ""
    var notice: String = ""

    public init() {}

    func ensureType(svc: MemoryService): Unit {
        if (this.typeName == "") {
            let types = uiListTypes(svc)
            if (types.size > 0) { this.typeName = types[0].name }
        }
    }

    public func render(): IComponent {
        setNav("summary")
        let svc = svc()
        this.ensureType(svc)
        let children = ArrayList<IComponent>()
        for (__it in pageTitle("语义总结", "LLM 把窗口条目提炼为结构化摘要（决策/结论/待办/状态变更/关键词），落库为总结记录；后台异步执行，幂等（窗口×分组已有摘要则跳过）。")) { children.add(__it) }

        // 触发总结表单
        let form = ArrayList<IComponent>()
        form.add(cardTitle("触发总结", "后台异步 · 幂等"))
        // 类型
        let typeRow = ArrayList<IComponent>()
        for (t in uiListTypes(svc)) {
            let c = div([text(t.name)], attrs: Some(a(if (this.typeName == t.name) { "ui-chip-sel on" } else { "ui-chip-sel" })))
            let name = t.name
            typeRow.add(c.onClick({ ctx =>
                this.typeName = name
                PatchResult.ReRender
            }))
        }
        form.add(this.field("记忆类型", div(typeRow.toArray(), attrs: Some(a("ui-chips")))))
        // 方式
        let modeRow = ArrayList<IComponent>()
        modeRow.add(this.modeChip("granularity", "按粒度窗口"))
        modeRow.add(this.modeChip("custom", "显式窗口（任务阶段）"))
        form.add(this.field("总结方式", div(modeRow.toArray(), attrs: Some(a("ui-chips")))))
        // 粒度 or 窗口
        let meta = uiGetType(svc, this.typeName)
        let levels: ArrayList<String> = match (meta) {
            case Some(m) => sortLevels(m.levels)
            case None => ArrayList<String>()
        }
        if (this.gran == "" || !levels.contains(this.gran)) {
            this.gran = if (levels.size > 0) { levels[0] } else { "day" }
        }
        if (this.mode == "granularity") {
            let granRow = ArrayList<IComponent>()
            for (l in levels) {
                let c = div([text(l)], attrs: Some(a(if (this.gran == l) { "ui-chip-sel on" } else { "ui-chip-sel" })))
                let g = l
                granRow.add(c.onClick({ ctx =>
                    this.gran = g
                    PatchResult.ReRender
                }))
            }
            form.add(this.field("粒度（类型 levels 内）", div(granRow.toArray(), attrs: Some(a("ui-chips")))))
        } else {
            form.add(this.inpField("窗口起始（epoch ms）", this.fromMs, { ctx => this.fromMs = paramStr(ctx.params, "value"); PatchResult.ReRender }))
            form.add(this.inpField("窗口结束（epoch ms）", this.toMs, { ctx => this.toMs = paramStr(ctx.params, "value"); PatchResult.ReRender }))
        }
        form.add(this.inpField("补充指令 instructions（可选）", this.instructions, { ctx => this.instructions = paramStr(ctx.params, "value"); PatchResult.ReRender }))
        // 提交
        let submit = div([text("提交总结任务")], attrs: Some(a("ui-btn primary")))
        let submitted = submit.onClick({ ctx =>
            let (fromMs, toMs) = this.resolveWindow(svc)
            let r = uiTriggerSummarize(svc, this.typeName, fromMs, toMs, this.instructions)
            this.notice = r.message
            PatchResult.ReRender
        })
        form.add(div([submitted], attrs: Some(a("ui-summary-submit"))))
        if (this.notice != "") {
            form.add(htmlSpan("<div style=\"margin-top:8px;font-size:12px;color:var(--accent)\">" + this.notice + "</div>"))
        }
        children.add(div(form.toArray(), attrs: Some(a("ui-card"))))

        // 总结记录
        let list = ArrayList<IComponent>()
        list.add(cardTitle("总结记录", "SummaryRecord · 最新在前 · 窗口×分组各一条"))
        let sums = uiSummaries(svc, this.typeName, 100)
        if (sums.size == 0) {
            list.add(emptyBox("暂无总结记录。未配置 LLM 时总结不可用；配置后触发窗口总结即可生成。"))
        } else {
            for (s0 in sums) { list.add(summaryCard(s0)) }
        }
        children.add(div(list.toArray(), attrs: Some(a("ui-card"))))
        div(children.toArray(), attrs: Some(a("ui-page")))
    }

    func modeChip(key: String, label: String): IComponent {
        let c = div([text(label)], attrs: Some(a(if (this.mode == key) { "ui-chip-sel on" } else { "ui-chip-sel" })))
        c.onClick({ ctx =>
            this.mode = key
            PatchResult.ReRender
        })
    }

    func resolveWindow(svc: MemoryService): (Int64, Int64) {
        if (this.mode == "custom") {
            return (parseEpochArg(this.fromMs), parseEpochArg(this.toMs))
        }
        // 按粒度：取最近一个已闭合物化桶窗口
        let buckets = uiListBuckets(svc, this.typeName, this.gran)
        if (buckets.size > 0) {
            let last = buckets[buckets.size - 1]
            let anchor = parseIsoUtcMs(last.bucketKey)
            if (anchor > 0) {
                let tl = svc.registry.timelineOf(this.typeName).getOrThrow()
                let win = tl.windowRangeOf(anchor, this.gran)
                return (win[0], win[1])
            }
        }
        (0, 0)
    }

    func field(label: String, inner: IComponent): IComponent {
        div([
            htmlSpan("<label>" + label + "</label>"),
            inner,
        ], attrs: Some(a("ui-field")))
    }

    func inpField(label: String, value: String, onInput: ActionHandler): IComponent {
        let handled = input(attrs: Some(a("ui-inp"))).on("blur", onInput).attr("value", value)
        div([
            htmlSpan("<label>" + label + "</label>"),
            handled,
        ], attrs: Some(a("ui-field")))
    }
}

// ==================== 记忆类型 ====================

@Page["/types", "记忆类型", uiNoGuard, UiLayout]
public class TypesPage <: Component {
    var createOpen: Bool = false
    var detailOpen: Bool = false
    var dangerOpen: Bool = false
    var forceDelete: Bool = false
    var notice: String = ""
    // 创建表单
    var cName: String = ""
    var cDesc: String = ""
    var cLevels: ArrayList<String> = ArrayList<String>()
    var cGroupBy: String = ""
    var cRetention: String = ""
    var cAuto: Bool = true

    public init() {}

    public func render(): IComponent {
        setNav("types")
        let svc = svc()
        let children = ArrayList<IComponent>()
        for (__it in pageTitle("记忆类型", "类型 = 一条独立 series（原始条目 + 同名 .summary 总结），粒度链是类型级配置：高频类型保分钟档，低频类型收敛到 day/week。")) { children.add(__it) }
        let list = ArrayList<IComponent>()
        let head = ArrayList<IComponent>()
        head.add(div([text("类型列表")], attrs: Some(a("ui-card-title"))))
        let createBtn = div([text("+ 创建类型")], attrs: Some(a("ui-btn primary sm")))
        let createHandled = createBtn.onClick({ ctx =>
            this.createOpen = true
            PatchResult.ReRender
        })
        head.add(div([createHandled], attrs: Some(a("ui-head-right"))))
        list.add(div(head.toArray(), attrs: Some(a("ui-card-title ui-card-title-flex"))))
        list.add(this.typeTable(svc))
        if (this.notice != "") {
            list.add(htmlSpan("<div style=\"margin-top:8px;font-size:12px\">" + this.notice + "</div>"))
        }
        list.add(htmlSpan("<div class=\"ui-danger-zone\"><div style=\"font-size:12.5px;color:var(--danger);font-weight:600;margin-bottom:6px\">危险操作</div><div class=\"ui-muted\" style=\"font-size:12px\">清空（TRUNCATE）删除类型全部条目但保留类型；删除（DROP）需先清空，且不可恢复。</div></div>"))
        children.add(div(list.toArray(), attrs: Some(a("ui-card"))))
        if (this.createOpen) {
            children.add(this.createDialog(svc))
        }
        if (this.detailOpen) {
            children.add(this.detailDialog(svc))
        }
        if (this.dangerOpen) {
            children.add(this.dangerDialog(svc))
        }
        div(children.toArray(), attrs: Some(a("ui-page")))
    }

    func typeTable(svc: MemoryService): IComponent {
        let rows = ArrayList<IComponent>()
        rows.add(this.typeRowHead())
        for (m in uiListTypes(svc)) {
            rows.add(this.typeRow(svc, m))
        }
        div(rows.toArray(), attrs: Some(a("ui-trows")))
    }

    func typeRowHead(): IComponent {
        let cells = ArrayList<IComponent>()
        for (c0 in ["类型", "描述", "粒度链", "分组维度", "条目", "自动总结", "操作"]) {
            cells.add(div([text(c0)], attrs: Some(a("ui-tcell ui-tcell-head"))))
        }
        div(cells.toArray(), attrs: Some(a("ui-trow ui-trow-head")))
    }

    func typeRow(svc: MemoryService, m: TypeMeta): IComponent {
        let name = m.name
        let levels = sortLevels(m.levels)
        let groupText = match (m.summaryGroupBy) {
            case Some(g) => String.join(g.toArray(), delimiter: ",")
            case None => "无"
        }
        let cells = ArrayList<IComponent>()
        cells.add(div([text(m.name)], attrs: Some(a("ui-mono ui-tname"))))
        cells.add(div([text(m.description)], attrs: Some(a("ui-tdesc"))))
        let lv = ArrayList<IComponent>()
        for (l in levels) { lv.add(chip("", l)) }
        cells.add(div(lv.toArray(), attrs: Some(a("ui-chips"))))
        cells.add(badge(groupText, "ui-mono"))
        cells.add(div([text(uiCount(svc, m.name).toString())], attrs: Some(a("ui-mono"))))
        cells.add(if (m.autoSummarize) { badge("✓ auto", "g") } else { badge("—", "") })
        cells.add(this.typeRowActions(svc, name))
        div(cells.toArray(), attrs: Some(a("ui-trow")))
    }

    func typeRowActions(svc: MemoryService, name: String): IComponent {
        let actions = ArrayList<IComponent>()
        let detail = div([text("详情")], attrs: Some(a("ui-btn sm")))
        actions.add(detail.onClick({ ctx =>
            this.detailName = name
            this.detailOpen = true
            PatchResult.ReRender
        }))
        let trash = div([text("清空")], attrs: Some(a("ui-btn sm danger")))
        actions.add(trash.onClick({ ctx =>
            let r = uiTruncate(svc, name)
            this.notice = r.message
            PatchResult.ReRender
        }))
        let del = div([text("删除")], attrs: Some(a("ui-btn sm danger")))
        actions.add(del.onClick({ ctx =>
            this.dangerName = name
            this.dangerOpen = true
            PatchResult.ReRender
        }))
        div(actions.toArray(), attrs: Some(a("ui-tactions")))
    }

    func levelsHtml(levels: ArrayList<String>): String {
        let sb = StringBuilder()
        for (l in levels) {
            sb.append("<span class=\"ui-chip " + levelChipClass(l) + "\">" + l + "</span> ")
        }
        sb.toString()
    }

    func createDialog(svc: MemoryService): IComponent {
        let dlg = ArrayList<IComponent>()
        dlg.add(this.inpField("类型名（白名单 [A-Za-z0-9_/-]）", this.cName, { ctx => this.cName = paramStr(ctx.params, "value"); PatchResult.ReRender }))
        dlg.add(this.inpField("描述", this.cDesc, { ctx => this.cDesc = paramStr(ctx.params, "value"); PatchResult.ReRender }))
        // levels
        let levelRow = ArrayList<IComponent>()
        for (l in ["10min", "30min", "1h", "3h", "day", "week", "month"]) {
            let on = this.cLevels.contains(l)
            let c = div([text(l)], attrs: Some(a(if (on) { "ui-chip-sel on" } else { "ui-chip-sel" })))
            let g = l
            let handled = c.onClick({ ctx =>
                if (this.cLevels.contains(g)) {
                    let next = ArrayList<String>()
                    for (x in this.cLevels) { if (x != g) { next.add(x) } }
                    this.cLevels = next
                } else {
                    this.cLevels.add(g)
                }
                PatchResult.ReRender
            })
            levelRow.add(handled)
        }
        dlg.add(this.field("粒度链 levels（升序）", div(levelRow.toArray(), attrs: Some(a("ui-chips")))))
        dlg.add(this.inpField("总结分组维度 summary_group_by（tag 键，可留空）", this.cGroupBy, { ctx => this.cGroupBy = paramStr(ctx.params, "value"); PatchResult.ReRender }))
        dlg.add(this.inpField("保留期 retention（如 30d，可留空）", this.cRetention, { ctx => this.cRetention = paramStr(ctx.params, "value"); PatchResult.ReRender }))
        // auto switch
        let swCls = "ui-switch" + (if (this.cAuto) { " on" } else { "" })
        let sw = htmlSpan("<span class=\"" + swCls + "\" style=\"display:inline-block;vertical-align:middle\"><span class=\"knob\"></span></span>")
        dlg.add(this.field("后台自动语义总结 auto_summarize", div([sw], attrs: Some(a("ui-switch-row")))))
        let foot = ArrayList<IComponent>()
        let cancel = div([text("取消")], attrs: Some(a("ui-btn ghost")))
        foot.add(cancel.onClick({ ctx =>
            this.createOpen = false
            PatchResult.ReRender
        }))
        let confirm = div([text("创建")], attrs: Some(a("ui-btn primary")))
        let confirmed = confirm.onClick({ ctx =>
            let groupBy = if (this.cGroupBy == "") { Option<ArrayList<String>>.None } else {
                let g = this.cGroupBy.split(",")
                let arr = ArrayList<String>()
                for (x in g) {
                    let t = trimSpace(x)
                    if (t != "") { arr.add(t) }
                }
                if (arr.size == 0) { Option<ArrayList<String>>.None } else { Some(arr) }
            }
            let retention = if (this.cRetention == "") { Option<String>.None } else { Some(this.cRetention) }
            let levels = if (this.cLevels.size == 0) { defaultLevelsOf() } else { sortLevels(this.cLevels) }
            let meta = TypeMeta(trimSpace(this.cName), this.cDesc, Option<String>.None, levels, retention,
                this.cAuto, Option<ArrayList<String>>.None, nowMs(), summaryGroupBy: groupBy)
            let r = uiCreateType(svc, meta)
            this.notice = r.message
            this.createOpen = false
            PatchResult.ReRender
        })
        foot.add(confirmed)
        this.dialog("创建记忆类型", dlg.toArray(), foot.toArray())
    }

    func defaultLevelsOf(): ArrayList<String> {
        let l = ArrayList<String>()
        l.add("10min"); l.add("30min"); l.add("1h"); l.add("day"); l.add("week")
        l
    }

    func detailDialog(svc: MemoryService): IComponent {
        let body = ArrayList<IComponent>()
        match (uiGetType(svc, this.detailName)) {
            case Some(meta) =>
                let info = uiTypeInfo(svc, meta.name).getOrThrow()
                let tr = StringBuilder()
                tr.append("<dt>类型名</dt><dd>" + meta.name + "</dd>")
                tr.append("<dt>描述</dt><dd style=\"font-family:var(--sans);color:var(--muted)\">" + meta.description + "</dd>")
                tr.append("<dt>粒度链</dt><dd>" + String.join(sortLevels(meta.levels).toArray(), delimiter: " → ") + "</dd>")
                tr.append("<dt>总结分组</dt><dd>" + groupTextOf(meta) + "</dd>")
                tr.append("<dt>条目数</dt><dd>" + info.entries.toString() + "</dd>")
                tr.append("<dt>总结数</dt><dd>" + info.summaries.toString() + "</dd>")
                for ((level, cnt) in info.bucketCounts) {
                    tr.append("<dt>" + level + " 桶</dt><dd>" + cnt.toString() + "</dd>")
                }
                tr.append("<dt>auto_summarize</dt><dd>" + meta.autoSummarize.toString() + "</dd>")
                tr.append("<dt>retention</dt><dd>" + (match (meta.retention) { case Some(r) => r case None => "无（全量保留）" }) + "</dd>")
                tr.append("<dt>createdAt</dt><dd>" + fmtDateTime(meta.createdAt, svc.store.timeZoneOf()) + "</dd>")
                body.add(htmlSpan("<dl class=\"ui-meta-kv\" style=\"margin-bottom:12px\">" + tr.toString() + "</dl>"))
                body.add(cardTitle("TypeMeta（json.stream）", ""))
                body.add(jsonPreview(toJsonString(meta)))
            case None => body.add(emptyBox("类型不存在"))
        }
        let foot = ArrayList<IComponent>()
        let close = div([text("关闭")], attrs: Some(a("ui-btn ghost")))
        foot.add(close.onClick({ ctx =>
            this.detailOpen = false
            PatchResult.ReRender
        }))
        this.dialog("类型详情 · " + this.detailName, body.toArray(), foot.toArray())
    }

    var detailName: String = ""

    func groupTextOf(meta: TypeMeta): String {
        match (meta.summaryGroupBy) {
            case Some(g) => "[" + String.join(g.toArray(), delimiter: ", ") + "]"
            case None => "未分组"
        }
    }

    func dangerDialog(svc: MemoryService): IComponent {
        let body = ArrayList<IComponent>()
        body.add(htmlSpan("<div style=\"font-size:12.5px;color:var(--muted);margin-bottom:10px\">DROP 语义：原始 + 总结序列必须为空，请先执行清空。此操作<b style=\"color:var(--danger)\">不可恢复</b>：</div>"))
        let foot = ArrayList<IComponent>()
        let cancel = div([text("取消")], attrs: Some(a("ui-btn ghost")))
        foot.add(cancel.onClick({ ctx =>
            this.dangerOpen = false
            PatchResult.ReRender
        }))
        let truncate = div([text("先清空（TRUNCATE）")], attrs: Some(a("ui-btn danger sm")))
        let truncHandled = truncate.onClick({ ctx =>
            let r = uiTruncate(svc, this.dangerName)
            this.notice = r.message
            PatchResult.ReRender
        })
        foot.add(truncHandled)
        let del = div([text("删除（DROP）")], attrs: Some(a("ui-btn danger")))
        let delHandled = del.onClick({ ctx =>
            let r = uiDeleteType(svc, this.dangerName)
            if (r.ok) {
                this.dangerOpen = false
            }
            this.notice = r.message
            PatchResult.ReRender
        })
        foot.add(delHandled)
        this.dialog("删除类型 · " + this.dangerName, body.toArray(), foot.toArray())
    }

    var dangerName: String = ""

    func dialog(title: String, body: Array<IComponent>, foot: Array<IComponent>): IComponent {
        div([
            div([
                htmlSpan("<div class=\"ui-dlg-head\"><h3>" + title + "</h3></div>"),
                div(body.toArray(), attrs: Some(a("ui-dlg-body"))),
                div(foot.toArray(), attrs: Some(a("ui-dlg-foot"))),
            ], attrs: Some(a("ui-dlg"))),
        ], attrs: Some(a("ui-dlg-mask show")))
    }

    func field(label: String, inner: IComponent): IComponent {
        div([
            htmlSpan("<label>" + label + "</label>"),
            inner,
        ], attrs: Some(a("ui-field")))
    }

    func inpField(label: String, value: String, onInput: ActionHandler): IComponent {
        let handled = input(attrs: Some(a("ui-inp"))).on("blur", onInput).attr("value", value)
        div([
            htmlSpan("<label>" + label + "</label>"),
            handled,
        ], attrs: Some(a("ui-field")))
    }
}

// ==================== 追加条目 ====================

@Page["/append", "追加条目", uiNoGuard, UiLayout]
public class AppendPage <: Component {
    var typeName: String = ""
    var task: String = ""
    var status: String = "完成"
    var outcome: String = ""
    var decisions: String = ""
    var next: String = ""
    var proj: String = "chronomem"
    var branch: String = ""
    var ts: String = ""
    var notice: String = ""

    public init() {}

    func ensureType(svc: MemoryService): Unit {
        if (this.typeName == "") {
            let types = uiListTypes(svc)
            if (types.size > 0) { this.typeName = types[0].name }
        }
    }

    public func render(): IComponent {
        setNav("append")
        let svc = svc()
        this.ensureType(svc)
        let children = ArrayList<IComponent>()
        for (__it in pageTitle("追加条目", "mem/append：宽松模式，任意 JSON payload + tags，缺省 ts = now；先落原始 series，结构物化 1 分钟内完成。")) { children.add(__it) }
        let form = ArrayList<IComponent>()
        // 类型
        let typeRow = ArrayList<IComponent>()
        for (t in uiListTypes(svc)) {
            let c = div([text(t.name)], attrs: Some(a(if (this.typeName == t.name) { "ui-chip-sel on" } else { "ui-chip-sel" })))
            let name = t.name
            typeRow.add(c.onClick({ ctx =>
                this.typeName = name
                PatchResult.ReRender
            }))
        }
        form.add(this.field("记忆类型", div(typeRow.toArray(), attrs: Some(a("ui-chips")))))
        form.add(this.inpField("task", this.task, { ctx => this.task = paramStr(ctx.params, "value"); PatchResult.ReRender }))
        // status chips
        let statusRow = ArrayList<IComponent>()
        for (s0 in ["完成", "阶段完成", "进行中"]) {
            let c = div([text(s0)], attrs: Some(a(if (this.status == s0) { "ui-chip-sel on" } else { "ui-chip-sel" })))
            let s1 = s0
            statusRow.add(c.onClick({ ctx =>
                this.status = s1
                PatchResult.ReRender
            }))
        }
        form.add(this.field("status", div(statusRow.toArray(), attrs: Some(a("ui-chips")))))
        form.add(this.inpField("outcome", this.outcome, { ctx => this.outcome = paramStr(ctx.params, "value"); PatchResult.ReRender }))
        form.add(this.inpField("decisions（可选）", this.decisions, { ctx => this.decisions = paramStr(ctx.params, "value"); PatchResult.ReRender }))
        form.add(this.inpField("next（可选）", this.next, { ctx => this.next = paramStr(ctx.params, "value"); PatchResult.ReRender }))
        let grid = ArrayList<IComponent>()
        grid.add(this.inpField("tags · proj", this.proj, { ctx => this.proj = paramStr(ctx.params, "value"); PatchResult.ReRender }))
        grid.add(this.inpField("tags · branch（可选）", this.branch, { ctx => this.branch = paramStr(ctx.params, "value"); PatchResult.ReRender }))
        form.add(div(grid.toArray(), attrs: Some(a("ui-grid2"))))
        form.add(this.inpField("ts（epoch ms，空 = now）", this.ts, { ctx => this.ts = paramStr(ctx.params, "value"); PatchResult.ReRender }))
        let submit = div([text("追加条目")], attrs: Some(a("ui-btn primary")))
        let submitted = submit.onClick({ ctx =>
            let r = this.doAppend(svc)
            this.notice = r.message
            if (r.ok) {
                this.task = ""
                this.outcome = ""
                this.decisions = ""
                this.next = ""
            }
            PatchResult.ReRender
        })
        let submitWrap = ArrayList<IComponent>()
        submitWrap.add(submitted)
        submitWrap.add(htmlSpan("<span class=\"ui-faint\" style=\"font-size:11.5px\"> 宽松模式：不做字段强校验</span>"))
        form.add(div(submitWrap.toArray(), attrs: Some(a("ui-append-submit"))))
        if (this.notice != "") {
            let cls = if (this.notice.startsWith("已")) { "var(--ok)" } else { "var(--danger)" }
            form.add(htmlSpan("<div style=\"margin-top:8px;font-size:12px;color:" + cls + "\">" + this.notice + "</div>"))
        }
        children.add(div(form.toArray(), attrs: Some(a("ui-card"))))
        // JSON 预览
        let preview = ArrayList<IComponent>()
        preview.add(cardTitle("实时 payload", "worklog 模板结构（task/status/outcome/decisions/next + tags）"))
        preview.add(jsonPreview(this.buildPayload()))
        children.add(div(preview.toArray(), attrs: Some(a("ui-card"))))
        div(children.toArray(), attrs: Some(a("ui-page")))
    }

    func doAppend(svc: MemoryService): UiResult {
        let tags = ArrayList<(String, String)>()
        tags.add(("proj", this.proj))
        if (this.branch != "") { tags.add(("branch", this.branch)) }
        let tsArg = parseEpochArg(this.ts)
        let payload = this.buildPayload()
        uiAppend(svc, this.typeName, tsArg, payload, tags)
    }

    func buildPayload(): String {
        let m = HashMap<String, JsonValue>()
        m.add("task", JsonValue.String(this.task))
        m.add("status", JsonValue.String(this.status))
        m.add("outcome", JsonValue.String(this.outcome))
        m.add("decisions", JsonValue.String(this.decisions))
        m.add("next", JsonValue.String(this.next))
        let v = JsonValue.Map(m)
        v.stringify()
    }

    func field(label: String, inner: IComponent): IComponent {
        div([
            htmlSpan("<label>" + label + "</label>"),
            inner,
        ], attrs: Some(a("ui-field")))
    }

    func inpField(label: String, value: String, onInput: ActionHandler): IComponent {
        let handled = input(attrs: Some(a("ui-inp"))).on("blur", onInput).attr("value", value)
        div([
            htmlSpan("<label>" + label + "</label>"),
            handled,
        ], attrs: Some(a("ui-field")))
    }
}

// 忆时塔 Web UI · 页面（2/2）：语义总结 + 记忆类型管理 + 追加条目
// 交互状态一律 Signal<T>（cjxt 脏追踪只认 Signal 订阅；普通字段+ReRender 不会产生补丁）；
// 表单统一使用 cjxt 组件库（Input/Select/RadioGroup/Switch/CheckboxGroup，对齐 Element Plus）。

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
import std.sort.*

// ==================== 语义总结 ====================

@Page["/summary", "语义总结", uiNoGuard]
public class SummaryPage <: Component {
    var typeName = Signal<String>("")
    var mode = Signal<String>("granularity")
    var gran = Signal<String>("day")
    var fromMs = Signal<String>("")
    var toMs = Signal<String>("")
    var instructions = Signal<String>("")
    var notice = Signal<String>("")

    public init() {}

    func ensureType(svc: MemoryService): Unit {
        if (this.typeName.get() == "") {
            let types = uiListTypes(svc)
            if (types.size > 0) { this.typeName.set(types[0].name) }
        }
    }

    public func render(): IComponent {
        let svc = svc()
        this.ensureType(svc)
        let children = ArrayList<IComponent>()
        for (__it in pageTitle("语义总结", "LLM 把窗口条目提炼为结构化摘要（决策/结论/待办/状态变更/关键词），落库为总结记录；后台异步执行，幂等（窗口×分组已有摘要则跳过）。")) { children.add(__it) }

        let meta = uiGetType(svc, this.typeName.get())
        let levels: ArrayList<String> = match (meta) {
            case Some(m) => sortLevels(m.levels)
            case None => ArrayList<String>()
        }
        if (this.gran.get() == "" || !levels.contains(this.gran.get())) {
            this.gran.set(if (levels.size > 0) { levels[0] } else { "day" })
        }

        // ---------- 触发总结表单（EP Form） ----------
        let typeOptions = ArrayList<IComponent>()
        for (t in uiListTypes(svc)) {
            typeOptions.add(SelectOption([text(t.name)], t.name))
        }
        let granRadio = ArrayList<IComponent>()
        for (l in levels) {
            granRadio.add(Radio([text(l)], l))
        }
        let form = ArrayList<IComponent>()
        form.add(FormItem([Select(typeOptions.toArray()).placeholder("记忆类型").bind(this.typeName)]).label("记忆类型"))
        form.add(FormItem([RadioGroup([
            Radio([text("按粒度窗口")], "granularity"),
            Radio([text("显式窗口（任务阶段）")], "custom"),
        ]).bind(this.mode)]).label("总结方式"))
        if (this.mode.get() == "granularity") {
            form.add(FormItem([RadioGroup(granRadio.toArray()).bind(this.gran)]).label("粒度（类型 levels 内）"))
        } else {
            form.add(FormItem([Input().placeholder("epoch ms").bind(this.fromMs)]).label("窗口起始"))
            form.add(FormItem([Input().placeholder("epoch ms").bind(this.toMs)]).label("窗口结束"))
        }
        form.add(FormItem([Input().placeholder("如：提炼本次任务的决策与待办").bind(this.instructions)]).label("补充指令 instructions（可选）"))

        let submit = div([text("提交总结任务")], attrs: Some(a("ui-btn primary")))
        let submitted = submit.onClick({ ctx =>
            let (fromMs, toMs) = this.resolveWindow(svc)
            let r = uiTriggerSummarize(svc, this.typeName.get(), fromMs, toMs, this.instructions.get())
            this.notice.set(r.message)
            PatchResult.ReRender
        })
        let formCard = ArrayList<IComponent>()
        formCard.add(cardTitle("触发总结", "后台异步 · 幂等"))
        formCard.add(div([
            Form(form.toArray()),
            div([submitted], attrs: Some(a("ui-summary-submit"))),
            div([text(this.notice.get())], attrs: Some(a("ui-notice"))),
        ], attrs: Some(a("ui-form-wrap"))))
        children.add(div(formCard.toArray(), attrs: Some(a("ui-card"))))

        // ---------- 总结记录 ----------
        let list = ArrayList<IComponent>()
        list.add(cardTitle("总结记录", "SummaryRecord · 最新在前 · 窗口×分组各一条"))
        let sums = uiSummaries(svc, this.typeName.get(), 100)
        if (sums.size == 0) {
            list.add(emptyBox("暂无总结记录。未配置 LLM 时总结不可用；配置后触发窗口总结即可生成。"))
        } else {
            for (s0 in sums) { list.add(summaryCard(s0)) }
        }
        children.add(div(list.toArray(), attrs: Some(a("ui-card"))))
        uiLayout("summary", div(children.toArray(), attrs: Some(a("ui-page"))))
    }

    func resolveWindow(svc: MemoryService): (Int64, Int64) {
        if (this.mode.get() == "custom") {
            return (parseEpochArg(this.fromMs.get()), parseEpochArg(this.toMs.get()))
        }
        let buckets = uiListBuckets(svc, this.typeName.get(), this.gran.get())
        if (buckets.size > 0) {
            let last = buckets[buckets.size - 1]
            let anchor = parseIsoUtcMs(last.bucketKey)
            if (anchor > 0) {
                let tl = svc.registry.timelineOf(this.typeName.get()).getOrThrow()
                let win = tl.windowRangeOf(anchor, this.gran.get())
                return (win[0], win[1])
            }
        }
        (0, 0)
    }
}

// ==================== 记忆类型 ====================

@Page["/types", "记忆类型", uiNoGuard]
public class TypesPage <: Component {
    var createOpen = Signal<Bool>(false)
    var detailOpen = Signal<Bool>(false)
    var dangerOpen = Signal<Bool>(false)
    var notice = Signal<String>("")
    var cName = Signal<String>("")
    var cDesc = Signal<String>("")
    var cLevels = Signal<ArrayList<String>>(ArrayList<String>(["day", "week"]))
    var cGroupBy = Signal<String>("")
    var cRetention = Signal<String>("")
    var cAuto = Signal<Bool>(true)
    var detailName = Signal<String>("")
    var dangerName = Signal<String>("")

    public init() {}

    public func render(): IComponent {
        let svc = svc()
        let children = ArrayList<IComponent>()
        for (__it in pageTitle("记忆类型", "类型 = 一条独立 series（原始条目 + 同名 .summary 总结），粒度链是类型级配置：高频类型保分钟档，低频类型收敛到 day/week。")) { children.add(__it) }
        let list = ArrayList<IComponent>()
        let head = ArrayList<IComponent>()
        head.add(div([text("类型列表")], attrs: Some(a("ui-card-title"))))
        let createBtn = div([text("+ 创建类型")], attrs: Some(a("ui-btn primary sm")))
        let createHandled = createBtn.onClick({ ctx =>
            this.createOpen.set(true)
            PatchResult.ReRender
        })
        head.add(div([createHandled], attrs: Some(a("ui-head-right"))))
        list.add(div(head.toArray(), attrs: Some(a("ui-card-title ui-card-title-flex"))))
        list.add(this.typeTable(svc))
        let noticeTxt = this.notice.get()
        if (noticeTxt != "") {
            list.add(htmlSpan("<div style=\"margin-top:8px;font-size:12px\">" + noticeTxt + "</div>"))
        }
        list.add(htmlSpan("<div class=\"ui-danger-zone\"><div style=\"font-size:12.5px;color:var(--danger);font-weight:600;margin-bottom:6px\">危险操作</div><div class=\"ui-muted\" style=\"font-size:12px\">清空（TRUNCATE）删除类型全部条目但保留类型；删除（DROP）需先清空，且不可恢复。</div></div>"))
        children.add(div(list.toArray(), attrs: Some(a("ui-card"))))
        if (this.createOpen.get()) {
            children.add(this.createDialog(svc))
        }
        if (this.detailOpen.get()) {
            children.add(this.detailDialog(svc))
        }
        if (this.dangerOpen.get()) {
            children.add(this.dangerDialog(svc))
        }
        uiLayout("types", div(children.toArray(), attrs: Some(a("ui-page"))))
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
            this.detailName.set(name)
            this.detailOpen.set(true)
            PatchResult.ReRender
        }))
        let trash = div([text("清空")], attrs: Some(a("ui-btn sm danger")))
        actions.add(trash.onClick({ ctx =>
            let r = uiTruncate(svc, name)
            this.notice.set(r.message)
            PatchResult.ReRender
        }))
        let del = div([text("删除")], attrs: Some(a("ui-btn sm danger")))
        actions.add(del.onClick({ ctx =>
            this.dangerName.set(name)
            this.dangerOpen.set(true)
            PatchResult.ReRender
        }))
        div(actions.toArray(), attrs: Some(a("ui-tactions")))
    }

    func createDialog(svc: MemoryService): IComponent {
        // levels 多选（EP CheckboxGroup）
        let levelChecks = ArrayList<IComponent>()
        for (l in ["10min", "30min", "1h", "3h", "day", "week", "month"]) {
            levelChecks.add(Checkbox([text(l)], l))
        }
        let dlg = ArrayList<IComponent>()
        dlg.add(FormItem([Input().placeholder("如 proj/decisions").bind(this.cName)]).label("类型名（白名单 [A-Za-z0-9_/-]）"))
        dlg.add(FormItem([Input().placeholder("这个类型记什么").bind(this.cDesc)]).label("描述"))
        dlg.add(FormItem([CheckboxGroup(levelChecks.toArray()).bind(this.cLevels)]).label("粒度链 levels（升序；默认 10min→30min→1h→day→week）"))
        dlg.add(FormItem([Input().placeholder("如 proj（tag 键，上限 2）").bind(this.cGroupBy)]).label("总结分组维度 summary_group_by"))
        dlg.add(FormItem([Input().placeholder("如 30d，留空=全量保留").bind(this.cRetention)]).label("保留期 retention"))
        dlg.add(FormItem([Switch().activeText("开启").inactiveText("关闭").bind(this.cAuto)]).label("后台自动语义总结 auto_summarize"))

        let foot = ArrayList<IComponent>()
        let cancel = div([text("取消")], attrs: Some(a("ui-btn ghost")))
        foot.add(cancel.onClick({ ctx =>
            this.createOpen.set(false)
            PatchResult.ReRender
        }))
        let confirm = div([text("创建")], attrs: Some(a("ui-btn primary")))
        let confirmed = confirm.onClick({ ctx =>
            let groupBy = if (this.cGroupBy.get() == "") { Option<ArrayList<String>>.None } else {
                let g = this.cGroupBy.get().split(",")
                let arr = ArrayList<String>()
                for (x in g) {
                    let t = trimSpace(x)
                    if (t != "") { arr.add(t) }
                }
                if (arr.size == 0) { Option<ArrayList<String>>.None } else { Some(arr) }
            }
            let retention = if (this.cRetention.get() == "") { Option<String>.None } else { Some(this.cRetention.get()) }
            let levels = if (this.cLevels.get().size == 0) { defaultLevelsOf() } else { sortLevels(this.cLevels.get()) }
            let meta = TypeMeta(trimSpace(this.cName.get()), this.cDesc.get(), Option<String>.None, levels, retention,
                this.cAuto.get(), Option<ArrayList<String>>.None, nowMs(), summaryGroupBy: groupBy)
            let r = uiCreateType(svc, meta)
            this.notice.set(r.message)
            this.createOpen.set(false)
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
        let name = this.detailName.get()
        match (uiGetType(svc, name)) {
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
                tr.append("<dt>retention</dt><dd>" + (match (meta.retention) { case Some(rr) => rr case None => "无（全量保留）" }) + "</dd>")
                tr.append("<dt>createdAt</dt><dd>" + fmtDateTime(meta.createdAt, svc.store.timeZoneOf()) + "</dd>")
                body.add(htmlSpan("<dl class=\"ui-meta-kv\" style=\"margin-bottom:12px\">" + tr.toString() + "</dl>"))
                body.add(cardTitle("TypeMeta（json.stream）", ""))
                body.add(jsonPreview(toJsonString(meta)))
            case None => body.add(emptyBox("类型不存在"))
        }
        let foot = ArrayList<IComponent>()
        let close = div([text("关闭")], attrs: Some(a("ui-btn ghost")))
        foot.add(close.onClick({ ctx =>
            this.detailOpen.set(false)
            PatchResult.ReRender
        }))
        this.dialog("类型详情 · " + name, body.toArray(), foot.toArray())
    }

    func groupTextOf(meta: TypeMeta): String {
        match (meta.summaryGroupBy) {
            case Some(g) => "[" + String.join(g.toArray(), delimiter: ", ") + "]"
            case None => "未分组"
        }
    }

    func dangerDialog(svc: MemoryService): IComponent {
        let name = this.dangerName.get()
        let body = ArrayList<IComponent>()
        body.add(htmlSpan("<div style=\"font-size:12.5px;color:var(--muted);margin-bottom:10px\">DROP 语义：原始 + 总结序列必须为空，请先执行清空。此操作<b style=\"color:var(--danger)\">不可恢复</b>：</div>"))
        let foot = ArrayList<IComponent>()
        let cancel = div([text("取消")], attrs: Some(a("ui-btn ghost")))
        foot.add(cancel.onClick({ ctx =>
            this.dangerOpen.set(false)
            PatchResult.ReRender
        }))
        let truncate = div([text("先清空（TRUNCATE）")], attrs: Some(a("ui-btn danger sm")))
        let truncHandled = truncate.onClick({ ctx =>
            let r = uiTruncate(svc, name)
            this.notice.set(r.message)
            PatchResult.ReRender
        })
        foot.add(truncHandled)
        let del = div([text("删除（DROP）")], attrs: Some(a("ui-btn danger")))
        let delHandled = del.onClick({ ctx =>
            let r = uiDeleteType(svc, name)
            if (r.ok) {
                this.dangerOpen.set(false)
            }
            this.notice.set(r.message)
            PatchResult.ReRender
        })
        foot.add(delHandled)
        this.dialog("删除类型 · " + name, body.toArray(), foot.toArray())
    }

    func dialog(title: String, bodyArr: Array<IComponent>, footArr: Array<IComponent>): IComponent {
        div([
            div([
                htmlSpan("<div class=\"ui-dlg-head\"><h3>" + title + "</h3></div>"),
                div(bodyArr.toArray(), attrs: Some(a("ui-dlg-body"))),
                div(footArr.toArray(), attrs: Some(a("ui-dlg-foot"))),
            ], attrs: Some(a("ui-dlg"))),
        ], attrs: Some(a("ui-dlg-mask show")))
    }
}

// ==================== 追加条目 ====================

@Page["/append", "追加条目", uiNoGuard]
public class AppendPage <: Component {
    var typeName = Signal<String>("")
    var task = Signal<String>("")
    var status = Signal<String>("完成")
    var outcome = Signal<String>("")
    var decisions = Signal<String>("")
    var next = Signal<String>("")
    var proj = Signal<String>("chronomem")
    var branch = Signal<String>("")
    var ts = Signal<String>("")
    var notice = Signal<String>("")

    public init() {}

    func ensureType(svc: MemoryService): Unit {
        if (this.typeName.get() == "") {
            let types = uiListTypes(svc)
            if (types.size > 0) { this.typeName.set(types[0].name) }
        }
    }

    public func render(): IComponent {
        let svc = svc()
        this.ensureType(svc)
        let children = ArrayList<IComponent>()
        for (__it in pageTitle("追加条目", "mem/append：宽松模式，任意 JSON payload + tags，缺省 ts = now；先落原始 series，结构物化 1 分钟内完成。")) { children.add(__it) }

        let typeOptions = ArrayList<IComponent>()
        for (t in uiListTypes(svc)) {
            typeOptions.add(SelectOption([text(t.name)], t.name))
        }

        let form = ArrayList<IComponent>()
        form.add(FormItem([Select(typeOptions.toArray()).placeholder("记忆类型").bind(this.typeName)]).label("记忆类型"))
        form.add(FormItem([Input().placeholder("任务/阶段名").bind(this.task)]).label("task"))
        form.add(FormItem([RadioGroup([
            Radio([text("完成")], "完成"),
            Radio([text("阶段完成")], "阶段完成"),
            Radio([text("进行中")], "进行中"),
        ]).bind(this.status)]).label("status"))
        form.add(FormItem([this.longInput("做了什么 / 结果", this.outcome)]).label("outcome"))
        form.add(FormItem([this.longInput("关键决策（可选）", this.decisions)]).label("decisions"))
        form.add(FormItem([this.longInput("后续待办（可选）", this.next)]).label("next"))
        form.add(FormItem([Input().placeholder("如 chronomem").bind(this.proj)]).label("tags · proj"))
        form.add(FormItem([Input().placeholder("如 feat/web-ui（可选）").bind(this.branch)]).label("tags · branch"))
        form.add(FormItem([Input().placeholder("空 = 当前时间").bind(this.ts)]).label("ts（epoch ms）"))

        let submit = div([text("追加条目")], attrs: Some(a("ui-btn primary")))
        let submitted = submit.onClick({ ctx =>
            let r = this.doAppend(svc)
            this.notice.set(r.message)
            if (r.ok) {
                this.task.set("")
                this.outcome.set("")
                this.decisions.set("")
                this.next.set("")
            }
            PatchResult.ReRender
        })
        let formCard = ArrayList<IComponent>()
        formCard.add(cardTitle("worklog 模板结构", "任务阶段 / 任务完成时记一条"))
        formCard.add(div([
            Form(form.toArray()),
            div([submitted, htmlSpan("<span class=\"ui-faint\" style=\"font-size:11.5px\"> 宽松模式：不做字段强校验</span>")], attrs: Some(a("ui-append-submit"))),
            div([text(this.notice.get())], attrs: Some(a("ui-notice"))),
        ], attrs: Some(a("ui-form-wrap"))))
        children.add(div(formCard.toArray(), attrs: Some(a("ui-card"))))
        let preview = ArrayList<IComponent>()
        preview.add(cardTitle("实时 payload", "task/status/outcome/decisions/next + tags"))
        preview.add(jsonPreview(this.buildPayload()))
        children.add(div(preview.toArray(), attrs: Some(a("ui-card"))))
        uiLayout("append", div(children.toArray(), attrs: Some(a("ui-page"))))
    }

    // 长文本：VNode textarea + EP 样式（el-textarea__inner），走 bind 通道
    func longInput(placeholder: String, sig: Signal<String>): IComponent {
        let m = HashMap<String, String>()
        m.add("class", "el-textarea__inner")
        m.add("placeholder", placeholder)
        let ta = VNode("textarea", Array<IComponent>(), attrs: Some(m))
        ta.bind(sig)
    }

    func doAppend(svc: MemoryService): UiResult {
        let tags = ArrayList<(String, String)>()
        tags.add(("proj", this.proj.get()))
        if (this.branch.get() != "") { tags.add(("branch", this.branch.get())) }
        let tsArg = parseEpochArg(this.ts.get())
        let payload = this.buildPayload()
        uiAppend(svc, this.typeName.get(), tsArg, payload, tags)
    }

    func buildPayload(): String {
        let m = HashMap<String, JsonValue>()
        m.add("task", JsonValue.String(this.task.get()))
        m.add("status", JsonValue.String(this.status.get()))
        m.add("outcome", JsonValue.String(this.outcome.get()))
        m.add("decisions", JsonValue.String(this.decisions.get()))
        m.add("next", JsonValue.String(this.next.get()))
        let v = JsonValue.Map(m)
        v.stringify()
    }
}

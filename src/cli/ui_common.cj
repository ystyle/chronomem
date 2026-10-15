// 忆时塔 Web UI · 公共构建器（package chronomem.cli —— 与 main 同包，@Page 页面类的主包）
// 全部元素由原生 div/span/button/text + 全局 class 构建（见 public/css/ui.css），
// 深色塔主题与高保真原型一致；组件库（EP）只在下拉/确认弹窗等少量场景使用。

package chronomem.cli

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import chronomem.ui.*
import chronomem.core.*
import chronomem.mcp.MemoryService
import tsdb.Point
import std.collection.{ArrayList, HashMap}

// ---------- 全局服务引用（main 装配时注入；页面渲染/动作从它读数据） ----------
public var uiSvc: ?MemoryService = None

public func paramStr(m: HashMap<String, String>, k: String): String {
    match (m.get(k)) {
        case Some(v) => v
        case None => ""
    }
}

public func svc(): MemoryService {
    match (uiSvc) {
        case Some(s) => s
        case None => throw Exception("UI 服务未装配")
    }
}

// ---------- attrs ----------

public func a(cls: String): HashMap<String, String> {
    let m = HashMap<String, String>()
    if (cls != "") { m.add("class", cls) }
    m
}

public func a(cls: String, style: String): HashMap<String, String> {
    let m = HashMap<String, String>()
    if (cls != "") { m.add("class", cls) }
    if (style != "") { m.add("style", style) }
    m
}

public func addAttr(m: HashMap<String, String>, k: String, v: String): HashMap<String, String> {
    m.add(k, v)
    m
}

public func withClass(m: HashMap<String, String>, extra: String): HashMap<String, String> {
    let cur = match (m.get("class")) { case Some(c) => c case None => "" }
    let merged = if (cur == "") { extra } else { var tmp = cur; tmp = tmp + " " + extra; tmp }
    m.add("class", merged)
    m
}

// ---------- 标签页 ----------

public func pageTitle(title: String, sub: String): Array<IComponent> {
    [
        div([text(title)], attrs: Some(a("ui-title"))),
        div([text(sub)], attrs: Some(a("ui-sub"))),
    ]
}

public func pill(text0: String, dot: String, cls: String): IComponent {
    let d = if (dot == "") { "" } else { "<span class=\"" + cls + "\" style=\"width:7px;height:7px;border-radius:50%;display:inline-block;box-shadow:0 0 6px currentColor\"></span>" }
    let inner = ArrayList<IComponent>()
    if (dot != "") { inner.add(htmlSpan(d)) } else { () }
    inner.add(htmlSpan(text0))
    htmlSpan("<span class=\"ui-pill\">" + d + text0 + "</span>")
}

// 内联 HTML 小片段（只用于无用户输入的静态标记）
func htmlSpan(html: String): IComponent {
    htmlSpan(html, "span")
}

// 指定标签的内联 HTML 片段（<details>/<div> 等块级容器需要非 span 标签）
func htmlSpan(html: String, tag: String): IComponent {
    // 使用 markdown 组件的 innerhtml 通道太重，这里用原始 VNode + innerhtml 属性
    let m = HashMap<String, String>()
    m.add("innerhtml", html)
    VNode(tag, Array<IComponent>(), attrs: Some(m))
}

public func badge(text0: String, cls: String): IComponent {
    htmlSpan("<span class=\"ui-badge" + (if (cls == "") { "" } else { " " + cls }) + "\">" + text0 + "</span>")
}

public func chip(text0: String, level: String): IComponent {
    htmlSpan("<span class=\"ui-chip " + levelChipClass(level) + "\">" + levelChipText(level) + "</span>")
}

public func chipRaw(text0: String, cls: String): IComponent {
    htmlSpan("<span class=\"ui-chip " + cls + "\">" + text0 + "</span>")
}

public func emptyBox(text0: String): IComponent {
    div([text(text0)], attrs: Some(a("ui-empty")))
}

public func cardTitle(title: String, hint: String): IComponent {
    let children = ArrayList<IComponent>()
    children.add(text(title))
    if (hint != "") {
        children.add(htmlSpan("<span class=\"ui-hint\">" + hint + "</span>"))
    }
    div(children.toArray(), attrs: Some(a("ui-card-title")))
}

// ---------- 标签 chips ----------

public func tagChips(p: Point): IComponent {
    let pairs = parseTags(p.tags)
    let children = ArrayList<IComponent>()
    for ((k, v) in pairs) {
        children.add(badge(k + "=" + v, "ui-mono"))
    }
    div(children.toArray(), attrs: Some(a("p-tags")))
}

// ---------- 统计卡 ----------

public func statCard(k: String, v: String, sub: String, glow: String): IComponent {
    var cls = "ui-stat"
    let children = ArrayList<IComponent>()
    children.add(div([text(k)], attrs: Some(a("k"))))
    children.add(div([text(v)], attrs: Some(a("v"))))
    let subEl = htmlSpan("<small>" + sub + "</small>")
    children.add(subEl)
    children.add(htmlSpan("<span class=\"glow\" style=\"background:" + glow + "\"></span>"))
    div(children.toArray(), attrs: Some(a(cls)))
}

public func statRow(items: ArrayList<IComponent>): IComponent {
    div(items.toArray(), attrs: Some(a("ui-stat-grid")))
}

// ---------- 时间流条目 ----------

public func timeflowItem(ts: Int64, meta: PayloadMeta, proj: String, tags2: ArrayList<(String, String)>): IComponent {
    let status = meta.status
    let done = status == "完成"
    var cls = "ui-tf-item"
    if (done) { cls = "ui-tf-item done" }
    let children = ArrayList<IComponent>()
    children.add(div([text(fmtTime(ts, svc().store.timeZoneOf()))], attrs: Some(a("tf-ts"))))
    let head = ArrayList<IComponent>()
    head.add(htmlSpan("<span class=\"ui-st-" + statusDot(status) + "\">" + esc(status) + "</span>"))
    head.add(text(" " + (if (meta.task != "") { meta.task } else { "（无 task 字段）" })))
    if (proj != "") {
        head.add(htmlSpan("<span class=\"ui-faint\" style=\"font-weight:400;font-size:11px\"> · " + esc(proj) + "</span>"))
    }
    children.add(div(head.toArray(), attrs: Some(a("tf-task"))))
    // 预览 + 展开全文（时间流同样不能让长内容不可读）
    children.add(previewBlock(meta, 200))
    let tc = ArrayList<IComponent>()
    for ((k, v) in tags2) {
        tc.add(badge(k + "=" + v, "ui-mono"))
    }
    children.add(div(tc.toArray(), attrs: Some(a("tf-tags"))))
    div(children.toArray(), attrs: Some(a(cls)))
}

public func statusDot(status: String): String {
    match (status) {
        case "完成" => "ok"
        case "阶段完成" => "phase"
        case _ => "doing"
    }
}

public func statusSpan(status: String): IComponent {
    htmlSpan("<span class=\"ui-" + statusDot(status) + "\">" + status + "</span>")
}

// ---------- 桶卡片 ----------

public func bucketCard(bucketKey: String, granularity: String, count: Int64, sel: Bool, h: ActionHandler): IComponent {
    var cls = "ui-bucket"
    if (sel) { cls = "ui-bucket sel" }
    let label = bucketLocalLabel(bucketKey, granularity, svc().store.timeZoneOf())
    let card = div([
        div([text(label)], attrs: Some(a("b-date"))),
        div([text(count.toString() + " 条")], attrs: Some(a("b-cnt"))),
    ], attrs: Some(a(cls)))
    card.onClick(h)
}

// ---------- 条目卡（下钻点） ----------

public func pointCard(p: Point): IComponent {
    let meta = payloadMeta(p.payload)
    let head = ArrayList<IComponent>()
    head.add(htmlSpan("<span class=\"p-ts\">" + fmtTime(p.ts, svc().store.timeZoneOf()) + "</span>"))
    head.add(statusSpan(meta.status))
    head.add(text(" " + (if (meta.task != "") { meta.task } else { "（无 task 字段）" })))
    div([
        div(head.toArray(), attrs: Some(a("p-head"))),
        previewBlock(meta, 220),
        tagChips(p),
    ], attrs: Some(a("ui-point")))
}

// ---------- 内容预览（可看全） ----------
// 记忆内容不能只有「截断后的预览」：截断必须带一个展开入口，
// 否则长 outcome / decisions / 自定义字段在 UI 上根本读不到。
// <details> 是原生控件：零 JS、无需 cjxt 补丁通道、键盘可达，契合本页「服务端渲染 + WS 补丁」架构。

public func previewBlock(meta: PayloadMeta, limit: Int64): IComponent {
    let pv = previewOf(meta, limit: limit)
    if (!pv.truncated) {
        return div([text(pv.text)], attrs: Some(a("p-out")))
    }
    htmlSpan(
        "<div class=\"p-out\">" + esc(pv.text) + "</div>" +
        "<details class=\"ui-expand\"><summary>展开全文（" + pv.full.size.toString() + " 字节）</summary>" +
        "<pre class=\"ui-fulltext\">" + esc(pv.full) + "</pre></details>",
        "div")
}

// 通用「预览 + 全文」文本块（保留原始换行）
public func fullTextBlock(label: String, raw: String, limit: Int64): IComponent {
    let pv = makePreview(raw, limit)
    if (!pv.truncated) {
        return div([text(pv.text)], attrs: Some(a("p-out")))
    }
    htmlSpan(
        "<div class=\"p-out\">" + esc(pv.text) + "</div>" +
        "<details class=\"ui-expand\"><summary>" + esc(label) + "（" + pv.full.size.toString() + " 字节）</summary>" +
        "<pre class=\"ui-fulltext\">" + esc(pv.full) + "</pre></details>",
        "div")
}

// ---------- 条目详情（全字段） ----------
// payload 是宽松 JSON，字段任意：详情必须列出每个字段（而非只认 task/status/outcome），
// 否则 decisions/next 与自定义字段在「详情」里同样看不到。
public func itemDetailBody(p: Point): Array<IComponent> {
    let out = ArrayList<IComponent>()
    let meta = payloadMeta(p.payload)
    out.add(htmlSpan("<div class=\"ui-detail-meta ui-mono\">" + esc(fmtTime(p.ts, svc().store.timeZoneOf())) +
        " · ts=" + p.ts.toString() + "</div>"))
    if (meta.status != "") {
        out.add(div([statusSpan(meta.status)], attrs: Some(a("ui-detail-status"))))
    }
    let fields = payloadFields(p.payload)
    if (fields.size == 0) {
        out.add(emptyBox("payload 不是 JSON 对象（下方显示原始文本）"))
        out.add(fullTextBlock("展开原始 payload", p.payload, 200))
    } else {
        for (f in fields) {
            let block = ArrayList<IComponent>()
            block.add(div([text(f.key)], attrs: Some(a("ui-detail-key ui-mono"))))
            block.add(fullTextBlock("展开全文", f.value, 400))
            out.add(div(block.toArray(), attrs: Some(a("ui-detail-field"))))
        }
    }
    if (p.tags != "") {
        let tb = ArrayList<IComponent>()
        tb.add(htmlSpan("<div class=\"ui-detail-key\">tags</div>"))
        tb.add(tagChips(p))
        out.add(div(tb.toArray(), attrs: Some(a("ui-detail-field"))))
    }
    out.toArray()
}

// ---------- 通用弹窗 ----------

public func modalShell(title: String, bodyArr: Array<IComponent>, footArr: Array<IComponent>, wide: Bool): IComponent {
    var cls = "ui-dlg"
    if (wide) { cls = "ui-dlg wide" }
    div([
        div([
            htmlSpan("<div class=\"ui-dlg-head\"><h3>" + esc(title) + "</h3></div>"),
            div(bodyArr, attrs: Some(a("ui-dlg-body"))),
            div(footArr, attrs: Some(a("ui-dlg-foot"))),
        ], attrs: Some(a(cls))),
    ], attrs: Some(a("ui-dlg-mask show")))
}

public func modalButton(label: String, cls: String, h: ActionHandler): IComponent {
    let b = div([text(label)], attrs: Some(a("ui-btn" + (if (cls == "") { "" } else { " " + cls }))))
    b.onClick(h)
}

// HTML 文本转义：预览/全文经 innerhtml 通道注入，用户内容里的 < > & 必须转义，
// 否则会被当作标记解析（渲染破坏 + 注入双重风险）。
public func esc(s: String): String {
    let sb = StringBuilder()
    for (r in s.runes()) {
        let c = r.toString()
        match (c) {
            case "&" => sb.append("&amp;")
            case "<" => sb.append("&lt;")
            case ">" => sb.append("&gt;")
            case "\"" => sb.append("&quot;")
            case "'" => sb.append("&#39;")
            case _ => sb.append(c)
        }
    }
    sb.toString()
}

// ---------- 塔层 ----------

public func towerLayer(level: String, label: String, sub: String, metric: String, enabled: Bool, active: Bool, h: Option<ActionHandler>): IComponent {
    var cls = "ui-layer " + layerCssClass(level)
    if (!enabled) { cls = cls + " l-off" }
    if (active) { cls = cls + " l-active" }
    let children = ArrayList<IComponent>()
    children.add(chip("", level))
    children.add(htmlSpan("<span class=\"l-name\">" + esc(label) + "</span>"))
    if (enabled) { children.add(htmlSpan("<span class=\"l-sub\">" + esc(sub) + "</span>")) }
    // 禁用层只标一次「未配置」：图标位放占位符，单位位放文案，
    // 否则 <b>未配置</b><span>未配置</span> 会连读成「未配置未配置」。
    let metricEl = if (enabled) {
        "<b>" + esc(metric) + "</b><span>时间桶</span>"
    } else {
        "<b>—</b><span>未配置</span>"
    }
    children.add(htmlSpan("<span class=\"l-metric\">" + metricEl + "</span>"))
    let layer = div(children.toArray(), attrs: Some(a(cls)))
    match (h) {
        case Some(hh) => layer.onClick(hh)
        case None => layer
    }
}

public func layerCssClass(level: String): String {
    match (level) {
        case "10min" => "l10"
        case "30min" => "l30"
        case "1h" => "l1h"
        case "3h" => "l1h"
        case "day" => "lday"
        case "week" => "lweek"
        case "month" => "lweek"
        case _ => "l1h"
    }
}

public func levelLabel(level: String): String {
    match (level) {
        case "10min" => "10 分钟"
        case "30min" => "30 分钟"
        case "1h" => "1 小时"
        case "3h" => "3 小时"
        case "day" => "日历天"
        case "week" => "自然周"
        case "month" => "自然月"
        case _ => level
    }
}

public func levelSub(level: String): String {
    match (level) {
        case "10min" => "当天精确回想"
        case "30min" => "半小时切片"
        case "1h" => "小时级切片"
        case "3h" => "3 小时切片"
        case "day" => "本地零点对齐"
        case "week" => "周一起点"
        case "month" => "每月 1 号"
        case _ => ""
    }
}

// ---------- 总结卡 ----------

public func summaryCard(item: UiSummaryItem): IComponent {
    let secs = parseSummarySections(item.text)
    let secBlock: (String, ArrayList<String>) -> IComponent = { name, items =>
        let children = ArrayList<IComponent>()
        if (items.size == 0) {
            EmptyVNode()
        } else {
            children.add(htmlSpan("<b>" + name + "</b>"))
            children.add(htmlSpan("<ul>" + joinItems(items) + "</ul>"))
            div(children.toArray(), attrs: Some(a("s-sec")))
        }
    }
    let group = match (item.groupKey) {
        case Some(g) => g
        case None => "未分组"
    }
    let head = ArrayList<IComponent>()
    head.add(htmlSpan("<span class=\"s-group\">【" + group + "】</span>"))
    head.add(htmlSpan("<span class=\"s-meta\">" + fmtTime(item.ts, svc().store.timeZoneOf()) + " · 窗口 " + item.windowFrom.toString() + " ~ " + item.windowTo.toString() + "</span>"))
    head.add(htmlSpan("<span class=\"ui-badge v ui-mono\" style=\"margin-left:auto\">" + item.model + "</span>"))
    head.add(badge("SummaryRecord", "b"))
    let sections = ArrayList<IComponent>()
    sections.add(secBlock("决策", secs.decisions))
    sections.add(secBlock("结论", secs.conclusions))
    sections.add(secBlock("待办", secs.todos))
    sections.add(secBlock("状态变更", secs.statusChanges))
    div([
        div(head.toArray(), attrs: Some(a("s-head"))),
        div(sections.toArray(), attrs: Some(a("s-sections"))),
        div(keywordChips(secs.keywords), attrs: Some(a("s-kw"))),
    ], attrs: Some(a("ui-sum-card")))
}

func joinItems(items: ArrayList<String>): String {
    let sb = StringBuilder()
    for (t in items) {
        sb.append("<li>")
        sb.append(t)
        sb.append("</li>")
    }
    sb.toString()
}

public func keywordChips(kws: ArrayList<String>): IComponent {
    let children = ArrayList<IComponent>()
    for (k in kws) {
        children.add(badge(k, "ui-mono"))
    }
    div(children.toArray(), attrs: Some(a("s-kw")))
}

// ---------- 类型卡（总览） ----------

public func typeCard(meta: TypeMeta, count: Int64): IComponent {
    let levels = sortLevels(meta.levels)
    let groupBy = match (meta.summaryGroupBy) {
        case Some(g) => g
        case None => ArrayList<String>()
    }
    let groupText = if (groupBy.size == 0) { "无" } else { String.join(groupBy.toArray(), delimiter: ", ") }
    let levelText = String.join(levels.toArray(), delimiter: " → ")
    let foot = ArrayList<IComponent>()
    if (meta.autoSummarize) {
        foot.add(badge("✓ auto_summarize", "g"))
    } else {
        foot.add(badge("auto_summarize ✗", ""))
    }
    for (l in levels) {
        foot.add(chip("", l))
    }
    let schemaText = match (meta.schema) {
        case Some(sc) => "schema：" + (if (sc.size > 18) { clampUtf8(sc, 18) + "…" } else { sc })
        case None => "无 schema"
    }
    foot.add(badge(schemaText, "b"))
    div([
        div([
            chipRaw("mem/append", "cday"),
            htmlSpan("<span class=\"tc-name\">" + meta.name + "</span>"),
            badge(count.toString() + " 条", ""),
        ], attrs: Some(a("tc-head"))),
        div([text(meta.description)], attrs: Some(a("tc-desc"))),
        div([
            div([htmlSpan("<b>" + levelText + "</b>")], attrs: Some(a("tc-metrics"))),
            div([text("粒度链")], attrs: Some(a("tc-metrics"))),
            div([htmlSpan("<b>" + groupText + "</b>")], attrs: Some(a("tc-metrics"))),
            div([text("总结分组维度")], attrs: Some(a("tc-metrics"))),
        ], attrs: Some(a("tc-metrics"))),
        div(foot.toArray(), attrs: Some(a("tc-foot"))),
    ], attrs: Some(a("ui-type-card")))
}

// ---------- JSON 展示 ----------

public func jsonPreview(json: String): IComponent {
    div([text(json)], attrs: Some(a("ui-json-preview")))
}

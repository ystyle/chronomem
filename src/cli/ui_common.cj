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
    // 使用 markdown 组件的 innerhtml 通道太重，这里用原始 VNode + innerhtml 属性
    let m = HashMap<String, String>()
    m.add("innerhtml", html)
    VNode("span", Array<IComponent>(), attrs: Some(m))
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

public func timeflowItem(ts: Int64, task: String, status: String, proj: String, out: String, tags2: ArrayList<(String, String)>): IComponent {
    let done = status == "完成"
    var cls = "ui-tf-item"
    if (done) { cls = "ui-tf-item done" }
    let children = ArrayList<IComponent>()
    children.add(div([text(fmtTime(ts, svc().store.timeZoneOf()))], attrs: Some(a("tf-ts"))))
    let head = ArrayList<IComponent>()
    head.add(htmlSpan("<span class=\"ui-st-" + statusDot(status) + "\">" + s(status) + "</span>"))
    head.add(text(" " + task))
    head.add(htmlSpan("<span class=\"ui-faint\" style=\"font-weight:400;font-size:11px\"> · " + proj + "</span>"))
    children.add(div(head.toArray(), attrs: Some(a("tf-task"))))
    children.add(div([text(out)], attrs: Some(a("tf-out"))))
    let tc = ArrayList<IComponent>()
    for ((k, v) in tags2) {
        tc.add(badge(k + "=" + v, "ui-mono"))
    }
    children.add(div(tc.toArray(), attrs: Some(a("tf-tags"))))
    div(children.toArray(), attrs: Some(a(cls)))
}

func s(x: String): String { x }

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
        div([text(outcomePreview(meta))], attrs: Some(a("p-out"))),
        tagChips(p),
    ], attrs: Some(a("ui-point")))
}

// UTF-8 安全截断：字节切片必须停在多字节字符边界（中文 3 字节/字符）
public func clampUtf8(s: String, limit: Int64): String {
    if (s.size <= limit) { return s }
    var cut = limit
    // 若第 cut 字节是续字节（10xxxxxx），说明字符被切断：回退到字符末尾
    while (cut > 0 && (s[cut] & 0xC0u8) == 0x80u8) {
        cut -= 1
    }
    s[0..cut]
}

public func outcomePreview(meta: PayloadMeta): String {
    let out = meta.outcome
    if (out == "") { return meta.task }
    clampUtf8(out, 150) + "…"
}

// ---------- 塔层 ----------

public func towerLayer(level: String, label: String, sub: String, metric: String, enabled: Bool, active: Bool, h: Option<ActionHandler>): IComponent {
    var cls = "ui-layer " + layerCssClass(level)
    if (!enabled) { cls = cls + " l-off" }
    if (active) { cls = cls + " l-active" }
    let children = ArrayList<IComponent>()
    children.add(chip("", level))
    children.add(htmlSpan("<span class=\"l-name\">" + label + "</span>"))
    if (enabled) { children.add(htmlSpan("<span class=\"l-sub\">" + sub + "</span>")) }
    children.add(htmlSpan("<span class=\"l-metric\"><b>" + metric + "</b><span>" + (if (enabled) { "时间桶" } else { "未配置" }) + "</span></span>"))
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

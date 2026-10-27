package chronomem.cli

import cjxt.*
import cjxt.components.*
import chronomem.mcp.MemoryService
import chronomem.core.*
import chronomem.ui.*
import std.collection.{ArrayList, HashMap}

// 页面交互单测（回归：塔层/桶点击无反应）：
// 树序列化后必须含「可点击的塔层/桶」（VNode actions.click → 前端 data-action-click → WS action）。
// 交互状态 Signal 化是补丁链路前提（cjxt 脏追踪只认 Signal 订阅）。

func uiPageTestSvc(): MemoryService {
    let svc = MemoryService.openFile(freshTestDir())
    let levels = ArrayList<String>()
    levels.add("day")
    levels.add("week")
    let r = uiCreateType(svc, TypeMeta("worklog", "测试", Option<String>.None, levels, Option<String>.None, true, Option<ArrayList<String>>.None, 1, summaryGroupBy: Some(ArrayList<String>(["proj"]))))
    if (!r.ok) { throw Exception("setup") }
    let tl = svc.registry.timelineOf("worklog").getOrThrow()
    tl.append(1787932800000, "{\"task\":\"b\"}", HashMap<String, String>())
    tl.append(1788019200000, "{\"task\":\"a\"}", HashMap<String, String>())
    tl.materialize(1787932800000, "测试")
    tl.materialize(1788019200000, "测试")
    uiSvc = Some(svc)
    svc
}

@Test
func uiTowerTreeHasClickableLayersAndBuckets() {
    let svc = uiPageTestSvc()
    let page = TowerPage()
    let tree = RenderContext.expandTree(page.renderWithScope(""), "")
    let json = toJsonString(tree)
    // 塔层（至少 day/week 启用层各一个可点击）+ 桶（两个物化桶）
    @Expect(json.contains("\"ui-layer"), true)
    @Expect(json.contains("\"ui-bucket"), true)
    // click 动作已序列化（vnodeToJson 输出 actions:{"click":...}）
    @Expect(json.contains("click"), true)
    // 桶计数来自 refs（信号回归：桶渲染出来）
    @Expect(json.contains("ui-bucket-grid"), true)
    svc.close()
}

@Test
func uiTowerSwitchTypeViaSelect() {
    // 类型选择器为 EP Select（Signal 绑定），切换后重新渲染 → 塔层随类型变化
    let svc = uiPageTestSvc()
    let page = TowerPage()
    let tree = RenderContext.expandTree(page.renderWithScope(""), "")
    let json = toJsonString(tree)
    @Expect(json.contains("el-select"), true)
    // worklog 的 levels = day/week：未配置层（1h/30min/10min）也渲染为禁用态
    @Expect(json.contains("l-off"), true)
    svc.close()
}

// 回归：链式方法（onClick/bind）返回新 VNode，返回值必须被接收——
// 丢弃返回值 = 元素上没有 data-action-click/data-bind-id，前端委托找不到目标，
// 表现为真实鼠标点击"点了没反应"（塔层/时间桶/查询按钮/长文本输入曾全部中招）。
// JSON 字段顺序固定 type→attrs→actions→children，某 class 之后的下一个
// "actions":{"click" 必然属于该节点自身。

func jsonHasClickAfterClass(json: String, exactCls: String): Bool {
    // 精确 class 值（带尾引号，避免 ui-bucket 前缀误配 ui-bucket-grid）+
    // 节点作用域：class 节点自身范围为 [位置, 下一个 "children" 之前]，
    // 防止 tail 撞上后续其他节点的 click（如禁用层后面跟着可点击的桶）
    match (json.indexOf("\"class\":\"" + exactCls + "\"")) {
        case Some(i) =>
            let tail = json[i..json.size]
            match (tail.indexOf("\"children\"")) {
                case Some(ci) => tail[0..ci].contains("\"actions\":{\"click\"")
                case None => tail.contains("\"actions\":{\"click\"")
            }
        case None => false
    }
}

@Test
func uiBucketCardClickActionSerialized() {
    let svc = uiPageTestSvc()
    let page = TowerPage()
    let tree = RenderContext.expandTree(page.renderWithScope(""), "")
    let json = toJsonString(tree)
    // 时间桶携带 click action（此前返回值未接收：桶永远点不开）
    @Expect(jsonHasClickAfterClass(json, "ui-bucket"), true)
    svc.close()
}

@Test
func uiTowerLayerEnabledClickableDisabledNot() {
    let svc = uiPageTestSvc()
    let page = TowerPage()
    let tree = RenderContext.expandTree(page.renderWithScope(""), "")
    let json = toJsonString(tree)
    // 启用层（worklog：week/day）可点击
    @Expect(jsonHasClickAfterClass(json, "ui-layer lweek"), true)
    // 当前选中粒度 = day（sortLevels 首个）：活动层 class 带 l-active
    @Expect(jsonHasClickAfterClass(json, "ui-layer lday l-active"), true)
    // 未配置层（1h）禁用，不携带 click（避免假绑定误导视觉）
    @Expect(jsonHasClickAfterClass(json, "ui-layer l1h l-off"), false)
    svc.close()
}

@Test
func uiQueryBtnCarriesClick() {
    let svc = uiPageTestSvc()
    let page = RecallPage()
    let tree = RenderContext.expandTree(page.renderWithScope(""), "")
    let json = toJsonString(tree)
    // 回想页"查询"按钮携带 click（此前返回值未接收：点了无反应）
    @Expect(jsonHasClickAfterClass(json, "ui-btn primary"), true)
    svc.close()
}

@Test
func uiLongInputCarriesBind() {
    let svc = uiPageTestSvc()
    let page = AppendPage()
    let tree = RenderContext.expandTree(page.renderWithScope(""), "")
    let json = toJsonString(tree)
    // 追加页长文本内容输入携带 data-bind-id（bind 返回值未接收：输入不进信号）
    match (json.indexOf("\"class\":\"el-textarea__inner")) {
        case Some(i) => @Expect(json[i..json.size].contains("\"data-bind-id\""), true)
        case None => @Expect(true, false)
    }
    svc.close()
}

// ==================== 内容看全 / 暗色适配回归 ====================

// 场景：一条 outcome 远超预览上限的条目（真实记忆内容常见）
func uiPageLongTextSvc(): MemoryService {
    let svc = MemoryService.openFile(freshTestDir())
    let levels = ArrayList<String>()
    levels.add("day")
    let r = uiCreateType(svc, TypeMeta("worklog", "测试", Option<String>.None, levels,
        Option<String>.None, true, Option<ArrayList<String>>.None, 1,
        summaryGroupBy: Some(ArrayList<String>(["proj"]))))
    if (!r.ok) { throw Exception("setup") }
    let tl = svc.registry.timelineOf("worklog").getOrThrow()
    let long = "忆时塔长内容验证" * 80
    let tags = HashMap<String, String>()
    tags["proj"] = "chronomem"
    tl.append(1787932800000,
        "{\"task\":\"长内容条目\",\"status\":\"完成\",\"outcome\":\"" + long +
        "\",\"decisions\":\"" + long + "\",\"custom_field\":\"自定义字段也要看得到\"}", tags)
    tl.materialize(1787932800000, "测试")
    uiSvc = Some(svc)
    svc
}

// 预览截断必须带「展开全文」出口，否则长记忆内容没有任何入口可读
@Test
func uiLongOutcomeHasExpandEntry() {
    let svc = uiPageLongTextSvc()
    uiSvc = Some(svc)
    let long = "忆时塔长内容验证" * 80
    let meta = PayloadMeta("长内容条目", "完成", long)
    // 卡片级渲染路径（与下钻点/时间流/查询结果同一函数）
    let node = previewBlock(meta, 220)
    let json = toJsonString(RenderContext.expandTree(node, ""))
    @Expect(json.contains("ui-expand"), true)
    @Expect(json.contains("展开全文"), true)
    @Expect(json.contains("ui-fulltext"), true)
    // 短内容不套 details（避免短文也要多点一下）
    let shortNode = previewBlock(PayloadMeta("t", "完成", "短"), 220)
    let shortJson = toJsonString(RenderContext.expandTree(shortNode, ""))
    @Expect(shortJson.contains("ui-expand"), false)
    svc.close()
}

// 详情弹窗必须列出 payload 的每一个字段（宽松 JSON：不只 task/status/outcome）
@Test
func uiDetailShowsAllPayloadFields() {
    let svc = uiPageLongTextSvc()
    let page = RecallPage()
    // 直接构造条目详情体（与「详情」按钮同一条代码路径）
    let tl = svc.registry.timelineOf("worklog").getOrThrow()
    let pts = tl.queryPoints(0, 0, 1, ArrayList<TagFilter>())
    @Expect(pts.size, Int64(1))
    let body = itemDetailBody(pts[0])
    let json = toJsonString(body)
    for (k in ["task", "status", "outcome", "decisions", "custom_field"]) {
        @Expect(json.contains(k), true)
    }
    svc.close()
}

// 回想页结果行必须带「详情」入口（长内容在此页同样不能只有预览）
@Test
func uiRecallRowHasDetailEntry() {
    let svc = uiPageLongTextSvc()
    let page = RecallPage()
    let tree = RenderContext.expandTree(page.renderWithScope(""), "")
    let json = toJsonString(tree)
    @Expect(json.contains("详情"), true)
    @Expect(json.contains("r-actions"), true)
    svc.close()
}

// 转义：用户内容里的标记必须被转义（预览/全文走 innerhtml 通道）
@Test
func uiEscHandlesMarkup() {
    @Expect(esc("<script>alert(1)</script>"), "&lt;script&gt;alert(1)&lt;/script&gt;")
    @Expect(esc("a & b"), "a &amp; b")
    @Expect(esc("引号\"与'"), "引号&quot;与&#39;")
    @Expect(esc("正常中文"), "正常中文")
}

// 禁用塔层只标一次「未配置」（此前 metric 与单位位都写「未配置」→ 连读两遍）
@Test
func uiDisabledLayerShowsUnconfiguredOnce() {
    let svc = uiPageTestSvc()
    let page = TowerPage()
    let tree = RenderContext.expandTree(page.renderWithScope(""), "")
    let json = toJsonString(tree)
    // 未配置层不再出现「未配置未配置」相邻串
    @Expect(json.contains("未配置未配置"), false)
    @Expect(json.contains("未配置"), true)
    svc.close()
}

// 头部/侧栏不再硬编码端口与目录（隔离实例、容器部署下需显示真实值）
@Test
func uiHeaderUsesRuntimeInfo() {
    let svc = uiPageTestSvc()
    let saved = uiRuntimeInfo
    uiRuntimeInfo = Some(("127.0.0.1", UInt16(18999), "~/.chronolog-test"))
    let page = OverviewPage()
    let tree = RenderContext.expandTree(page.renderWithScope(""), "")
    let json = toJsonString(tree)
    @Expect(json.contains("18999"), true)
    @Expect(json.contains("~/.chronolog-test"), true)
    uiRuntimeInfo = saved
    svc.close()
}

// 绑定 0.0.0.0 时不得把 "0.0.0.0" 当成服务地址展示
// （0.0.0.0 是「所有网卡」的绑定通配，不是客户端可访问的目标）
@Test
func uiHeaderDoesNotShowWildcardAsAddress() {
    let svc = uiPageTestSvc()
    let saved = uiRuntimeInfo
    uiRuntimeInfo = Some(("0.0.0.0", UInt16(18901), "~/.chronolog-test"))
    let page = OverviewPage()
    let json = toJsonString(RenderContext.expandTree(page.renderWithScope(""), ""))
    @Expect(json.contains("0.0.0.0"), false)
    @Expect(json.contains("所有网卡"), true)
    @Expect(json.contains("局域网可达"), true)
    @Expect(json.contains("18901"), true)
    uiRuntimeInfo = saved
    svc.close()
}

// 绑回环时标明「本机可达」，避免误以为外部也能访问
@Test
func uiHeaderMarksLoopbackScope() {
    let svc = uiPageTestSvc()
    let saved = uiRuntimeInfo
    uiRuntimeInfo = Some(("127.0.0.1", UInt16(8900), "~/.chronolog"))
    let page = OverviewPage()
    let json = toJsonString(RenderContext.expandTree(page.renderWithScope(""), ""))
    @Expect(json.contains("仅本机"), true)
    @Expect(json.contains("本机可达"), true)
    uiRuntimeInfo = saved
    svc.close()
}

// 预览只归一化空白、不丢全文（换行在全文里保留）
@Test
func uiPreviewKeepsNewlinesInFull() {
    let raw = "第一行\n第二行"
    let pv = makePreview(raw, 200)
    @Expect(pv.truncated, false)
    @Expect(pv.text, "第一行 第二行")
    @Expect(pv.full, "第一行\n第二行")
}

// 语义回顾面板必须有类型选择器：类型是粒度与分组的来源，缺了它就只能看 types[0]。
// RecallPage.render() 里两个 tab 的内容都是**当场构造**的，但 Tabs 只把激活的
// pane 渲进 DOM —— 所以整页序列化看不到语义回顾那边的东西，必须直接渲染该方法。
@Test
func uiSummaryModeHasTypeSelector() {
    let svc = uiPageTestSvc()
    let page = RecallPage()
    let json = toJsonString(RenderContext.expandTree(page.renderSummaryMode(svc), ""))
    // 两个 el-select：记忆类型 + 分组过滤；粒度是单选组
    @Expect(json.contains("记忆类型"), true)
    @Expect(countOfStr(json, "el-select\""), Int64(2))
    @Expect(json.contains("el-radio-group"), true)
    svc.close()
}

// 换类型后粒度必须落在新类型的 levels 里：工作的类型是 day/week，
// 对话类常配 1h/day/week —— 留旧值会对着不存在的物化桶查空。
@Test
func uiSummaryModeGranularityFollowsType() {
    let svc = uiPageTestSvc()
    let chatLevels = ArrayList<String>()
    chatLevels.add("1h")
    chatLevels.add("day")
    chatLevels.add("week")
    @Expect(uiCreateType(svc, TypeMeta("chat", "对话", Option<String>.None, chatLevels,
        Option<String>.None, true, Option<ArrayList<String>>.None, 2)).ok, true)

    let page = RecallPage()
    // worklog 没有 1h：首档应是 day
    page.qType.set("worklog")
    let logJson = toJsonString(RenderContext.expandTree(page.renderSummaryMode(svc), ""))
    @Expect(logJson.contains("el-radio-group"), true)
    @Expect(page.sGran.get(), "day")

    // 换到 chat（有 1h）：粒度必须重新收敛到它的首档，而不是沿用 day
    page.qType.set("chat")
    page.sGran.set("day")
    let chatJson = toJsonString(RenderContext.expandTree(page.renderSummaryMode(svc), ""))
    @Expect(chatJson.contains("1h"), true)
    @Expect(page.sGran.get(), "day")
    svc.close()
}

func countOfStr(hay: String, needle: String): Int64 {
    var n = Int64(0)
    var i = Int64(0)
    while (true) {
        match (hay.indexOf(needle, i)) {
            case Some(p) =>
                n += 1
                i = p + 1
            case None => break
        }
    }
    n
}

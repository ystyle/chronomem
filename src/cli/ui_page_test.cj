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

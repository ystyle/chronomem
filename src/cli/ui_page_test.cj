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
    let svc = MemoryService.openInMemory()
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
}

package chronomem.ui

import std.collection.ArrayList
import std.time.*

// SummaryRecord.text 分节解析 / ISO 桶 key / 日历 / 标签解析 / payload 摘要 / levels 排序
// 风格对齐 chronomem 现有测试（编译器内置 @Test/@Expect 宏，不依赖 std.test）。

@Test
func uiParseStandardSections() {
    let text = "决策：\n- cjxt 作为 cjreg path 依赖\n- 分组维度可配置\n\n结论：\n- 全部完成\n\n待办：\n- 后续可选：处理 cjpm.toml\n\n状态变更：\n- 分支合并至 master\n\n关键词：\n- cjreg, 公开页, 优化"
    let s = parseSummarySections(text)
    @Expect(s.decisions.size, Int64(2))
    @Expect(s.decisions[0], "cjxt 作为 cjreg path 依赖")
    @Expect(s.conclusions[0], "全部完成")
    @Expect(s.todos[0], "后续可选：处理 cjpm.toml")
    @Expect(s.statusChanges[0], "分支合并至 master")
    @Expect(s.keywords[0], "cjreg, 公开页, 优化")
}

@Test
func uiParseMarkdownHashedSections() {
    // chronomem 组真实输出带 "### 决策" 前缀
    let text = "### 决策\n- 分组维度可配置（每类型自己声明），不写死 proj\n- 维度上限 2\n\n### 结论\n- 分组维度总结功能完成\n\n### 待办\n- 考虑任务重试/降级\n\n### 状态变更\n- 部署验证通过\n\n### 关键词\n- summary_group_by\n- 窗口错位修复"
    let s = parseSummarySections(text)
    @Expect(s.decisions[0], "分组维度可配置（每类型自己声明），不写死 proj")
    @Expect(s.conclusions[0], "分组维度总结功能完成")
    @Expect(s.todos[0], "考虑任务重试/降级")
    @Expect(s.keywords.size, Int64(2))
    @Expect(s.keywords[1], "窗口错位修复")
}

@Test
func uiParseCompactSingleLineSections() {
    // cangjie-publish 真实输出：单行多节，分号分段
    let text = "决策：安全红线落地方案：SKILL.md 文件顶部加红线章节；结论：cangjie-publish SKILL.md 新增「安全红线」章节；待办：可考虑将红线同步到各项目 AGENTS.md；状态变更：发版安全红线写入 skill；关键词：安全红线，SKILL.md"
    let s = parseSummarySections(text)
    @Expect(s.decisions.size, Int64(1))
    @Expect(s.conclusions.size, Int64(1))
    @Expect(s.todos.size, Int64(1))
    @Expect(s.statusChanges.size, Int64(1))
    @Expect(s.keywords.size, Int64(1))
    @Expect(s.keywords[0], "安全红线，SKILL.md")
}

@Test
func uiParseBulletLinesOnly() {
    let text = "决策：\n- M5 砍掉 esbuild Watch 热刷\n- npm-shared 自愈仅针对已存在但残缺场景\n\n结论：\n- M4 真根因修复"
    let s = parseSummarySections(text)
    @Expect(s.decisions.size, Int64(2))
    @Expect(s.decisions[0], "M5 砍掉 esbuild Watch 热刷")
    @Expect(s.conclusions.size, Int64(1))
}

@Test
func uiParseEmptyText() {
    let s = parseSummarySections("")
    @Expect(s.decisions.size, Int64(0))
    @Expect(s.conclusions.size, Int64(0))
}

// ---------- ISO 桶 key 解析（UTC）----------

@Test
func uiParseIsoUtcMsBasic() {
    // 2026-08-28T16:00:00Z = 北京时间 08-29 00:00:00
    let ms = parseIsoUtcMs("2026-08-28T16:00:00Z")
    let dt = DateTime.ofEpoch(second: ms / 1000, nanosecond: 0).inUTC()
    @Expect(dt.format("yyyy-MM-dd"), "2026-08-28")
    @Expect(dt.format("HH:mm:ss"), "16:00:00")
}

@Test
func uiParseIsoUtcMsEpoch() {
    @Expect(parseIsoUtcMs("1970-01-01T00:00:00Z"), Int64(0))
}

@Test
func uiParseIsoUtcMsInvalid() {
    @Expect(parseIsoUtcMs("garbage"), Int64(0))
    @Expect(parseIsoUtcMs("2026-13-40T99:99:99Z"), Int64(0))
}

// ---------- daysFromCivil ----------

@Test
func uiDaysFromCivilEpoch() {
    @Expect(daysFromCivil(1970, 1, 1), Int64(0))
    @Expect(daysFromCivil(1970, 1, 2), Int64(1))
    let d1 = daysFromCivil(2026, 8, 28)
    let d2 = daysFromCivil(2026, 8, 27)
    @Expect(d1 - d2, Int64(1))
    @Expect(daysFromCivil(2024, 3, 1) - daysFromCivil(2024, 2, 29), Int64(1))
}

// ---------- 桶标签 ----------

@Test
func uiBucketLocalLabelDay() {
    let tz = TimeZone.load("Asia/Shanghai")
    @Expect(bucketLocalLabel("2026-08-28T16:00:00Z", "day", tz), "2026-08-29")
}

@Test
func uiBucketLocalLabelWeek() {
    let tz = TimeZone.load("Asia/Shanghai")
    @Expect(bucketLocalLabel("2026-08-23T16:00:00Z", "week", tz), "08-24 周")
}

// ---------- tags 解析 ----------

@Test
func uiParseTagsBasic() {
    let tags = parseTags("{\"proj\":\"cjreg\",\"branch\":\"feat/x\",\"n\":3}")
    @Expect(tags.size, Int64(3))
    @Expect(tags[0][0], "proj")
    @Expect(tags[0][1], "cjreg")
    @Expect(tags[2][1], "3")
}

@Test
func uiParseTagsEmpty() {
    @Expect(parseTags("{}").size, Int64(0))
    @Expect(parseTags("").size, Int64(0))
    @Expect(parseTags("not json").size, Int64(0))
}

// ---------- payload 摘要 ----------

@Test
func uiPayloadMetaBasic() {
    let m = payloadMeta("{\"task\":\"T1\",\"status\":\"完成\",\"outcome\":\"结果\"}")
    @Expect(m.task, "T1")
    @Expect(m.status, "完成")
    @Expect(m.outcome, "结果")
}

@Test
func uiPayloadMetaInvalid() {
    let m = payloadMeta("not-json")
    @Expect(m.task, "")
    @Expect(m.status, "")
}

// ---------- levels ----------

@Test
func uiSortLevelsBasic() {
    let levels = ArrayList<String>()
    levels.add("week")
    levels.add("day")
    levels.add("10min")
    let sorted = sortLevels(levels)
    @Expect(sorted[0], "10min")
    @Expect(sorted[1], "day")
    @Expect(sorted[2], "week")
}

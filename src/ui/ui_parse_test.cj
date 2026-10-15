package chronomem.ui

import std.collection.ArrayList
import std.collection.HashMap
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
func uiParseBulletDotPrefix() {
    // "·" 为 3 字节 UTF-8：前缀剥离不能切成续字节（曾导致 Invalid utf8）
    let text = "决策：\n· 分组维度可配置\n· 无 tag 条目归未分组\n\n结论：\n- 完成"
    let s = parseSummarySections(text)
    @Expect(s.decisions.size, Int64(2))
    @Expect(s.decisions[0], "分组维度可配置")
    @Expect(s.decisions[1], "无 tag 条目归未分组")
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

// ---------- UTF-8 安全截断（回归：切在字符中间 → 非法 UTF-8 → 前端解码失败）----------

@Test
func uiClampUtf8Boundary() {
    // 中文 3 字节/字符：limit 落在字符中间时必须回退到字符边界
    @Expect(clampUtf8("忆时塔时间记忆", 7), "忆时")
    @Expect(clampUtf8("chronomem忆时塔", 12), "chronomem忆")
    @Expect(clampUtf8("abc", 10), "abc")
    @Expect(clampUtf8("abcdef", 3), "abc")
    @Expect(clampUtf8("任意", 0), "")
    // 恰好等于 limit 不截断（省略号由预览层负责追加）
    @Expect(clampUtf8("abcdefghij", 10), "abcdefghij")
    @Expect(clampUtf8("abcdefghij", 5), "abcde")
}

// ---------- payload 字段扁平化（回归：只展示 task/status/outcome = 内容看不全）----------

@Test
func uiPayloadFieldsAll() {
    let fs = payloadFields("{\"task\":\"T\",\"status\":\"完成\",\"outcome\":\"O\",\"decisions\":\"D\",\"next\":\"N\",\"extra\":\"E\"}")
    @Expect(fs.size, Int64(6))
    var keys = ArrayList<String>()
    for (f in fs) { keys.add(f.key) }
    // 键升序，渲染稳定
    @Expect(keys[0], "decisions")
    @Expect(keys[1], "extra")
    @Expect(keys[2], "next")
    @Expect(keys[3], "outcome")
    @Expect(keys[4], "status")
    @Expect(keys[5], "task")
    @Expect(fs[0].value, "D")
    @Expect(fs[5].value, "T")
}

@Test
func uiPayloadFieldsNonScalar() {
    let fs = payloadFields("{\"n\":3,\"b\":true,\"arr\":[1,2],\"nul\":null}")
    var got = HashMap<String, String>()
    for (f in fs) { got[f.key] = f.value }
    @Expect(got["n"], "3")
    @Expect(got["b"], "true")
    @Expect(got["arr"], "[1,2]")
    @Expect(got["nul"], "")
}

@Test
func uiPayloadFieldsInvalid() {
    @Expect(payloadFields("not-json").size, Int64(0))
    @Expect(payloadFields("[1,2]").size, Int64(0))
    @Expect(payloadFields("{}").size, Int64(0))
}

// ---------- 预览/全文（回归：截断后没有任何入口看全内容）----------

@Test
func uiNormalizeInlineCollapsesWhitespace() {
    @Expect(normalizeInline("a\n\nb\t c  d"), "a b c d")
    @Expect(normalizeInline("  前导与尾随  "), "前导与尾随")
    @Expect(normalizeInline("单行"), "单行")
    @Expect(normalizeInline(""), "")
    // 多字节字符不得被切坏
    @Expect(normalizeInline("忆\n时\t塔"), "忆 时 塔")
}

@Test
func uiPreviewKeepsFullText() {
    let long = "忆时塔" * 200
    let pv = makePreview(long, 150)
    @Expect(pv.truncated, true)
    // 全文必须原样保留（长度按字节）
    @Expect(pv.full.size, long.size)
    // 预览不超限 + 省略号
    @Expect(pv.text.size <= 150 + 3, true)
    @Expect(pv.text.endsWith("…"), true)
}

@Test
func uiPreviewShortNotTruncated() {
    let pv = makePreview("短内容", 150)
    @Expect(pv.truncated, false)
    @Expect(pv.text, "短内容")
    @Expect(pv.full, "短内容")
}

@Test
func uiPreviewOfFallsBackToTask() {
    // outcome 为空时回退 task（旧行为），避免空预览
    let meta = PayloadMeta("任务名", "完成", "")
    let pv = previewOf(meta)
    @Expect(pv.text, "任务名")
}

@Test
func uiDescPreviewMarksTruncation() {
    // 列表里的描述需要「看全入口」判据：截断必须可识别
    let short = descPreview("短描述")
    @Expect(short.truncated, false)
    let long = descPreview("这是一段很长的类型描述，" * 10)
    @Expect(long.truncated, true)
    @Expect(long.full.size > long.text.size, true)
}

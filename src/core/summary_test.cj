package chronomem.core

import std.collection.*

// 固定结构 json 往返测试：TypeMeta / SummaryRecord。

@Test
func typeMeta_jsonRoundtrip() {
    let m = TypeMeta("worklog", "desc", Some("{\"a\":\"s\"}"), dayWeekLevels(), Some("30d"),
        true, Some(dayWeekLevels()), TEST_BASE)
    let json = toJsonString(m)
    let back = fromJsonString<TypeMeta>(json)
    @Expect(back.name, "worklog")
    @Expect(back.description, "desc")
    match (back.schema) {
        case Some(s) => @Expect(s, "{\"a\":\"s\"}")
        case None => @Fail("schema 丢失")
    }
    @Expect(back.levels.size, Int64(2))
    match (back.retention) {
        case Some(r) => @Expect(r, "30d")
        case None => @Fail("retention 丢失")
    }
    @Expect(back.autoSummarize, true)
    match (back.summaryLevels) {
        case Some(ls) => @Expect(ls.size, Int64(2))
        case None => @Fail("summaryLevels 丢失")
    }
    match (back.summaryGroupBy) {
        case None => ()
        case Some(_) => @Fail("summaryGroupBy 应为 None")
    }
    @Expect(back.createdAt, TEST_BASE)
}

@Test
func typeMeta_jsonRoundtrip_summaryGroupBy() {
    let gb = ArrayList<String>()
    gb.add("proj")
    gb.add("branch")
    let m = TypeMeta("worklog", "desc", None, dayWeekLevels(), None, true, None, TEST_BASE,
        summaryGroupBy: Some(gb))
    let back = fromJsonString<TypeMeta>(toJsonString(m))
    match (back.summaryGroupBy) {
        case Some(dims) =>
            @Expect(dims.size, Int64(2))
            @Expect(dims[0], "proj")
            @Expect(dims[1], "branch")
        case None => @Fail("summaryGroupBy 丢失")
    }
}

@Test
func typeMeta_jsonRoundtrip_nullableMissing() {
    let m = TypeMeta("t", "", None, dayWeekLevels(), None, false, None, TEST_BASE)
    let back = fromJsonString<TypeMeta>(toJsonString(m))
    @Expect(back.schema, None)
    @Expect(back.retention, None)
    @Expect(back.autoSummarize, false)
    match (back.summaryLevels) {
        case None => ()
        case Some(_) => @Fail("summaryLevels 应为 None")
    }
    match (back.summaryGroupBy) {
        case None => ()
        case Some(_) => @Fail("summaryGroupBy 应为 None")
    }
}

@Test
func summaryRecord_jsonRoundtrip() {
    let refs = ArrayList<Int64>()
    refs.add(Int64(1))
    refs.add(Int64(2))
    let s = SummaryRecord(Int64(100), Int64(0), Int64(200), "qwen3", refs, "inst", "决策：X")
    let back = fromJsonString<SummaryRecord>(toJsonString(s))
    @Expect(back.text, "决策：X")
    @Expect(back.model, "qwen3")
    @Expect(back.refs.size, Int64(2))
    @Expect(back.windowTo, Int64(200))
    @Expect(back.instructions, "inst")
    match (back.groupKey) {
        case None => ()
        case Some(_) => @Fail("groupKey 应为 None")
    }
}

@Test
func summaryRecord_jsonRoundtrip_groupKey() {
    let refs = ArrayList<Int64>()
    refs.add(Int64(1))
    let s = SummaryRecord(Int64(100), Int64(0), Int64(200), "qwen3", refs, "inst", "决策：X",
        groupKey: Some("xisp"))
    let back = fromJsonString<SummaryRecord>(toJsonString(s))
    match (back.groupKey) {
        case Some(g) => @Expect(g, "xisp")
        case None => @Fail("groupKey 丢失")
    }
}

package chronomem.core

import std.collection.*

// 固定结构 json 往返测试：TypeMeta / SummaryRecord。

@Test
func typeMeta_jsonRoundtrip() {
    let m = TypeMeta("worklog", "desc", Some("{\"a\":\"s\"}"), dayWeekLevels(), Some("30d"), TEST_BASE)
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
    @Expect(back.createdAt, TEST_BASE)
}

@Test
func typeMeta_jsonRoundtrip_nullableMissing() {
    let m = TypeMeta("t", "", None, dayWeekLevels(), None, TEST_BASE)
    let back = fromJsonString<TypeMeta>(toJsonString(m))
    @Expect(back.schema, None)
    @Expect(back.retention, None)
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
}

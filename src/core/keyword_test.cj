package chronomem.core

import std.collection.*

// ===== keyword 解析与匹配 =====
//
// 这一层的约定是"**空关键词不等于匹配一切**"：不传 keyword 时由调用方跳过，
// 但一旦传了、且能拆出词，就必须都命中。拆完后为空说明根本没给内容条件
// （全是空白），此时不做过滤是对的；拆出空串则必须报错——空串匹配一切，
// 让一个空段参与 AND 等于把"搜两个词"悄悄变成"什么都没搜"。

@Test
func keywordParseSingle() {
    let p = parseKeywords("nftables")
    @Expect(p.isOk(), true)
    @Expect(p.keywords.size, Int64(1))
    @Expect(p.keywords[0], "nftables")
}

@Test
func keywordParseEmptyMeansNoFilter() {
    for (input in ["", "   ", "\t\n", "  \t \n "]) {
        let p = parseKeywords(input)
        @Expect(p.isOk(), true)
        @Expect(p.isEmpty(), true)
    }
}

@Test
func keywordParseMultipleIsAnd() {
    let p = parseKeywords("图片 报错")
    @Expect(p.keywords.size, Int64(2))
    @Expect(p.keywords[0], "图片")
    @Expect(p.keywords[1], "报错")
}

// 连续空白不能拆出空串：空串匹配一切，会静默把 AND 变成"无条件"
@Test
func keywordParseCollapsesRunsOfWhitespace() {
    let p = parseKeywords("图片   报错")
    @Expect(p.keywords.size, Int64(2))
    @Expect(p.keywords[0], "图片")
    @Expect(p.keywords[1], "报错")
    let tabs = parseKeywords("图片\t报错\n更多")
    @Expect(tabs.keywords.size, Int64(3))
}

@Test
func keywordParseLowercases() {
    let p = parseKeywords("NFTables DSH_SESSION_ID")
    @Expect(p.keywords[0], "nftables")
    @Expect(p.keywords[1], "dsh_session_id")
}

@Test
func keywordMatchesAllTerms() {
    let kw = parseKeywords("图片 报错").keywords
    @Expect(matchesKeywords("{\"note\":\"图片上传时报错\"}", kw), true)
    // 顺序无关
    @Expect(matchesKeywords("{\"note\":\"报错发生在图片上传\"}", kw), true)
    // 缺一个 → 不命中（AND 语义）
    @Expect(matchesKeywords("{\"note\":\"图片上传成功\"}", kw), false)
    @Expect(matchesKeywords("{\"note\":\"报错了\"}", kw), false)
}

@Test
func keywordMatchesIsCaseInsensitive() {
    let kw = parseKeywords("nftables").keywords
    @Expect(matchesKeywords("用 NFTables 配规则", kw), true)
    @Expect(matchesKeywords("用 nftables 配规则", kw), true)
}

// 未指定关键词 = 恒命中（调用方不必特判）
@Test
func keywordMatchesEmptyPatternMatchesEverything() {
    let empty = parseKeywords("").keywords
    @Expect(matchesKeywords("任何内容", empty), true)
    @Expect(matchesKeywords("", empty), true)
}

// 关键词可以命中字段名：payload 原文扫描，不解析 JSON
@Test
func keywordMatchesFieldNamesToo() {
    let kw = parseKeywords("cause").keywords
    @Expect(matchesKeywords("{\"cause\":\"x\"}", kw), true)
}

// 中文按字节包含判断——UTF-8 里不可能把一个完整字符误判成另一个词的前缀
@Test
func keywordMatchesChineseSubstring() {
    let kw = parseKeywords("老舅").keywords
    @Expect(matchesKeywords("这老舅的账我真服了", kw), true)
    @Expect(matchesKeywords("老舅舅", kw), true)
    @Expect(matchesKeywords("老 舅", kw), false)
}

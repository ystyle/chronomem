package chronomem.mcp

import chronomem.core.*
import jsonvalue.*
import std.collection.*

// mem/query 的 tag 多条件语法。
//
// 语法（首版刻意保持最小）：
//   tag: "proj=chronomem"                 单条件（与旧行为完全一致，向后兼容）
//   tag: "proj=chronomem role=user"       空格分隔 = 多个条件 **AND**
//   tag: "status=todo,done"               逗号分隔 = 同 tag 多值 **IN**（OR）
//   tag: "status=todo,done room=r1"       IN 与 AND 可组合
//
// 为什么不支持 OR / 存在性 / 否定：mem/query 的调用方是 LLM 客户端，语法越少越不易误用；
// 而实际查询以「固定条件 + AND」为主。需要这些语义时再单独设计参数（不塞进这一个字符串）。
//
// 解析必须严格：非法输入要给出明确错误，**不能静默当成「无过滤」**——否则会把
// 「查某个项目」悄悄变成「查全部条目」，返回大量无关数据而调用方毫不知情。

// 直接测解析函数（不经过 MCP 层），把语法契约钉在最小单元上
@Test
func tagFiltersSingleCondition() {
    let r = parseTagFilters("proj=chronomem")
    @Expect(r.isOk(), true)
    @Expect(r.filters.size, 1)
    @Expect(r.filters[0].tag, "proj")
    @Expect(r.filters[0].values.size, 1)
    @Expect(r.filters[0].values[0], "chronomem")
}

@Test
func tagFiltersEmptyMeansNoFilter() {
    // 空串 = 不过滤（旧行为：调用方不传 tag 时 argStr 返回空串）
    let r = parseTagFilters("")
    @Expect(r.isOk(), true)
    @Expect(r.filters.size, 0)
}

@Test
func tagFiltersAndAcrossConditions() {
    let r = parseTagFilters("proj=chronomem role=user")
    @Expect(r.isOk(), true)
    @Expect(r.filters.size, 2)
    @Expect(r.filters[0].tag, "proj")
    @Expect(r.filters[0].values[0], "chronomem")
    @Expect(r.filters[1].tag, "role")
    @Expect(r.filters[1].values[0], "user")
}

@Test
func tagFiltersInValues() {
    let r = parseTagFilters("status=todo,done")
    @Expect(r.isOk(), true)
    @Expect(r.filters.size, 1)
    @Expect(r.filters[0].tag, "status")
    @Expect(r.filters[0].values.size, 2)
    @Expect(r.filters[0].values[0], "todo")
    @Expect(r.filters[0].values[1], "done")
}

@Test
func tagFiltersInAndAnd() {
    let r = parseTagFilters("status=todo,done room=r1")
    @Expect(r.isOk(), true)
    @Expect(r.filters.size, 2)
    @Expect(r.filters[0].values.size, 2)
    @Expect(r.filters[1].tag, "room")
}

@Test
func tagFiltersExtraSpacesTolerated() {
    // 多空格 / 首尾空格都要容忍（调用方是人或 LLM，格式不会总是规整）
    let r = parseTagFilters("  proj=p1   role=user  ")
    @Expect(r.isOk(), true)
    @Expect(r.filters.size, 2)
}

@Test
func tagFiltersDuplicateValuesDeduped() {
    let r = parseTagFilters("status=todo,todo")
    @Expect(r.isOk(), true)
    @Expect(r.filters[0].values.size, 1)
}

@Test
func tagFiltersRejectMissingEquals() {
    // 无 '=' 是笔误：必须报错，不能当成「查值为空」或「无过滤」
    let r = parseTagFilters("proj")
    @Expect(r.isOk(), false)
}

@Test
func tagFiltersRejectEmptyKey() {
    let r = parseTagFilters("=v")
    @Expect(r.isOk(), false)
}

@Test
func tagFiltersRejectEmptyValue() {
    let r = parseTagFilters("proj=")
    @Expect(r.isOk(), false)
}

@Test
func tagFiltersRejectEmptyInItem() {
    // "status=todo," 尾部空项是笔误
    let r = parseTagFilters("status=todo,")
    @Expect(r.isOk(), false)
}

// ---------- 端到端：真的作用到查询上 ----------

func multiTagSvc(): MemoryService {
    let s = svc()
    handleTypeCreate(s, argsFromJson("{\"name\":\"mt\",\"levels\":[\"day\"]}"))
    // 三种组合，覆盖 AND 与 IN 的判定
    handleAppend(s, argsFromJson("{\"type\":\"mt\",\"payload\":{\"t\":\"a\"},\"ts\":1000,\"tags\":{\"proj\":\"p1\",\"role\":\"user\"}}"))
    handleAppend(s, argsFromJson("{\"type\":\"mt\",\"payload\":{\"t\":\"b\"},\"ts\":2000,\"tags\":{\"proj\":\"p2\",\"role\":\"user\"}}"))
    handleAppend(s, argsFromJson("{\"type\":\"mt\",\"payload\":{\"t\":\"c\"},\"ts\":3000,\"tags\":{\"proj\":\"p1\",\"role\":\"assistant\"}}"))
    handleAppend(s, argsFromJson("{\"type\":\"mt\",\"payload\":{\"t\":\"d\"},\"ts\":4000,\"tags\":{\"proj\":\"p3\",\"role\":\"user\"}}"))
    s
}

@Test
func memQuerySingleTagStillWorks() {
    // 向后兼容：单条件行为与升级前完全一致
    let s = multiTagSvc()
    let r = resultText(handleQuery(s, argsFromJson("{\"type\":\"mt\",\"tag\":\"proj=p1\"}")))
    @Expect(r.indexOf("共 2 条") != None, true)
    @Expect(r.indexOf("proj=p1") != None, true)
    s.close()
}

@Test
func memQueryMultiTagAnd() {
    // proj=p1 AND role=user → 只有 a
    let s = multiTagSvc()
    let r = resultText(handleQuery(s, argsFromJson("{\"type\":\"mt\",\"tag\":\"proj=p1 role=user\"}")))
    @Expect(r.indexOf("共 1 条") != None, true)
    s.close()
}

@Test
func memQueryTagIn() {
    // role in (user) 的实际价值在下方；这里先验 IN 单值等价
    let s = multiTagSvc()
    let r = resultText(handleQuery(s, argsFromJson("{\"type\":\"mt\",\"tag\":\"proj=p1,p2\"}")))
    @Expect(r.indexOf("共 3 条") != None, true)
    s.close()
}

@Test
func memQueryTagInAndAnd() {
    // proj in (p1,p2) AND role=user → a、b
    let s = multiTagSvc()
    let r = resultText(handleQuery(s, argsFromJson("{\"type\":\"mt\",\"tag\":\"proj=p1,p2 role=user\"}")))
    @Expect(r.indexOf("共 2 条") != None, true)
    s.close()
}

@Test
func memQueryTagAndNoMatch() {
    let s = multiTagSvc()
    let r = resultText(handleQuery(s, argsFromJson("{\"type\":\"mt\",\"tag\":\"proj=p1 role=nobody\"}")))
    @Expect(r.indexOf("无匹配条目") != None, true)
    s.close()
}

@Test
func memQueryBadTagSyntaxIsError() {
    // 关键安全性：语法错误必须报错，绝不能静默降级为「无过滤」
    let s = multiTagSvc()
    let r = handleQuery(s, argsFromJson("{\"type\":\"mt\",\"tag\":\"proj\"}"))
    @Expect(r.isError, true)
    // 校验错误信息里带上正确写法提示
    @Expect(resultText(r).indexOf("key=value") != None, true)
    s.close()
}

@Test
func memQueryMultiTagPagination() {
    // 多条件与页码分页组合：总数与页内容都要对
    let s = multiTagSvc()
    let r = resultText(handleQuery(s, argsFromJson(
        "{\"type\":\"mt\",\"tag\":\"proj=p1,p2 role=user\",\"limit\":1,\"page\":1}")))
    @Expect(r.indexOf("共 2 条") != None, true)
    @Expect(r.indexOf("第 1/2 页") != None, true)
    let r2 = resultText(handleQuery(s, argsFromJson(
        "{\"type\":\"mt\",\"tag\":\"proj=p1,p2 role=user\",\"limit\":1,\"page\":2}")))
    @Expect(r2.indexOf("第 2/2 页") != None, true)
    s.close()
}

@Test
func memQueryMultiTagWithTimeRange() {
    // 与时间范围组合：role=user 的点是 b@2000、d@4000，窗口 [1500,3500] 内只剩 b
    let s = multiTagSvc()
    let r = resultText(handleQuery(s, argsFromJson(
        "{\"type\":\"mt\",\"tag\":\"role=user\",\"from\":1500,\"to\":3500}")))
    @Expect(r.indexOf("共 1 条") != None, true)
    s.close()
}

@Test
func memQuerySameTagTwiceIsAnd() {
    // 同一 tag 写两遍 = 两个 AND 条件，必然无交集（不合并成 IN，避免语义歧义）
    let s = multiTagSvc()
    let r = resultText(handleQuery(s, argsFromJson("{\"type\":\"mt\",\"tag\":\"proj=p1 proj=p2\"}")))
    @Expect(r.indexOf("无匹配条目") != None, true)
    s.close()
}

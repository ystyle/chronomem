package chronomem.cli


// clampUtf8：UTF-8 字节切片安全截断（生产事故回归：长中文 outcome 截断在字符中间 → Invalid utf8 → 500）

@Test
func clampUtf8AsciiPassthrough() {
    @Expect(clampUtf8("abc", 10), "abc")
    @Expect(clampUtf8("abcdef", 3), "abc")
}

@Test
func clampUtf8ChineseBoundary() {
    // 中文 3 字节/字符：limit 落在字符中间时必须回退到字符边界
    let s = "忆时塔时间记忆"
    let r = clampUtf8(s, 7)   // 7 = 2 个完整中文（6 字节）+ 第 3 字符第 1 字节位置
    @Expect(r, "忆时")
}

@Test
func clampUtf8MixedBoundary() {
    // 英文 + 中文混合
    let s = "chronomem忆时塔时间记忆"
    let r = clampUtf8(s, 12)  // 9 字节英文 + 第 1 个中文的第 3 字节位置（12 = 9+3 恰好在字符末尾）
    @Expect(r, "chronomem忆")
}

@Test
func clampUtf8ExactLimit() {
    let s = "abcdefghij"
    @Expect(clampUtf8(s, 10), "abcdefghij")
    // 长度恰好等于 limit 不追加省略号（截断样式在 outcomePreview 层处理）
    let r = clampUtf8(s, 5)
    @Expect(r, "abcde")
}

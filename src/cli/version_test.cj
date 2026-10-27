package chronomem.cli

// 版本号来自编译期的 cjpm.toml（cjpminfo 的 @ModuleVer），不手写。
// 手写的版本号必然与实际发布脱节：打过 v0.1.1 的 tag，代码里还写着 0.1.0。
@Test
func versionComesFromCjpmToml() {
    @Expect(APP_VERSION.size > 0, true)
    // 与 cjpm.toml 的 [package] version 一致（此处钉住格式，不是具体数字）
    @Expect(APP_VERSION.contains("."), true)
    // 宏取不到时会退回默认值并打 stderr；默认值必须能被识别出来。
    // 这条是真正验证"注入成功"的断言：读到 cjpm.toml 才会是具体版本号。
    @Expect(APP_VERSION != "0.0.0-unknown", true)
    // 与清单里的值逐字一致（改 version 忘了同步时这里会红，提醒重跑构建）
    @Expect(APP_VERSION, "0.1.1")
}

@Test
func versionStringIsReadable() {
    let s = appVersionText()
    @Expect(s.contains(APP_VERSION), true)
    @Expect(s.contains("chronomem"), true)
}

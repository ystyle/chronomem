package chronomem.cli

import std.fs.*

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
    // 与清单里的值逐字一致。**从 cjpm.toml 读当前值来比**，不写死数字：
    // 写死的话每次发版都要改测试，而"改测试让它变绿"正是版本号脱节的典型起点。
    // 读到清单（cjpm test 的 cwd 是包根）就逐字比；读不到（例如别的目录下跑）跳过这条，
    // 前两条断言已经证明宏注入成功。
    match (readProjectVersion()) {
        case Some(v) => @Expect(APP_VERSION, v)
        case None => ()
    }
}

// 从 cjpm.toml 里取 [package] 的 version（找不到返回 None）。
// 只用最简单的前缀匹配，不引 TOML 解析器——测试里要的是"清单里写的那个字符串"。
func readProjectVersion(): Option<String> {
    try {
        let text = String.fromUtf8(File.readFrom(Path("./cjpm.toml")))
        var inPackage = false
        for (line in text.split("\n")) {
            let t = line.trimAscii()
            if (t.startsWith("[") && t.endsWith("]")) {
                inPackage = (t == "[package]")
                continue
            }
            if (inPackage && t.startsWith("version")) {
                match (t.indexOf("=")) {
                    case Some(i) =>
                        var v = t[i + 1..t.size].trimAscii()
                        v = v.replace("\"", "")
                        return Some(v)
                    case None => ()
                }
            }
        }
        None
    } catch (_) {
        None
    }
}

@Test
func versionStringIsReadable() {
    let s = appVersionText()
    @Expect(s.contains(APP_VERSION), true)
    @Expect(s.contains("chronomem"), true)
}

// 单独钉住"能从清单读到版本号"这条前提：上一条断言在读到 None 时会静默跳过，
// 若某天 cjpm test 的 cwd 变了，那条就退化成永远为真——这里显式报出来。
@Test
func projectVersionIsReadable() {
    match (readProjectVersion()) {
        case Some(v) =>
            @Expect(v.size > 0, true)
            @Expect(v.contains("."), true)
        case None => @Fail("读不到 ./cjpm.toml 的 [package] version：版本一致性断言已失去意义")
    }
}

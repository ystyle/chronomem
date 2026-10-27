// 版本信息：编译期从 cjpm.toml 读取，不手写。
//
// 为什么用宏而不是常量：手写的版本号一定会和实际发布脱节（tag 打了 v0.1.1，
// 代码里还写着 0.1.0）。cjpminfo 的 @ModuleVer 在编译时读**本包**的 cjpm.toml，
// 因此发布前改 version 一处即可，代码与制品自动一致。
//
// 注意：宏读的是"当前正在编译的包"的清单（见 cjpminfo README 的
// 「作为依赖被编译」一条），所以必须在 chronomem.cli 包里用，才能拿到
// chronomem 自己的版本号，而不是某个依赖的。
package chronomem.cli

import cjpminfo.*

/**
 * 应用版本（来自 cjpm.toml 的 `[package] version`）。
 *
 * 默认值刻意取一个一眼能认出来的串：宏取不到清单时会退回它，
 * 于是 `0.0.0-unknown` 出现在界面上就等于"版本注入坏了"，不会被误当成真版本。
 */
public let APP_VERSION: String = @ModuleVer("0.0.0-unknown")

/** 一行式版本描述（CLI 与 UI 共用，避免两处拼格式）。 */
public func appVersionText(): String {
    "chronomem " + APP_VERSION
}

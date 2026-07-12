import AppKit
import Carbon
import Foundation

/// 输入法安装器：把内嵌的 aime-ime.app（Contents/Helpers）拷到 ~/Library/Input Methods
/// 并向 TIS 注册启用。设置页按钮与 `--register-ime` CLI 共用这条路径，
/// 分发版用户拖装 aime.app 后在 app 内一键完成，不再依赖 make install-ime。
enum IMEInstaller {
    static let imeBundleID = "com.zhanba.inputmethod.aime"

    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// app 包内嵌副本（make bundle 放入 Contents/Helpers）
    static var embeddedURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/aime-ime.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods/aime-ime.app")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedURL.path)
    }

    /// 已安装副本与内嵌副本不一致时提示更新（以内嵌为准；开发期版本号不动，
    /// 用可执行文件修改时间兜底判断）
    static var updateAvailable: Bool {
        guard let embedded = embeddedURL, isInstalled else { return false }
        if versionTag(of: embedded) != versionTag(of: installedURL) { return true }
        let embeddedDate = executableDate(of: embedded)
        let installedDate = executableDate(of: installedURL)
        if let embeddedDate, let installedDate {
            return embeddedDate > installedDate
        }
        return false
    }

    private static func versionTag(of appURL: URL) -> String {
        guard let info = Bundle(url: appURL)?.infoDictionary else { return "?" }
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short)-\(build)"
    }

    private static func executableDate(of appURL: URL) -> Date? {
        let exe = appURL.appendingPathComponent("Contents/MacOS/aime-ime")
        return try? FileManager.default.attributesOfItem(atPath: exe.path)[.modificationDate] as? Date
    }

    /// 安装（或覆盖更新）并注册启用。返回用户可读的结果信息。
    @discardableResult
    static func install() throws -> String {
        guard let embedded = embeddedURL else {
            throw InstallError(message: "app 包内未找到 aime-ime.app（需从打包后的 aime.app 运行）")
        }
        // 结束运行中的旧 IME；用户切回输入法时系统会自动重新拉起新副本
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: imeBundleID) {
            running.forceTerminate()
        }
        let fm = FileManager.default
        try fm.createDirectory(
            at: installedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: installedURL.path) {
            try fm.removeItem(at: installedURL)
        }
        try fm.copyItem(at: embedded, to: installedURL)
        return try register()
    }

    /// 仅注册启用（make install-ime 已拷贝时单独使用）。
    @discardableResult
    static func register() throws -> String {
        guard isInstalled else {
            throw InstallError(message: "未找到 \(installedURL.path)")
        }
        let status = TISRegisterInputSource(installedURL as CFURL)
        guard status == noErr else {
            throw InstallError(message: "TISRegisterInputSource 错误 \(status)")
        }
        let filter = [kTISPropertyBundleID as String: imeBundleID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              !list.isEmpty
        else {
            throw InstallError(message: "输入源注册后未能找到（可能需要注销重新登录后重试）")
        }
        for source in list {
            let enableStatus = TISEnableInputSource(source)
            guard enableStatus == noErr else {
                throw InstallError(message: "TISEnableInputSource 错误 \(enableStatus)")
            }
        }
        return "已安装并启用。到 系统设置 → 键盘 → 输入法 或菜单栏输入法图标里选择「Aime拼音」。"
    }
}

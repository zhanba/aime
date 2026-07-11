import Cocoa
import InputMethodKit

/// aime 拼音输入法进程入口。系统在用户选中输入法时经 launchd 拉起，
/// IMKServer 按 Info.plist 的 InputMethodServerControllerClass 实例化控制器。
enum IMEGlobals {
    static var server: IMKServer!
}

let app = NSApplication.shared
let connectionName = (Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String)
    ?? "com.zhanba.inputmethod.aime_Connection"
NSLog("aime-ime 启动，连接名=\(connectionName)")
IMEGlobals.server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
app.run()

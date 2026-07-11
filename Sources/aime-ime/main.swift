import Cocoa
import InputMethodKit

/// aime 拼音输入法进程入口。系统在用户选中输入法时经 launchd 拉起，
/// IMKServer 按 Info.plist 的 InputMethodServerControllerClass 实例化控制器。
enum IMEGlobals {
    static var server: IMKServer!
    static var candidates: IMKCandidates!
}

let app = NSApplication.shared
let connectionName = (Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String) ?? "aime_ime_connection"
IMEGlobals.server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
IMEGlobals.candidates = IMKCandidates(server: IMEGlobals.server, panelType: kIMKSingleColumnScrollingCandidatePanel)
app.run()

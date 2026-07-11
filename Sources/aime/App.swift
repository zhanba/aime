import AppKit
import SwiftUI

@main
struct AimeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var state = AppState.shared

    init() {
        DebugCLI.runIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: menuIcon)
        }

        SwiftUI.Settings {
            SettingsView()
        }
    }

    private var menuIcon: String {
        switch state.phase {
        case .recording: return "waveform.circle.fill"
        case .transcribing, .refining, .preparingModel: return "waveform.circle"
        default: return "waveform"
        }
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        Text(statusLine)

        if !state.accessibilityGranted {
            Text("⚠️ 未授予辅助功能权限，快捷键不可用")
        }
        if !state.micGranted {
            Text("⚠️ 未授予麦克风权限")
        }

        Divider()

        SettingsLink {
            Text("设置…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("退出 aime") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        let hotkeyName = Settings.current().hotkey.displayName
        switch state.phase {
        case .idle: return state.modelReady ? "按住 \(hotkeyName) 说话" : "语音模型准备中…"
        case .preparingModel: return "语音模型准备中…"
        case .recording: return "正在录音…"
        case .transcribing: return "整理转写…"
        case .refining: return "润色中…"
        case .done: return "已完成"
        case .failed(let message): return "出错：\(message)"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppState.shared.bootstrap()
    }
}

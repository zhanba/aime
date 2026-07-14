import AimeUI
import AppKit
import SwiftUI

@main
struct AimeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var voice = AppState.shared.voice

    init() {
        DebugCLI.runIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state, voice: voice)
        } label: {
            Image(systemName: menuIcon)
        }

        SwiftUI.Settings {
            SettingsView()
        }
    }

    private var menuIcon: String {
        switch voice.phase {
        case .recording: return "waveform.circle.fill"
        case .transcribing, .refining, .preparingModel: return "waveform.circle"
        default: return "waveform"
        }
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var voice: VoiceOverlayModel

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

        Button("检查更新…") {
            UpdaterController.shared.checkForUpdates()
        }

        Divider()

        Button("退出 Aime") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        let hotkeyName = Settings.current().hotkey.displayName
        switch voice.phase {
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
        _ = UpdaterController.shared // 启动 Sparkle 后台定时检查
    }
}

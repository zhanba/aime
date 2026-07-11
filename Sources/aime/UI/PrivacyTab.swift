import AimePinyin
import AppKit
import SwiftUI

/// 隐私面板：纯本地模式、按应用屏蔽矩阵、数据流向说明。
struct PrivacyTab: View {
    @AppStorage(SettingsKey.pureLocalMode) private var pureLocalMode = false
    @State private var blockedApps: [String] = Settings.current().privacyBlockedApps
    @State private var newBundleID = ""

    var body: some View {
        Form {
            Section {
                Toggle("纯本地模式（禁用一切 LLM 网络请求）", isOn: $pureLocalMode)
            } footer: {
                Text("开启后：拼音只用本地词库整句，语音只出本地识别原文，不发送任何数据到 API。")
            }

            Section("屏蔽应用（在这些应用里不读上下文、不调用 LLM）") {
                HStack {
                    TextField("Bundle ID，如 com.apple.keychainaccess", text: $newBundleID)
                        .textFieldStyle(.roundedBorder)
                    Button("添加当前前台应用") { addFrontmost() }
                    Button("添加") { add(newBundleID) }
                        .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(blockedApps, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID)
                        Spacer()
                        Button(role: .destructive) { remove(bundleID) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section("数据流向") {
                Text("""
                始终在本地：语音识别（Qwen3-ASR/系统）、拼音切分与纠错、词库整句、用户词库。
                仅在配置了 API 且非纯本地模式时发送到你自己配置的 endpoint：\
                语音转写文本、拼音切分分析、光标前文本（可关）、用户常用词列表。
                永不发送：音频原始数据、密码框内容（系统级保护）、屏蔽应用内的任何内容。
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addFrontmost() {
        // 设置窗自己在前台，取除自己外最近的常规应用
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
        if let frontmost = apps.first(where: { $0.isActive }) ?? apps.first,
           let bundleID = frontmost.bundleIdentifier {
            add(bundleID)
        }
    }

    private func add(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !blockedApps.contains(trimmed) else { return }
        blockedApps.append(trimmed)
        newBundleID = ""
        persist()
    }

    private func remove(_ bundleID: String) {
        blockedApps.removeAll { $0 == bundleID }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(blockedApps, forKey: SettingsKey.privacyBlockedApps)
    }
}

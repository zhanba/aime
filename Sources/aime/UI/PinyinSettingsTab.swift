import AimePinyin
import SwiftUI

/// 拼音输入法设置：词库更新、模糊音矩阵。安装/更新提示仅在需要时出现。
struct PinyinSettingsTab: View {
    @State private var enabledRules: Set<String> = Settings.current().fuzzyRuleIDs
    @ObservedObject private var lexicon = LexiconInstaller.shared
    @State private var imeInstalled = IMEInstaller.isInstalled
    @State private var installMessage: String?
    @State private var installFailed = false

    var body: some View {
        Form {
            if !imeInstalled || installMessage != nil {
                Section {
                    imeInstallRow
                }
            }

            Section {
                lexiconRow
            } header: {
                Text("词库")
            } footer: {
                Text("来自开源词库白霜拼音，缺失时自动下载（约 12MB）。")
            }

            Section("模糊音") {
                let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(FuzzyRule.all) { rule in
                        Toggle(rule.displayName, isOn: Binding(
                            get: { enabledRules.contains(rule.id) },
                            set: { enabled in
                                if enabled {
                                    enabledRules.insert(rule.id)
                                } else {
                                    enabledRules.remove(rule.id)
                                }
                                UserDefaults.standard.set(Array(enabledRules), forKey: SettingsKey.fuzzyRules)
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }

            DictionarySections()
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var imeInstallRow: some View {
        HStack(alignment: .firstTextBaseline) {
            if let installMessage {
                Label(installMessage, systemImage: installFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(installFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            } else {
                Label("输入法尚未安装", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !imeInstalled {
                Button("安装输入法") { installIME() }
            }
        }
    }

    private func installIME() {
        do {
            installMessage = try IMEInstaller.install()
            installFailed = false
        } catch {
            installMessage = error.localizedDescription
            installFailed = true
        }
        imeInstalled = IMEInstaller.isInstalled
    }

    @ViewBuilder
    private var lexiconRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(lexicon.installedInfo ?? "未安装，将在下次启动时自动下载")
                statusLine
            }
            Spacer()
            switch lexicon.phase {
            case .downloading, .compiling:
                ProgressView().controlSize(.small)
            case .failed:
                Button("重试") { lexicon.install() }
            case .idle:
                if lexicon.installedInfo != nil {
                    Button("检查更新") { lexicon.install() }
                }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch lexicon.phase {
        case .idle:
            EmptyView()
        case .downloading(let text):
            Text(text).font(.caption).foregroundStyle(.secondary)
        case .compiling:
            Text("编译词库…").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }
}

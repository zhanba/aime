import AimePinyin
import SwiftUI

/// 拼音输入法设置：词库更新、模糊音矩阵。安装提示仅在未安装时出现。
struct PinyinSettingsTab: View {
    @State private var enabledRules: Set<String> = Settings.current().fuzzyRuleIDs
    @ObservedObject private var lexicon = LexiconInstaller.shared

    private static let imeInstallPath = NSString(
        string: "~/Library/Input Methods/aime-ime.app"
    ).expandingTildeInPath

    private var imeInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.imeInstallPath)
    }

    var body: some View {
        Form {
            if !imeInstalled {
                Section {
                    Label("输入法尚未安装：终端执行 make install-ime", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                lexiconRow
            } header: {
                Text("词库")
            } footer: {
                Text("本地整句与词候选的数据来源（开源项目白霜拼音 rime-frost），缺失时启动自动下载，约 12MB。")
            }

            Section("模糊音（按你的口音习惯勾选）") {
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
        }
        .formStyle(.grouped)
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

import AimePinyin
import SwiftUI

/// 拼音输入法设置：词库更新、模糊音矩阵。安装/更新提示仅在需要时出现。
struct PinyinSettingsTab: View {
    @State private var enabledRules: Set<String> = Settings.current().fuzzyRuleIDs
    @ObservedObject private var lexicon = LexiconInstaller.shared
    @ObservedObject private var gram = GramInstaller.shared
    @ObservedObject private var localLLM = LocalLLMInstaller.shared
    @State private var imeInstalled = IMEInstaller.isInstalled
    @State private var chinesePunctuation = SharedConfig.chinesePunctuation
    @State private var localLLMEnabled = SharedConfig.localLLMEnabled
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

            Section {
                gramRow
            } header: {
                Text("语法模型")
            } footer: {
                Text("词语搭配知识，大幅提升整句准确率。数据来自万象拼音 LMDG（CC-BY-4.0）。")
            }

            Section {
                localLLMRow
                Toggle("用本地模型整句转换", isOn: $localLLMEnabled)
                    .onChange(of: localLLMEnabled) { _, enabled in
                        SharedConfig.mirrorLocalLLMEnabled(enabled)
                        if enabled, localLLM.installedInfo == nil {
                            localLLM.install()
                        }
                    }
            } header: {
                Text("本地整句模型")
            } footer: {
                Text("Qwen3-0.6B 在本地做整句转换（约 320MB，Apache 2.0），无需联网与 API Key，比云端快约 4 倍；失败自动回退云端。")
            }

            Section("输入") {
                Toggle("中文标点", isOn: $chinesePunctuation)
                    .onChange(of: chinesePunctuation) { _, enabled in
                        SharedConfig.mirrorChinesePunctuation(enabled)
                    }
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
    private var gramRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(gram.installedInfo ?? "未安装，将在下次启动时自动下载")
                switch gram.phase {
                case .idle:
                    EmptyView()
                case .downloading(let text):
                    Text(text).font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            switch gram.phase {
            case .downloading:
                ProgressView().controlSize(.small)
            case .failed:
                Button("重试") { gram.install() }
            case .idle:
                if gram.installedInfo != nil {
                    Button("检查更新") { gram.install() }
                }
            }
        }
    }

    @ViewBuilder
    private var localLLMRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(localLLM.installedInfo ?? "模型未下载")
                switch localLLM.phase {
                case .idle:
                    EmptyView()
                case .downloading(let text):
                    Text(text).font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            switch localLLM.phase {
            case .downloading:
                ProgressView().controlSize(.small)
            case .failed:
                Button("重试") { localLLM.install() }
            case .idle:
                if localLLM.installedInfo == nil {
                    Button("下载模型") { localLLM.install() }
                } else {
                    Button("删除") { localLLM.delete() }
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

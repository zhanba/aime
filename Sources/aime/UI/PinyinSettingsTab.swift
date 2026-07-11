import AimePinyin
import SwiftUI

/// 拼音输入法设置：模糊音矩阵、安装引导、Playground 调试区。
struct PinyinSettingsTab: View {
    @State private var enabledRules: Set<String> = Settings.current().fuzzyRuleIDs
    @State private var playgroundInput = ""
    @State private var segmentationText = ""
    @State private var conversionText = ""
    @State private var converting = false
    @StateObject private var lexicon = LexiconInstaller()

    var body: some View {
        Form {
            Section {
                LabeledContent("安装") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("终端执行 make install-ime，然后在这里启用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("打开输入法设置") {
                            let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } footer: {
                Text("整句转换用「精修」页配置的同一个 LLM API。空格上屏首选，回车上屏原始拼音，数字选候选，←→ 选、↑↓ 翻页，Esc 取消。")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lexicon.installedInfo ?? "未安装（词候选与本地整句不可用，仅 LLM 模式）")
                        statusLine
                    }
                    Spacer()
                    switch lexicon.phase {
                    case .downloading, .compiling:
                        ProgressView().controlSize(.small)
                    default:
                        Button(lexicon.installedInfo == nil ? "下载词库" : "更新词库") {
                            lexicon.install()
                        }
                        if lexicon.installedInfo != nil {
                            Button("删除", role: .destructive) { lexicon.delete() }
                        }
                    }
                }
            } header: {
                Text("词库（白霜拼音）")
            } footer: {
                Text("约 12MB，来自开源项目 rime-frost（GPL-3.0，人工校对注音 + 现代语料词频）。下载编译后本地整句与词候选即时可用；输入法切换时自动加载新词库。")
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

            Section("Playground") {
                HStack {
                    TextField("输入拼音试试，如 nihsoshijie 或 zheshiyigeAPIjiekou", text: $playgroundInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { runPlayground() }
                    Button(converting ? "转换中…" : "转换") { runPlayground() }
                        .disabled(playgroundInput.isEmpty || converting)
                }
                if !segmentationText.isEmpty {
                    Text("切分：\(segmentationText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !conversionText.isEmpty {
                    Text(conversionText)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
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

    private func runPlayground() {
        let raw = playgroundInput.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        let result = PinyinEngine.shared.analyze(raw, fuzzyRuleIDs: enabledRules)
        let segments = result.segments
        segmentationText = PinyinPromptBuilder.describe(segments: segments)
        conversionText = ""
        if let local = result.localSentence {
            let words = result.wordCandidates.prefix(6).map(\.word).joined(separator: "/")
            conversionText = "本地：\(local)\(words.isEmpty ? "" : "  词候选：\(words)")"
        } else {
            conversionText = "（词库未安装：终端执行 swift run -c release aime-pinyin --build-lexicon <白霜 cn_dicts 目录>）"
        }
        let config = SharedConfig.loadLLMConfig()
        guard !config.apiKey.isEmpty else { return }
        converting = true
        Task {
            do {
                let began = Date()
                let result = try await PinyinConverter().convert(
                    raw: raw, segments: segments, context: nil,
                    userDictEntries: UserDictionary.shared.topEntries(), config: config
                )
                var text = conversionText.isEmpty ? "" : conversionText + "\n"
                text += "首选：\(result.best)"
                if let alternative = result.alternative {
                    text += "\n备选：\(alternative)"
                }
                text += String(format: "  （%.2fs）", Date().timeIntervalSince(began))
                conversionText = text
            } catch {
                conversionText = "转换失败：\(error.localizedDescription)"
            }
            converting = false
        }
    }
}

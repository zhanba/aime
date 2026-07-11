import AimePinyin
import SwiftUI

/// 拼音输入法设置：模糊音矩阵、安装引导、Playground 调试区。
struct PinyinSettingsTab: View {
    @State private var enabledRules: Set<String> = Settings.current().fuzzyRuleIDs
    @State private var playgroundInput = ""
    @State private var segmentationText = ""
    @State private var conversionText = ""
    @State private var converting = false

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
                Text("整句转换用「精修」页配置的同一个 LLM API。空格上屏首选，回车上屏原始拼音，数字选候选，Esc 取消。双拼方案 M3.5 提供。")
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

    private func runPlayground() {
        let raw = playgroundInput.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        let segments = PinyinSegmenter.segment(raw, enabledFuzzyRuleIDs: enabledRules)
        segmentationText = PinyinPromptBuilder.describe(segments: segments)
        conversionText = ""
        let config = SharedConfig.loadLLMConfig()
        guard !config.apiKey.isEmpty else {
            conversionText = "（未配置 API key，仅显示切分）"
            return
        }
        converting = true
        Task {
            do {
                let began = Date()
                let result = try await PinyinConverter().convert(
                    raw: raw, segments: segments, context: nil,
                    userDictEntries: UserDictionary.shared.topEntries(), config: config
                )
                var text = "首选：\(result.best)"
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

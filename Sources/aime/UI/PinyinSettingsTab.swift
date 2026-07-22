import AimePinyin
import SwiftUI

/// 拼音输入法设置。页面保持短：安装/更新提示仅在需要时出现，
/// 词库/语法/模型合并为一个「数据与模型」组，模糊音默认收起。
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
    @State private var fuzzyExpanded = false

    var body: some View {
        Form {
            if !imeInstalled || installMessage != nil {
                Section {
                    imeInstallRow
                }
            }

            Section("输入") {
                Toggle("中文标点", isOn: $chinesePunctuation)
                    .onChange(of: chinesePunctuation) { _, enabled in
                        SharedConfig.mirrorChinesePunctuation(enabled)
                    }
                fuzzyGroup
            }

            Section {
                dataRow("词库", info: lexicon.installedInfo, caption: lexiconCaption) {
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
                dataRow("语法模型", info: gram.installedInfo, caption: gramCaption) {
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
                localLLMRow
            } header: {
                Text("数据与模型")
            } footer: {
                Text("缺失时自动下载。词库：白霜拼音；语法：万象 LMDG；模型：Qwen3-1.7B。")
            }

            DictionarySections()
        }
        .formStyle(.grouped)
    }

    // MARK: - 模糊音（默认收起，标签带已开数量）

    private var fuzzyGroup: some View {
        DisclosureGroup(isExpanded: $fuzzyExpanded) {
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
        } label: {
            HStack {
                Text("模糊音")
                Spacer()
                Text(enabledRules.isEmpty ? "未开启" : "已开 \(enabledRules.count) 组")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 数据与模型

    /// 统一的资源行：标题 + 状态同行，进度/错误缩为 caption，操作靠右
    private func dataRow(
        _ title: String,
        info: String?,
        caption: (text: String, isError: Bool)?,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                    Text(info ?? "未安装，将自动下载")
                        .foregroundStyle(.secondary)
                }
                if let caption {
                    Text(caption.text)
                        .font(.caption)
                        .foregroundStyle(caption.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
            Spacer()
            trailing()
        }
    }

    private var lexiconCaption: (text: String, isError: Bool)? {
        switch lexicon.phase {
        case .idle: return nil
        case .downloading(let text): return (text, false)
        case .compiling: return ("编译词库…", false)
        case .failed(let message): return (message, true)
        }
    }

    private var gramCaption: (text: String, isError: Bool)? {
        switch gram.phase {
        case .idle: return nil
        case .downloading(let text): return (text, false)
        case .failed(let message): return (message, true)
        }
    }

    private var localLLMCaption: (text: String, isError: Bool)? {
        switch localLLM.phase {
        case .idle:
            return localLLM.installedInfo == nil ? ("开启后自动下载（约 950MB）", false) : nil
        case .downloading(let text): return (text, false)
        case .failed(let message): return (message, true)
        }
    }

    /// 开关与模型状态合一行：开启即触发下载，装好后开关旁提供删除
    private var localLLMRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("本地整句转换")
                    if let info = localLLM.installedInfo {
                        Text(info).foregroundStyle(.secondary)
                    }
                }
                if let caption = localLLMCaption {
                    Text(caption.text)
                        .font(.caption)
                        .foregroundStyle(caption.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
            Spacer()
            switch localLLM.phase {
            case .downloading:
                ProgressView().controlSize(.small)
            case .failed:
                Button("重试") { localLLM.install() }
            case .idle:
                if localLLM.installedInfo != nil {
                    Button("删除") { localLLM.delete() }
                }
            }
            Toggle("本地整句转换", isOn: $localLLMEnabled)
                .labelsHidden()
                .onChange(of: localLLMEnabled) { _, enabled in
                    SharedConfig.mirrorLocalLLMEnabled(enabled)
                    if enabled, localLLM.installedInfo == nil {
                        localLLM.install()
                    }
                }
        }
    }

    // MARK: - 输入法安装

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
}

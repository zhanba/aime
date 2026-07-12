import AimePinyin
import SwiftUI

/// "教它"页：用户词库管理。词条来自拼音/语音上屏学习，双向增强两个模态。
struct DictionaryTab: View {
    @State private var entries: [UserDictionary.Entry] = []
    @State private var newWord = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("手动添加词（专有名词、项目名…）", text: $newWord)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addWord() }
                    Button("添加") { addWord() }
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("词库由上屏内容自动学习（拼音/语音双向共享：拼音教过的词，语音识别也认识）。评分随时间衰减，旧习惯自然淡出。")
            }

            Section("已学到 \(entries.count) 个词") {
                if entries.isEmpty {
                    Text("还没有词条——用 Aime拼音 打字或语音输入后会自动积累")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                entryRow(entry)
                                    .padding(.vertical, 4)
                                if entry.id != entries.last?.id {
                                    Divider()
                                }
                            }
                        }
                        // 给悬浮滚动条让位，避免盖住行尾的删除按钮
                        .padding(.trailing, 16)
                    }
                    .frame(height: 280)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { reload() }
    }

    private func entryRow(_ entry: UserDictionary.Entry) -> some View {
        HStack {
            Text(entry.text)
            Text(entry.source == "voice" ? "🎤" : entry.source == "manual" ? "✍️" : "⌨️")
                .font(.caption)
            Spacer()
            Text("×\(entry.count) · \(entry.lastUsed.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(role: .destructive) {
                UserDictionary.shared.remove(entry.text)
                reload()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func reload() {
        UserDictionary.shared.reload()
        entries = UserDictionary.shared.allEntries
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        UserDictionary.shared.record(word, source: "manual")
        newWord = ""
        reload()
    }
}

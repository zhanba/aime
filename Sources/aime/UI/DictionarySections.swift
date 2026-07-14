import AimePinyin
import SwiftUI

/// 用户词库管理（拼音页内嵌 Sections）。词条来自拼音/语音上屏学习，双向增强两个模态。
struct DictionarySections: View {
    @State private var entries: [UserDictionary.Entry] = []
    @State private var newWord = ""

    var body: some View {
        Section {
            HStack {
                TextField("手动添加词（专有名词、项目名…）", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addWord() }
                Button("添加") { addWord() }
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("词典 · 已学到 \(entries.count) 个词")
        } footer: {
            Text("由上屏内容自动学习，拼音与语音共享，久不用的词自动淡出。")
        }
        .onAppear { reload() }

        if !entries.isEmpty {
            Section {
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
                .frame(height: 200)
            }
        }
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

import AimePinyin
import Cocoa
import InputMethodKit

/// 组合逻辑：小写字母进 buffer → 180ms 防抖 LLM 整句转换 → 组合区预览 → 空格上屏。
///
/// 键位约定：空格=上屏首选；回车=上屏原始拼音；Esc=取消；数字=选候选；
/// 中文标点直出；大写字母/数字进 buffer 原样透传（中英混输）。
@objc(AimeInputController)
class AimeInputController: IMKInputController {
    private var buffer = ""
    private var conversion: PinyinConversion?
    /// conversion 对应的 buffer 快照（不匹配则预览过期）
    private var convertedFor = ""
    private var pendingCommit = false
    private var debounceTask: Task<Void, Never>?
    private var currentCandidates: [String] = []
    /// 方向键高亮的候选序号（自行跟踪，Enter 按它提交，不依赖面板回调）
    private var selectedCandidateIndex = 0
    private var candidatesNavigated = false

    private static let punctuationMap: [String: String] = [
        ",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；",
        "\\": "、", "(": "（", ")": "）",
    ]

    // MARK: - IMK 生命周期

    override func activateServer(_ sender: Any!) {
        NSLog("aime-ime activateServer client=%@", String(describing: type(of: sender ?? "nil")))
        clearComposition()
    }

    override func deactivateServer(_ sender: Any!) {
        // 切走输入法：未完成的组合以原始拼音上屏，不丢用户输入
        if !buffer.isEmpty {
            commit(buffer)
        }
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    // MARK: - 按键处理

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            if !buffer.isEmpty { commit(buffer) }
            return false
        }

        let characters = event.characters ?? ""

        // 空 buffer：字母开启组合，中文标点直出，其余放行
        if buffer.isEmpty {
            if characters.count == 1, characters.first!.isLowercaseLatin {
                buffer = characters
                afterBufferChange()
                return true
            }
            if let mapped = Self.punctuationMap[characters] {
                client()?.insertText(mapped, replacementRange: Self.replacementRange)
                return true
            }
            return false
        }

        // 组合中
        switch event.keyCode {
        case 53: // Esc：取消
            clearComposition()
            return true
        case 51: // Backspace
            buffer = String(buffer.dropLast())
            afterBufferChange()
            return true
        case 36: // Enter：方向键选过候选则提交高亮项，否则上屏原始拼音
            if candidatesNavigated, selectedCandidateIndex < currentCandidates.count {
                commit(currentCandidates[selectedCandidateIndex])
            } else {
                commit(buffer)
            }
            return true
        case 49: // Space：方向键选过候选则提交高亮项，否则上屏首选
            if candidatesNavigated, selectedCandidateIndex < currentCandidates.count {
                commit(currentCandidates[selectedCandidateIndex])
            } else {
                commitBestOrWait()
            }
            return true
        case 125, 126: // ↓/↑：候选高亮移动（转发给面板同步视觉，自己记序号）
            guard isCandidatesVisible, !currentCandidates.isEmpty else { return true }
            if event.keyCode == 125 {
                selectedCandidateIndex = min(selectedCandidateIndex + 1, currentCandidates.count - 1)
            } else {
                selectedCandidateIndex = max(selectedCandidateIndex - 1, 0)
            }
            candidatesNavigated = true
            IMEGlobals.candidates?.interpretKeyEvents([event])
            return true
        case 48: // Tab：暂不做段间跳转（M4），吞掉避免焦点跳走
            return true
        default:
            break
        }

        if characters.count == 1, let char = characters.first {
            // 数字优先选候选（候选面板可见时）；否则作为混输进 buffer
            if let digit = char.wholeNumberValue, (1 ... 9).contains(digit),
               isCandidatesVisible, digit <= currentCandidates.count {
                commit(currentCandidates[digit - 1])
                return true
            }
            if char.isLowercaseLatin || char.isUppercaseLatin || char.isNumber || char == "'" {
                buffer.append(char)
                afterBufferChange()
                return true
            }
            if let mapped = Self.punctuationMap[characters] {
                // 标点结束整句：先上屏当前最优，再补标点
                let text = freshConversion()?.best ?? buffer
                commit(text + mapped)
                return true
            }
        }
        // 其他键：上屏原文后放行
        commit(buffer)
        return false
    }

    // MARK: - 组合状态

    private func afterBufferChange() {
        pendingCommit = false
        // buffer 变了 → 候选已过期，收起面板等新转换
        currentCandidates = []
        selectedCandidateIndex = 0
        candidatesNavigated = false
        IMEGlobals.candidates?.hide()
        if buffer.isEmpty {
            clearComposition()
            return
        }
        updateMarkedText()
        scheduleConversion()
    }

    private func freshConversion() -> PinyinConversion? {
        convertedFor == buffer ? conversion : nil
    }

    private func clearComposition() {
        buffer = ""
        conversion = nil
        convertedFor = ""
        pendingCommit = false
        debounceTask?.cancel()
        currentCandidates = []
        selectedCandidateIndex = 0
        candidatesNavigated = false
        IMEGlobals.candidates?.hide()
        client()?.setMarkedText(
            "", selectionRange: NSRange(location: 0, length: 0), replacementRange: Self.replacementRange
        )
    }

    private func commit(_ text: String) {
        guard !text.isEmpty else {
            clearComposition()
            return
        }
        client()?.insertText(text, replacementRange: Self.replacementRange)
        recordToUserDictionary(text)
        clearComposition()
    }

    /// 空格：预览就绪直接上屏；还在转换 → 标记待上屏，转换回来自动提交
    private func commitBestOrWait() {
        if let fresh = freshConversion() {
            commit(fresh.best)
        } else {
            pendingCommit = true
            updateMarkedText()
        }
    }

    // MARK: - 组合区渲染

    private static let replacementRange = NSRange(location: NSNotFound, length: 0)

    /// 预览就绪：显示转换结果（实线下划线）；未就绪：显示原始拼音（虚线感的细下划线）
    private func updateMarkedText() {
        guard let client = client() else { return }
        let text: String
        let underline: NSUnderlineStyle
        if let fresh = freshConversion() {
            text = fresh.best
            underline = .single
        } else {
            text = buffer + (pendingCommit ? "…" : "")
            underline = .patternDot
        }
        let attributed = NSAttributedString(string: text, attributes: [
            .underlineStyle: underline.union(.single).rawValue,
            .markedClauseSegment: 0,
        ])
        client.setMarkedText(
            attributed,
            selectionRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: Self.replacementRange
        )
    }

    // MARK: - LLM 转换（180ms 防抖）

    private func scheduleConversion() {
        let snapshot = buffer
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            await self?.convertNow(snapshot)
        }
    }

    @MainActor
    private func convertNow(_ snapshot: String) async {
        guard snapshot == buffer, !snapshot.isEmpty else { return }
        let config = SharedConfig.loadLLMConfig()
        do {
            let result = try await PinyinConverter().convert(
                raw: snapshot,
                context: contextBeforeCursor(),
                userDictEntries: UserDictionary.shared.topEntries(),
                config: config
            )
            guard snapshot == buffer else { return }
            conversion = result
            convertedFor = snapshot
            if pendingCommit {
                commit(result.best)
                return
            }
            updateMarkedText()
            refreshCandidates()
        } catch {
            guard snapshot == buffer else { return }
            if pendingCommit {
                // 转换失败不阻塞输入：上屏原始拼音
                commit(snapshot)
            }
        }
    }

    // MARK: - 候选窗

    private var isCandidatesVisible: Bool {
        IMEGlobals.candidates?.isVisible() ?? false
    }

    private func refreshCandidates() {
        var list: [String] = []
        if let fresh = freshConversion() {
            list.append(fresh.best)
            if let alternative = fresh.alternative {
                list.append(alternative)
            }
        }
        list.append(buffer)
        currentCandidates = list
        selectedCandidateIndex = 0
        candidatesNavigated = false
        IMEGlobals.candidates?.update()
        IMEGlobals.candidates?.show()
    }

    override func candidates(_ sender: Any!) -> [Any]! {
        currentCandidates
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        commit(candidateString.string)
    }

    // MARK: - 上下文与词库

    /// 直接从宿主应用取光标前文本（IMKTextInput 能力，无需辅助功能权限）
    private func contextBeforeCursor() -> String? {
        guard let client = client() else { return nil }
        let selection = client.selectedRange()
        guard selection.location != NSNotFound, selection.location > 0 else { return nil }
        let start = max(0, selection.location - 120)
        let range = NSRange(location: start, length: selection.location - start)
        return client.attributedSubstring(from: range)?.string
    }

    /// 上屏文本里的英文术语与短句进词库（L2 双向词库的拼音侧入口）
    private func recordToUserDictionary(_ text: String) {
        guard text != buffer else { return } // 原始拼音上屏不学习
        var englishRun = ""
        for char in text {
            if char.isUppercaseLatin || char.isLowercaseLatin {
                englishRun.append(char)
            } else {
                if englishRun.count >= 2 { UserDictionary.shared.record(englishRun, source: "pinyin") }
                englishRun = ""
            }
        }
        if englishRun.count >= 2 { UserDictionary.shared.record(englishRun, source: "pinyin") }
        if (2 ... 8).contains(text.count) {
            UserDictionary.shared.record(text, source: "pinyin")
        }
    }
}

private extension Character {
    var isLowercaseLatin: Bool { isASCII && isLowercase && isLetter }
    var isUppercaseLatin: Bool { isASCII && isUppercase && isLetter }
}

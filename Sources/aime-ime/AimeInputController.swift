import AimePinyin
import Cocoa
import InputMethodKit

/// 候选（逻辑层）。
private struct Candidate {
    enum Kind {
        case llmBest, llmAlternative, localSentence, word, raw
    }

    var text: String
    var kind: Kind
    /// word 类：消耗的音节数；其余类消耗全部
    var syllableCount: Int?

    var tag: String {
        switch kind {
        case .llmBest: return "AI"
        case .llmAlternative: return "备"
        case .localSentence: return "句"
        case .word: return ""
        case .raw: return "原"
        }
    }
}

/// M3.5 组合逻辑：
/// 按键 → 本地引擎（切分+词库+造句，即时）→ 候选条 + 预览；
/// 180ms 防抖 LLM 整句 → 回验通过则接管首位；
/// 选词候选 = 部分确认（逐段上屏模型），空格上屏当前预览，永不等待网络。
@objc(AimeInputController)
class AimeInputController: IMKInputController {
    // 组合状态：已确认前缀（栈，可回退）+ 活动 buffer
    private var confirmedStack: [(text: String, keys: String)] = []
    private var rawBuffer = ""

    private var engineResult: PinyinEngine.Result?
    private var llmConversion: PinyinConversion?
    private var llmVerdict: PinyinVerifier.Verdict = .pass
    private var convertedFor = ""
    private var debounceTask: Task<Void, Never>?

    private var candidates: [Candidate] = []
    private var highlighted = 0
    private var page = 0
    private static let pageSize = 6

    private static let bar = CandidateBarController()

    private var confirmedText: String {
        confirmedStack.map(\.text).joined()
    }

    private static let punctuationMap: [String: String] = [
        ",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；",
        "\\": "、", "(": "（", ")": "）",
    ]

    // MARK: - IMK 生命周期

    override func activateServer(_ sender: Any!) {
        PinyinEngine.shared.reloadIfChanged() // app 侧可能刚装/删了词库
        resetAll()
    }

    override func deactivateServer(_ sender: Any!) {
        // 切走输入法：已确认部分 + 原始拼音上屏，不丢输入
        if !confirmedText.isEmpty || !rawBuffer.isEmpty {
            commitFinal(confirmedText + rawBuffer)
        }
        Self.bar.hide()
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    // MARK: - 按键处理

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            if isComposing { commitFinal(confirmedText + rawBuffer) }
            return false
        }
        let characters = event.characters ?? ""

        if !isComposing {
            if characters.count == 1, characters.first!.isLowercaseLatin {
                rawBuffer = characters
                refresh()
                return true
            }
            if let mapped = Self.punctuationMap[characters] {
                client()?.insertText(mapped, replacementRange: Self.replacementRange)
                return true
            }
            return false
        }

        switch event.keyCode {
        case 53: // Esc：整体取消（含已确认段）
            resetAll()
            return true
        case 51: // Backspace：先退活动 buffer，空了回退上一次确认
            if !rawBuffer.isEmpty {
                rawBuffer = String(rawBuffer.dropLast())
                if rawBuffer.isEmpty, confirmedStack.isEmpty {
                    resetAll()
                } else {
                    refresh()
                }
            } else if let last = confirmedStack.popLast() {
                rawBuffer = last.keys
                refresh()
            }
            return true
        case 36: // Enter：已确认 + 原始拼音
            commitFinal(confirmedText + rawBuffer)
            return true
        case 49: // Space：提交高亮候选（默认高亮第一个 = 当前最优）
            selectCandidate(at: page * Self.pageSize + highlighted)
            return true
        case 123: // ← 高亮左移
            moveHighlight(-1)
            return true
        case 124: // → 高亮右移
            moveHighlight(1)
            return true
        case 125: // ↓ 下一页
            turnPage(1)
            return true
        case 126: // ↑ 上一页
            turnPage(-1)
            return true
        case 48: // Tab：下一页（习惯兼容）
            turnPage(1)
            return true
        default:
            break
        }

        if characters.count == 1, let char = characters.first {
            if let digit = char.wholeNumberValue, (1 ... 9).contains(digit), !candidates.isEmpty {
                selectCandidate(at: page * Self.pageSize + digit - 1)
                return true
            }
            if char.isLowercaseLatin || char.isUppercaseLatin || char == "'" {
                rawBuffer.append(char)
                refresh()
                return true
            }
            if char.isNumber {
                rawBuffer.append(char)
                refresh()
                return true
            }
            if let mapped = Self.punctuationMap[characters] {
                commitFinal(confirmedText + currentPreview + mapped)
                return true
            }
        }
        commitFinal(confirmedText + rawBuffer)
        return false
    }

    // MARK: - 状态

    private var isComposing: Bool {
        !rawBuffer.isEmpty || !confirmedStack.isEmpty
    }

    private var llmFresh: Bool {
        llmConversion != nil && convertedFor == rawBuffer
    }

    /// 当前预览 = LLM（过回验）> 本地整句 > 原始拼音
    private var currentPreview: String {
        if llmFresh, llmVerdict != .reject, let best = llmConversion?.best {
            return best
        }
        return engineResult?.localSentence ?? rawBuffer
    }

    private func resetAll() {
        confirmedStack = []
        rawBuffer = ""
        engineResult = nil
        llmConversion = nil
        convertedFor = ""
        debounceTask?.cancel()
        candidates = []
        highlighted = 0
        page = 0
        Self.bar.hide()
        client()?.setMarkedText(
            "", selectionRange: NSRange(location: 0, length: 0), replacementRange: Self.replacementRange
        )
    }

    private func commitFinal(_ text: String) {
        if !text.isEmpty {
            client()?.insertText(text, replacementRange: Self.replacementRange)
            learn(text)
        }
        resetAll()
    }

    // MARK: - 刷新（每次按键，同步毫秒级）

    private func refresh() {
        guard !rawBuffer.isEmpty else {
            // 活动 buffer 空但有确认段：只显示确认段
            updateMarkedText()
            rebuildCandidates()
            return
        }
        let config = SharedConfig.loadLLMConfig()
        engineResult = PinyinEngine.shared.analyze(rawBuffer, fuzzyRuleIDs: config.enabledFuzzyRuleIDs)
        if convertedFor != rawBuffer {
            llmConversion = nil
        }
        rebuildCandidates()
        updateMarkedText()
        scheduleConversion()
    }

    private func rebuildCandidates() {
        var list: [Candidate] = []
        if llmFresh, let conversion = llmConversion {
            switch llmVerdict {
            case .pass:
                list.append(Candidate(text: conversion.best, kind: .llmBest, syllableCount: nil))
                if let alternative = conversion.alternative,
                   PinyinVerifier.verify(candidate: alternative, segments: engineResult?.segments ?? []) == .pass {
                    list.append(Candidate(text: alternative, kind: .llmAlternative, syllableCount: nil))
                }
            case .demote, .reject:
                break // demote 的稍后插在词候选后；reject 不进候选
            }
        }
        if let local = engineResult?.localSentence, !list.contains(where: { $0.text == local }) {
            list.append(Candidate(text: local, kind: .localSentence, syllableCount: nil))
        }
        for word in engineResult?.wordCandidates.prefix(16) ?? [] where !list.contains(where: { $0.text == word.word }) {
            list.append(Candidate(text: word.word, kind: .word, syllableCount: word.syllableCount))
        }
        if llmFresh, llmVerdict == .demote, let best = llmConversion?.best {
            list.append(Candidate(text: best, kind: .llmBest, syllableCount: nil))
        }
        if !rawBuffer.isEmpty {
            list.append(Candidate(text: rawBuffer, kind: .raw, syllableCount: nil))
        }
        candidates = list
        highlighted = 0
        page = 0
        showBar()
    }

    // MARK: - 候选条

    private func showBar() {
        guard isComposing, !candidates.isEmpty else {
            Self.bar.hide()
            return
        }
        let start = page * Self.pageSize
        let slice = Array(candidates[start ..< min(start + Self.pageSize, candidates.count)])
        let items = slice.enumerated().map { index, candidate in
            CandidateDisplayItem(id: start + index, text: candidate.text, tag: candidate.tag)
        }
        let pageCount = (candidates.count + Self.pageSize - 1) / Self.pageSize
        Self.bar.show(
            items: items,
            highlighted: highlighted,
            pageInfo: pageCount > 1 ? "\(page + 1)/\(pageCount)" : "",
            near: caretRect()
        )
    }

    private func caretRect() -> NSRect {
        var rect = NSRect.zero
        _ = client()?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect
    }

    private func moveHighlight(_ delta: Int) {
        let start = page * Self.pageSize
        let pageItemCount = min(Self.pageSize, candidates.count - start)
        guard pageItemCount > 0 else { return }
        highlighted = (highlighted + delta + pageItemCount) % pageItemCount
        showBar()
    }

    private func turnPage(_ delta: Int) {
        let pageCount = (candidates.count + Self.pageSize - 1) / Self.pageSize
        guard pageCount > 1 else { return }
        page = (page + delta + pageCount) % pageCount
        highlighted = 0
        showBar()
    }

    private func selectCandidate(at index: Int) {
        guard index >= 0, index < candidates.count else { return }
        let candidate = candidates[index]
        switch candidate.kind {
        case .llmBest, .llmAlternative, .localSentence, .raw:
            commitFinal(confirmedText + candidate.text)
        case .word:
            partialConfirm(candidate)
        }
    }

    /// 逐段确认：提交词、消耗按键、剩余重新转换
    private func partialConfirm(_ candidate: Candidate) {
        guard let syllableCount = candidate.syllableCount,
              let segments = engineResult?.segments else { return }
        let keyLength = PinyinEngine.consumedKeyLength(
            raw: rawBuffer, segments: segments, syllableCount: syllableCount
        )
        guard keyLength > 0 else { return }
        let consumedKeys = String(rawBuffer.prefix(keyLength))
        confirmedStack.append((text: candidate.text, keys: consumedKeys))
        rawBuffer = String(rawBuffer.dropFirst(keyLength))
        if rawBuffer.isEmpty {
            commitFinal(confirmedText)
        } else {
            llmConversion = nil
            convertedFor = ""
            refresh()
        }
    }

    // MARK: - 组合区渲染

    private static let replacementRange = NSRange(location: NSNotFound, length: 0)

    /// 已确认段：粗下划线；预览段：LLM 过验=实线，本地/原文=点线
    private func updateMarkedText() {
        guard let client = client() else { return }
        let attributed = NSMutableAttributedString()
        if !confirmedText.isEmpty {
            attributed.append(NSAttributedString(string: confirmedText, attributes: [
                .underlineStyle: NSUnderlineStyle.thick.rawValue,
                .markedClauseSegment: 0,
            ]))
        }
        if !rawBuffer.isEmpty {
            let preview = currentPreview
            let solid = llmFresh && llmVerdict == .pass
            attributed.append(NSAttributedString(string: preview, attributes: [
                .underlineStyle: solid
                    ? NSUnderlineStyle.single.rawValue
                    : NSUnderlineStyle.patternDot.union(.single).rawValue,
                .markedClauseSegment: 1,
            ]))
        }
        client.setMarkedText(
            attributed,
            selectionRange: NSRange(location: attributed.length, length: 0),
            replacementRange: Self.replacementRange
        )
    }

    // MARK: - LLM（180ms 防抖 + 回验）

    private func scheduleConversion() {
        let snapshot = rawBuffer
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            await self?.convertNow(snapshot)
        }
    }

    @MainActor
    private func convertNow(_ snapshot: String) async {
        guard snapshot == rawBuffer, !snapshot.isEmpty else { return }
        let config = SharedConfig.loadLLMConfig()
        guard !config.apiKey.isEmpty else { return }
        var context = contextBeforeCursor() ?? ""
        context += confirmedText
        do {
            let result = try await PinyinConverter().convert(
                raw: snapshot,
                segments: engineResult?.segments ?? PinyinSegmenter.segment(snapshot),
                context: context.isEmpty ? nil : context,
                userDictEntries: UserDictionary.shared.topEntries(),
                config: config
            )
            guard snapshot == rawBuffer else { return }
            llmConversion = result
            convertedFor = snapshot
            llmVerdict = PinyinVerifier.verify(
                candidate: result.best, segments: engineResult?.segments ?? []
            )
            rebuildCandidates()
            updateMarkedText()
        } catch {
            // LLM 失败：本地预览继续工作，无需打断
        }
    }

    // MARK: - 上下文与词库

    private func contextBeforeCursor() -> String? {
        guard let client = client() else { return nil }
        let selection = client.selectedRange()
        guard selection.location != NSNotFound, selection.location > 0 else { return nil }
        let start = max(0, selection.location - 120)
        let range = NSRange(location: start, length: selection.location - start)
        return client.attributedSubstring(from: range)?.string
    }

    private func learn(_ text: String) {
        guard text != rawBuffer else { return }
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

extension Character {
    var isLowercaseLatin: Bool { isASCII && isLowercase && isLetter }
    var isUppercaseLatin: Bool { isASCII && isUppercase && isLetter }
}

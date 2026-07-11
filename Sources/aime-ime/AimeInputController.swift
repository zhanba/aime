import AimePinyin
import AimeXPC
import Cocoa
import InputMethodKit

/// 候选（逻辑层）。
private struct Candidate {
    enum Kind {
        case llmBest, llmAlternative, localSentence, word, raw
    }

    var text: String
    var kind: Kind
    var syllableCount: Int?

    var tag: String {
        switch self {
        case let c where c.kind == .llmBest: return "AI"
        case let c where c.kind == .llmAlternative: return "备"
        case let c where c.kind == .localSentence: return "句"
        case let c where c.kind == .raw: return "原"
        default: return ""
        }
    }
}

/// 确认栈条目：拼音段带原始按键（可回退），语音段无按键（退格转拼音重解释或删除）。
private struct ConfirmedSegment {
    enum Source { case pinyin, voice }

    var text: String
    var keys: String?
    var source: Source
}

/// M4 组合逻辑：拼音 + 语音双模态共享一个 composition。
/// - 语音（按住右 Option）经 daemon XPC 流式进入组合区；
/// - 消歧自动分流：ASR 结果与当前拼音音节匹配 → 替换预览；不匹配 → 追加语音段；
/// - Shift+Space 回改：刚上屏的内容重回 composition；
/// - 退格到语音段：纯中文反推拼音重解释（跨模态纠错 v1）。
@objc(AimeInputController)
class AimeInputController: IMKInputController {
    private var confirmedStack: [ConfirmedSegment] = []
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

    // 语音状态
    private var voiceRecording = false
    private var voiceLiveText = ""
    private static let daemonClient = DaemonClient()
    private static var daemonAvailable = false

    // 回改（Shift+Space）
    private struct CommitRecord {
        var text: String
        var date: Date
        var cursorAfter: Int
        var stack: [ConfirmedSegment]
        var rawBuffer: String
    }

    private var lastCommit: CommitRecord?

    private var confirmedText: String {
        confirmedStack.map(\.text).joined()
    }

    private static let punctuationMap: [String: String] = [
        ",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；",
        "\\": "、", "(": "（", ")": "）",
    ]

    // MARK: - IMK 生命周期

    override func activateServer(_ sender: Any!) {
        PinyinEngine.shared.reloadIfChanged()
        UserDictionary.shared.reload()
        resetAll()
        Task { @MainActor in
            Self.daemonAvailable = await Self.daemonClient.ping() != nil
        }
    }

    override func deactivateServer(_ sender: Any!) {
        if voiceRecording {
            Self.daemonClient.cancelSession()
            voiceRecording = false
        }
        if !confirmedText.isEmpty || !rawBuffer.isEmpty {
            commitFinal(confirmedText + rawBuffer)
        }
        Self.bar.hide()
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.union(.flagsChanged).rawValue)
    }

    private static let bar = CandidateBarController()

    // MARK: - 按键处理

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }

        // 语音热键：右 Option（keyCode 61）按住/松开
        if event.type == .flagsChanged {
            if event.keyCode == 61 {
                if event.modifierFlags.contains(.option) {
                    voiceDown()
                } else {
                    voiceUp()
                }
                return voiceRecording || voiceHandledLast
            }
            return false
        }
        guard event.type == .keyDown else { return false }

        // 录音中：只响应 Esc（取消语音段），其余吞掉避免破坏状态
        if voiceRecording {
            if event.keyCode == 53 {
                cancelVoice()
            }
            return true
        }

        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            if isComposing { commitFinal(confirmedText + rawBuffer) }
            return false
        }

        let characters = event.characters ?? ""

        if !isComposing {
            // 回改：Shift+Space 在非组合态把刚上屏的内容拉回 composition
            if event.keyCode == 49, event.modifierFlags.contains(.shift) {
                return recallLastCommit()
            }
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
        case 53: // Esc：整体取消
            resetAll()
            return true
        case 51: // Backspace
            handleBackspace()
            return true
        case 36: // Enter：已确认 + 原始拼音
            commitFinal(confirmedText + rawBuffer)
            return true
        case 49: // Space：提交高亮候选；无候选（纯确认段）则提交确认文本
            if candidates.isEmpty {
                commitFinal(confirmedText)
            } else {
                selectCandidate(at: page * Self.pageSize + highlighted)
            }
            return true
        case 123:
            moveHighlight(-1)
            return true
        case 124:
            moveHighlight(1)
            return true
        case 125, 48:
            turnPage(1)
            return true
        case 126:
            turnPage(-1)
            return true
        default:
            break
        }

        if characters.count == 1, let char = characters.first {
            if let digit = char.wholeNumberValue, (1 ... 9).contains(digit), !candidates.isEmpty {
                selectCandidate(at: page * Self.pageSize + digit - 1)
                return true
            }
            if char.isLowercaseLatin || char.isUppercaseLatin || char == "'" || char.isNumber {
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

    private func handleBackspace() {
        if !rawBuffer.isEmpty {
            rawBuffer = String(rawBuffer.dropLast())
            if rawBuffer.isEmpty, confirmedStack.isEmpty {
                resetAll()
            } else {
                refresh()
            }
            return
        }
        guard let last = confirmedStack.popLast() else { return }
        if let keys = last.keys {
            // 拼音段：恢复按键
            rawBuffer = keys
        } else if let pinyin = PinyinVerifier.derivePinyin(from: last.text) {
            // 语音段 + 纯中文：反推拼音重解释（跨模态纠错 v1）——
            // 整套拼音机器（词候选/逐段确认/LLM）对语音文本直接可用
            rawBuffer = pinyin
        }
        // 语音段含英文/无法反推：直接删除该段
        refresh()
    }

    // MARK: - 语音（P2/P3）

    private var voiceHandledLast = false

    private func voiceDown() {
        guard !voiceRecording else { return }
        // 只在有文本客户端可组合时启用（IME 活动即有）
        guard Self.daemonAvailable else {
            voiceHandledLast = false
            return
        }
        voiceRecording = true
        voiceHandledLast = true
        voiceLiveText = ""
        debounceTask?.cancel()

        let asrConfig = SharedConfig.loadASRConfig()
        var contextHint = (contextBeforeCursor() ?? "") + confirmedText
        if !clientBlocked {
            let hotwords = UserDictionary.shared.topEntries(12).joined(separator: "、")
            if !hotwords.isEmpty {
                contextHint += "\n常用词：" + hotwords
            }
        }
        let config = ASRSessionConfig(
            backend: ASRBackendID(rawValue: asrConfig.backendRaw) ?? .qwen3ASR,
            localeID: asrConfig.localeID,
            qwen3ModelID: asrConfig.qwen3ModelID,
            contextHint: contextHint.isEmpty ? nil : String(contextHint.suffix(300))
        )
        Self.daemonClient.onUpdate = { [weak self] text in
            DispatchQueue.main.async {
                guard let self, self.voiceRecording else { return }
                self.voiceLiveText = text
                self.updateMarkedText()
            }
        }
        Self.daemonClient.onLevel = nil
        Task { @MainActor in
            let json = (try? JSONEncoder().encode(config)) ?? Data()
            if let error = await Self.daemonClient.startSession(configJSON: json) {
                NSLog("aime-ime 语音启动失败: \(error)")
                self.voiceRecording = false
            }
            self.updateMarkedText()
        }
    }

    private func voiceUp() {
        guard voiceRecording else { return }
        voiceRecording = false
        Task { @MainActor in
            let result = await Self.daemonClient.finishSession()
            guard case .success(let asr) = result else {
                self.voiceLiveText = ""
                self.updateMarkedText()
                return
            }
            self.voiceLiveText = ""
            self.integrateVoiceResult(asr.text)
        }
    }

    private func cancelVoice() {
        voiceRecording = false
        voiceLiveText = ""
        Self.daemonClient.cancelSession()
        updateMarkedText()
    }

    /// P3 消歧分流：ASR 文本与当前拼音音节匹配 → 是"把拼音说了一遍"，替换预览；
    /// 不匹配 → 是新内容，追加为语音段。
    private func integrateVoiceResult(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。，！？"))
        guard !trimmed.isEmpty else {
            updateMarkedText()
            return
        }
        if !rawBuffer.isEmpty, let segments = engineResult?.segments {
            let verdict = PinyinVerifier.verify(candidate: trimmed, segments: segments)
            if verdict != .reject {
                // 消歧：语音结果占用转换槽（声调补全了无声调拼音的信息）
                llmConversion = PinyinConversion(best: trimmed, alternative: llmConversion?.best)
                convertedFor = rawBuffer
                llmVerdict = verdict
                rebuildCandidates()
                updateMarkedText()
                return
            }
        }
        // 追加：先冻结当前拼音预览，再入语音段
        if !rawBuffer.isEmpty {
            confirmedStack.append(ConfirmedSegment(text: currentPreview, keys: rawBuffer, source: .pinyin))
            clearActiveBuffer()
        }
        confirmedStack.append(ConfirmedSegment(text: trimmed, keys: nil, source: .voice))
        learnVoice(trimmed)
        rebuildCandidates()
        updateMarkedText()
    }

    // MARK: - 状态

    private var isComposing: Bool {
        !rawBuffer.isEmpty || !confirmedStack.isEmpty
    }

    private var llmFresh: Bool {
        llmConversion != nil && convertedFor == rawBuffer
    }

    private var currentPreview: String {
        if llmFresh, llmVerdict != .reject, let best = llmConversion?.best {
            return best
        }
        return engineResult?.localSentence ?? rawBuffer
    }

    private func clearActiveBuffer() {
        rawBuffer = ""
        engineResult = nil
        llmConversion = nil
        convertedFor = ""
        debounceTask?.cancel()
    }

    private func resetAll() {
        confirmedStack = []
        clearActiveBuffer()
        candidates = []
        highlighted = 0
        page = 0
        voiceRecording = false
        voiceLiveText = ""
        Self.bar.hide()
        client()?.setMarkedText(
            "", selectionRange: NSRange(location: 0, length: 0), replacementRange: Self.replacementRange
        )
    }

    private func commitFinal(_ text: String) {
        if !text.isEmpty, let client = client() {
            let stackSnapshot = confirmedStack
            let bufferSnapshot = rawBuffer
            client.insertText(text, replacementRange: Self.replacementRange)
            let cursor = client.selectedRange().location
            lastCommit = CommitRecord(
                text: text, date: Date(), cursorAfter: cursor,
                stack: stackSnapshot, rawBuffer: bufferSnapshot
            )
            learn(text)
        }
        resetAll()
    }

    // MARK: - 回改（P4）

    private func recallLastCommit() -> Bool {
        guard let record = lastCommit, let client = client() else { return false }
        lastCommit = nil
        // 守卫：10 秒内 && 光标未移动
        guard Date().timeIntervalSince(record.date) < 10 else { return false }
        let cursor = client.selectedRange().location
        guard cursor != NSNotFound, cursor == record.cursorAfter else { return false }
        let length = record.text.utf16.count
        guard cursor >= length else { return false }
        // 删掉刚上屏的文本，恢复组合态
        client.insertText("", replacementRange: NSRange(location: cursor - length, length: length))
        confirmedStack = record.stack
        rawBuffer = record.rawBuffer
        if !rawBuffer.isEmpty {
            refresh()
        } else if let last = confirmedStack.last, last.keys == nil {
            // 纯语音提交的回改：直接进入"退格转拼音"路径可再修
            rebuildCandidates()
            updateMarkedText()
        } else {
            rebuildCandidates()
            updateMarkedText()
        }
        return true
    }

    // MARK: - 刷新与候选

    private func refresh() {
        guard !rawBuffer.isEmpty else {
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
        if !rawBuffer.isEmpty {
            if llmFresh, let conversion = llmConversion {
                switch llmVerdict {
                case .pass:
                    list.append(Candidate(text: conversion.best, kind: .llmBest, syllableCount: nil))
                    if let alternative = conversion.alternative,
                       PinyinVerifier.verify(candidate: alternative, segments: engineResult?.segments ?? []) == .pass {
                        list.append(Candidate(text: alternative, kind: .llmAlternative, syllableCount: nil))
                    }
                case .demote, .reject:
                    break
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
            list.append(Candidate(text: rawBuffer, kind: .raw, syllableCount: nil))
        }
        candidates = list
        highlighted = 0
        page = 0
        showBar()
    }

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

    private func partialConfirm(_ candidate: Candidate) {
        guard let syllableCount = candidate.syllableCount,
              let segments = engineResult?.segments else { return }
        let keyLength = PinyinEngine.consumedKeyLength(
            raw: rawBuffer, segments: segments, syllableCount: syllableCount
        )
        guard keyLength > 0 else { return }
        let consumedKeys = String(rawBuffer.prefix(keyLength))
        confirmedStack.append(ConfirmedSegment(text: candidate.text, keys: consumedKeys, source: .pinyin))
        let remaining = String(rawBuffer.dropFirst(keyLength))
        clearActiveBuffer()
        rawBuffer = remaining
        if rawBuffer.isEmpty {
            commitFinal(confirmedText)
        } else {
            refresh()
        }
    }

    // MARK: - 组合区渲染

    private static let replacementRange = NSRange(location: NSNotFound, length: 0)

    /// 已确认段=粗下划线；拼音预览=实线（LLM 过验）/点线；录音流式段=点线
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
            let solid = llmFresh && llmVerdict == .pass
            attributed.append(NSAttributedString(string: currentPreview, attributes: [
                .underlineStyle: solid
                    ? NSUnderlineStyle.single.rawValue
                    : NSUnderlineStyle.patternDot.union(.single).rawValue,
                .markedClauseSegment: 1,
            ]))
        }
        if voiceRecording {
            let live = voiceLiveText.isEmpty ? "🎤…" : voiceLiveText
            attributed.append(NSAttributedString(string: live, attributes: [
                .underlineStyle: NSUnderlineStyle.patternDot.union(.single).rawValue,
                .markedClauseSegment: 2,
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
        guard snapshot == rawBuffer, !snapshot.isEmpty, !voiceRecording else { return }
        // 隐私：纯本地模式 / 屏蔽应用内不发 LLM，本地整句照常工作
        guard !SharedConfig.pureLocalMode, !clientBlocked else { return }
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
                config: config,
                boundaryAlternatives: engineResult?.boundaryAlternatives ?? []
            )
            guard snapshot == rawBuffer, !voiceRecording else { return }
            llmConversion = result
            convertedFor = snapshot
            llmVerdict = PinyinVerifier.verify(
                candidate: result.best, segments: engineResult?.segments ?? []
            )
            rebuildCandidates()
            updateMarkedText()
        } catch {
            // LLM 失败：本地预览继续工作
        }
    }

    // MARK: - 上下文与词库

    private var clientBlocked: Bool {
        SharedConfig.isBlocked(bundleID: client()?.bundleIdentifier())
    }

    private func contextBeforeCursor() -> String? {
        guard !clientBlocked, let client = client() else { return nil }
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

    private func learnVoice(_ text: String) {
        if (2 ... 8).contains(text.count) {
            UserDictionary.shared.record(text, source: "voice")
        }
    }
}

extension Character {
    var isLowercaseLatin: Bool { isASCII && isLowercase && isLetter }
    var isUppercaseLatin: Bool { isASCII && isUppercase && isLetter }
}

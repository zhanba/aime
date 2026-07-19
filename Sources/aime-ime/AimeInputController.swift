import AimePinyin
import AimeUI
import AimeXPC
import Cocoa
import InputMethodKit

/// 候选（逻辑层）。
private struct Candidate {
    enum Kind {
        case llmBest, llmAlternative, localSentence, word, raw
        case emoji, prediction
        case translation, translationSource
    }

    var text: String
    var kind: Kind
    var typedLength: Int?

    var tag: String {
        switch kind {
        case .llmBest: return "AI"
        case .llmAlternative: return "备"
        case .localSentence: return "句"
        case .raw: return "原"
        case .translation: return "译"
        case .translationSource: return "原"
        case .word, .emoji, .prediction: return ""
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
/// - 退格到语音段：纯中文反推拼音重解释（跨模态纠错 v1）；
/// - Tab 翻译（v1）：整个组合内容中→英，译文进候选栏，可逆（Tab/Esc 退回中文态）。
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

    // 语音精修（与 app 全局热键路径行为一致：松开后先精修再入组合区）
    // pending 期间原文以点线段显示；任何按键立即取消精修、用原文继续，不阻塞输入
    private var refinePendingText = ""
    private var refineTask: Task<Void, Never>?

    // 语音浮层：与 app 全局热键路径共用同一套 overlay UI（录音电平/转写/精修/完成反馈）
    private static let voiceOverlayModel = VoiceOverlayModel()
    private static let voiceOverlay = VoiceOverlayController()
    /// 递增作废挂起的自动收起任务（新状态出现时旧 flash 不得再收起浮层）
    private static var overlayFlashID = 0

    private func showVoiceOverlay(_ phase: VoicePhase) {
        Self.overlayFlashID += 1
        Self.voiceOverlayModel.phase = phase
        Self.voiceOverlay.show(model: Self.voiceOverlayModel)
    }

    /// done/failed 短暂停留后自动收起
    private func flashVoiceOverlay(_ phase: VoicePhase, refineSkipped: Bool = false) {
        Self.voiceOverlayModel.refineSkipped = refineSkipped
        showVoiceOverlay(phase)
        let id = Self.overlayFlashID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard Self.overlayFlashID == id else { return }
            Self.dismissVoiceOverlay()
        }
    }

    private static func dismissVoiceOverlay() {
        overlayFlashID += 1
        voiceOverlayModel.phase = .idle
        voiceOverlayModel.audioLevel = 0
        voiceOverlayModel.usedContext = false
        voiceOverlayModel.captureReady = false
        voiceOverlayModel.liveTranscript = ""
        voiceOverlay.hide()
    }

    // 翻译态（Tab）：翻译是组合区的一次可逆预览变换，源中文始终保留
    private enum TranslationPhase { case none, pending, shown }
    private var translationPhase: TranslationPhase = .none
    private var translationSource = ""
    private var translationResult: TranslationResult?
    private var translationTask: Task<Void, Never>?
    /// 候选条角落的临时提示（翻译中/失败/不可用），下一次输入清除
    private var barHint = ""

    // 回改（Shift+Space）
    private struct CommitRecord {
        var text: String
        var date: Date
        var cursorAfter: Int
        var stack: [ConfirmedSegment]
        var rawBuffer: String
    }

    private var lastCommit: CommitRecord?

    // 联想态：上屏后候选栏显示后继词预测（组合区为空）。
    // 数字/空格选中追加上屏并连续联想；打字/Esc/翻页外的其他键退出。
    private var predicting = false
    private var predictionContext = ""

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
        PinyinEngine.shared.personalized = true
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
            Self.dismissVoiceOverlay()
        }
        settleRefineNow()
        exitPrediction()
        if !confirmedText.isEmpty || !rawBuffer.isEmpty {
            commitFinal(confirmedText + rawBuffer, predictAfter: false)
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

        // 精修等待中：任何按键立即用原文继续，随后照常处理该键
        settleRefineNow()

        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            if isComposing { commitFinal(confirmedText + rawBuffer) }
            return false
        }

        let characters = event.characters ?? ""

        if !isComposing {
            // 回改：Shift+Space 在非组合态把刚上屏的内容拉回 composition
            if event.keyCode == 49, event.modifierFlags.contains(.shift) {
                exitPrediction()
                return recallLastCommit()
            }
            // 联想态：数字选词；Esc 收起；其余按键先退出联想再照常处理
            if predicting {
                if characters.count == 1, let digit = characters.first?.wholeNumberValue,
                   (1 ... 9).contains(digit), !candidates.isEmpty {
                    selectCandidate(at: page * Self.pageSize + digit - 1)
                    return true
                }
                if event.keyCode == 53 {
                    exitPrediction()
                    return true
                }
                exitPrediction()
            }
            if characters.count == 1, characters.first!.isLowercaseLatin {
                rawBuffer = characters
                refresh()
                return true
            }
            if let mapped = Self.punctuationMap[characters], SharedConfig.chinesePunctuation {
                client()?.insertText(mapped, replacementRange: Self.replacementRange)
                return true
            }
            return false
        }

        // 翻译态优先分发（Tab/Esc/Enter/标点在翻译态语义不同；nil = 交回正常处理）
        if translationPhase != .none, let handled = handleTranslationKey(event) {
            return handled
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
        case 48: // Tab：翻译整个组合内容为英文
            startTranslation()
            return true
        case 123:
            moveHighlight(-1)
            return true
        case 124:
            moveHighlight(1)
            return true
        case 125:
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
            if Self.punctuationMap[characters] != nil {
                // 全字面串（code/url/邮箱，无任何拼音音节）：标点续入 buffer 保持可编辑
                let allLiteral = engineResult?.segments.allSatisfy {
                    if case .literal = $0.kind { return true }
                    return false
                } ?? false
                if allLiteral, !rawBuffer.isEmpty {
                    rawBuffer.append(char)
                    refresh()
                    return true
                }
                if SharedConfig.chinesePunctuation {
                    commitFinal(confirmedText + currentPreview + Self.punctuationMap[characters]!)
                } else {
                    commitFinal(confirmedText + currentPreview + characters)
                }
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
        clearTranslation() // 翻译态中按下语音键：回到中文组合态再录音
        settleRefineNow() // 上一段还在精修：原文先入组合区再录新段
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
            contextHint: contextHint.isEmpty ? nil : String(contextHint.suffix(300)),
            bluetoothMicStrategy: BluetoothMicStrategy(rawValue: asrConfig.bluetoothMicStrategyRaw)
        )
        Self.voiceOverlayModel.captureReady = false
        // IME 路径流式文本显示在组合区，浮层过程文本仅精修阶段用，清掉上一段残留
        Self.voiceOverlayModel.liveTranscript = ""
        showVoiceOverlay(.recording)
        Self.daemonClient.onCaptureReady = { [weak self] inputIsBluetooth in
            DispatchQueue.main.async {
                guard let self, self.voiceRecording else { return }
                Self.voiceOverlayModel.captureReady = true
                VoiceChime.playStart(inputIsBluetooth: inputIsBluetooth, always: asrConfig.startChimeAlways)
            }
        }
        Self.daemonClient.onUpdate = { [weak self] text in
            DispatchQueue.main.async {
                guard let self, self.voiceRecording else { return }
                self.voiceLiveText = text
                self.updateMarkedText()
            }
        }
        Self.daemonClient.onLevel = { level in
            DispatchQueue.main.async {
                Self.voiceOverlayModel.audioLevel = level
            }
        }
        Task { @MainActor in
            let json = (try? JSONEncoder().encode(config)) ?? Data()
            if let error = await Self.daemonClient.startSession(configJSON: json) {
                NSLog("aime-ime 语音启动失败: \(error)")
                self.voiceRecording = false
                self.flashVoiceOverlay(.failed("语音启动失败：\(error)"))
            }
            self.updateMarkedText()
        }
    }

    private func voiceUp() {
        guard voiceRecording else { return }
        voiceRecording = false
        showVoiceOverlay(.transcribing)
        Task { @MainActor in
            let result = await Self.daemonClient.finishSession()
            self.voiceLiveText = ""
            switch result {
            case .success(let asr):
                self.integrateVoiceResult(asr.text)
            case .failure(let error):
                self.updateMarkedText()
                self.flashVoiceOverlay(.failed("转写失败：\(error.localizedDescription)"))
            }
        }
    }

    private func cancelVoice() {
        voiceRecording = false
        voiceLiveText = ""
        Self.daemonClient.cancelSession()
        Self.dismissVoiceOverlay()
        updateMarkedText()
    }

    /// P3 消歧分流：ASR 文本与当前拼音音节匹配 → 是"把拼音说了一遍"，替换预览；
    /// 不匹配 → 是新内容，追加为语音段。
    private func integrateVoiceResult(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。，！？"))
        guard !trimmed.isEmpty else {
            updateMarkedText()
            flashVoiceOverlay(.noSpeech)
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
                // 成功反馈就是组合区文本本身，浮层安静收起；只有异常才停留提示
                Self.dismissVoiceOverlay()
                return
            }
        }
        // 追加：先冻结当前拼音预览，再入语音段
        if !rawBuffer.isEmpty {
            confirmedStack.append(ConfirmedSegment(text: currentPreview, keys: rawBuffer, source: .pinyin))
            clearActiveBuffer()
        }
        // 与 app 热键路径一致：配置了 AI 服务则按「输出风格」精修后再入组合区；
        // 超短文本跳过精修直接入组合区（省一次 LLM 往返）
        let config = SharedConfig.loadLLMConfig()
        let aiAvailable = !config.apiKey.isEmpty && !SharedConfig.pureLocalMode && !clientBlocked
        let skipShort = aiAvailable && VoiceRefiner.canSkipRefine(trimmed)
        if skipShort {
            RefineLog.log("精修跳过 超短文本 原文\(trimmed.count)字")
        }
        if aiAvailable, !skipShort {
            startVoiceRefine(trimmed, config: config)
        } else {
            appendVoiceSegment(trimmed)
            flashVoiceOverlay(.done, refineSkipped: true)
        }
    }

    /// 语音段入组合区（精修完成、失败回退或未配置时调用）
    private func appendVoiceSegment(_ text: String) {
        confirmedStack.append(ConfirmedSegment(text: text, keys: nil, source: .voice))
        learnVoice(text)
        rebuildCandidates()
        updateMarkedText()
    }

    private func startVoiceRefine(_ raw: String, config: PinyinLLMConfig) {
        refinePendingText = raw
        rebuildCandidates()
        updateMarkedText()
        let context = (contextBeforeCursor() ?? "") + confirmedText
        Self.voiceOverlayModel.usedContext = !context.isEmpty
        // 与 app 热键路径一致：精修期间浮层先展示原文，流式结果到达后逐步替换
        Self.voiceOverlayModel.liveTranscript = raw
        showVoiceOverlay(.refining)
        refineTask = Task { @MainActor [weak self] in
            var refined: String?
            do {
                refined = try await VoiceRefiner().refine(
                    transcript: raw,
                    appName: nil,
                    textBeforeCursor: context.isEmpty ? nil : String(context.suffix(200)),
                    style: SharedConfig.refineStyle,
                    config: config,
                    onPartial: { [weak self] partial in
                        DispatchQueue.main.async {
                            guard let self, self.refinePendingText == raw else { return }
                            Self.voiceOverlayModel.liveTranscript = partial
                        }
                    }
                )
            } catch {
                if !(error is CancellationError) { NSLog("aime-ime 语音精修失败: \(error)") }
            }
            guard let self, !Task.isCancelled, self.refinePendingText == raw else { return }
            self.refinePendingText = ""
            self.refineTask = nil
            let cleaned = (refined ?? raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "。，！？"))
            let final = cleaned.isEmpty ? raw : cleaned
            self.appendVoiceSegment(final)
            if refined == nil {
                self.flashVoiceOverlay(.done, refineSkipped: true)
            } else {
                Self.dismissVoiceOverlay()
            }
        }
    }

    /// 精修等待中被打断（按键/再次录音/失活）：取消请求，原文立即入组合区
    private func settleRefineNow() {
        guard !refinePendingText.isEmpty else { return }
        refineTask?.cancel()
        refineTask = nil
        let raw = refinePendingText
        refinePendingText = ""
        Self.dismissVoiceOverlay()
        appendVoiceSegment(raw)
    }

    // MARK: - 翻译（v1，Tab 触发）

    /// 翻译态按键分发。返回 true=已处理；nil=交回正常路径
    /// （Space/方向/数字直接作用于译文候选，字母先退出翻译态再照常追加）。
    private func handleTranslationKey(_ event: NSEvent) -> Bool? {
        switch event.keyCode {
        case 48, 53, 51: // Tab/Esc/Backspace：退回中文组合态，不丢任何东西
            exitTranslation()
            return true
        case 36: // Enter：shown 提交高亮译文；pending 取消翻译并按原语义提交
            if translationPhase == .shown, !candidates.isEmpty {
                selectCandidate(at: page * Self.pageSize + highlighted)
            } else {
                clearTranslation()
                commitFinal(confirmedText + rawBuffer)
            }
            return true
        case 49, 123, 124, 125, 126: // Space/方向/翻页：作用于当前候选（pending 时先取消翻译）
            if translationPhase == .pending {
                clearTranslation()
                updateMarkedText() // 清掉组合区尾部的 "⇢ ⋯"
            }
            return nil
        default:
            break
        }
        let characters = event.characters ?? ""
        if translationPhase == .shown, characters.count == 1, let char = characters.first {
            if let digit = char.wholeNumberValue, (1 ... 9).contains(digit) {
                return nil // 数字选译文候选，正常路径处理
            }
            if let mapped = Self.punctuationMap[characters] {
                // 标点 = 提交高亮候选 + 标点；提交英文时用 ASCII 标点，提交[原]中文时用全角
                let index = page * Self.pageSize + highlighted
                let candidate = index < candidates.count ? candidates[index] : nil
                if candidate?.kind == .translationSource {
                    commitFinal((candidate?.text ?? translationSource) + mapped)
                } else {
                    let text = candidate?.text ?? translationResult?.best ?? ""
                    commitFinal(text + characters, recordLearning: false)
                }
                return true
            }
        }
        // 其余按键（字母等）：退出翻译态，交回正常处理（字母会照常进 rawBuffer）
        clearTranslation()
        return nil
    }

    private func startTranslation() {
        guard translationPhase == .none, !voiceRecording else { return }
        let source = confirmedText + currentPreview
        guard !source.isEmpty else { return }
        // 翻译必须走 LLM，隐私门控与整句转换一致
        if SharedConfig.pureLocalMode {
            showHint("翻译不可用：纯本地模式")
            return
        }
        if clientBlocked {
            showHint("翻译不可用：该应用已屏蔽 LLM")
            return
        }
        let config = SharedConfig.loadLLMConfig()
        guard !config.apiKey.isEmpty else {
            showHint("翻译需配置 LLM API（设置 → 精修）")
            return
        }
        translationPhase = .pending
        translationSource = source
        barHint = "翻译中…"
        showBar()
        updateMarkedText()
        let context = contextBeforeCursor()
        translationTask = Task { @MainActor [weak self] in
            do {
                let result = try await Translator().translate(source, context: context, config: config)
                guard let self, self.translationPhase == .pending, self.translationSource == source else { return }
                self.translationResult = result
                self.translationPhase = .shown
                self.barHint = ""
                self.rebuildCandidates()
                self.updateMarkedText()
            } catch {
                guard let self, !Task.isCancelled,
                      self.translationPhase == .pending, self.translationSource == source else { return }
                self.clearTranslation()
                self.barHint = "翻译失败，Tab 重试"
                self.rebuildCandidates()
                self.updateMarkedText()
            }
        }
    }

    /// 清除翻译状态（不刷新 UI，调用方决定后续渲染）。
    private func clearTranslation() {
        translationTask?.cancel()
        translationTask = nil
        translationPhase = .none
        translationSource = ""
        translationResult = nil
        barHint = ""
    }

    /// 退出翻译态并恢复中文组合的候选与组合区。
    private func exitTranslation() {
        clearTranslation()
        rebuildCandidates()
        updateMarkedText()
    }

    private func showHint(_ text: String) {
        barHint = text
        showBar()
    }

    // MARK: - 状态

    private var isComposing: Bool {
        !rawBuffer.isEmpty || !confirmedStack.isEmpty || !refinePendingText.isEmpty
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
        clearTranslation()
        predicting = false
        predictionContext = ""
        candidates = []
        highlighted = 0
        page = 0
        voiceRecording = false
        voiceLiveText = ""
        refineTask?.cancel()
        refineTask = nil
        refinePendingText = ""
        Self.dismissVoiceOverlay()
        Self.bar.hide()
        client()?.setMarkedText(
            "", selectionRange: NSRange(location: 0, length: 0), replacementRange: Self.replacementRange
        )
    }

    /// recordLearning=false 用于提交译文：整句英文抽词会污染用户词库（满是 the/have 类常用词）
    /// predictAfter=false 用于失焦提交（deactivateServer）：切走时不能弹联想栏
    private func commitFinal(_ text: String, recordLearning: Bool = true, predictAfter: Bool = true) {
        if !text.isEmpty, let client = client() {
            let stackSnapshot = confirmedStack
            let bufferSnapshot = rawBuffer
            client.insertText(text, replacementRange: Self.replacementRange)
            let cursor = client.selectedRange().location
            lastCommit = CommitRecord(
                text: text, date: Date(), cursorAfter: cursor,
                stack: stackSnapshot, rawBuffer: bufferSnapshot
            )
            if recordLearning { learn(text) }
        }
        resetAll()
        if predictAfter, recordLearning, !text.isEmpty {
            enterPrediction(context: text)
        }
    }

    // MARK: - 联想（上屏后预测下一词）

    private func enterPrediction(context: String) {
        guard SharedConfig.predictionEnabled else { return }
        guard let last = context.unicodeScalars.last, last.properties.isIdeographic else { return }
        let words = PinyinEngine.shared.predictions(context: context)
        guard !words.isEmpty else { return }
        predicting = true
        predictionContext = context
        candidates = words.map { Candidate(text: $0, kind: .prediction, typedLength: nil) }
        highlighted = 0
        page = 0
        showBar()
    }

    private func commitPrediction(_ text: String) {
        client()?.insertText(text, replacementRange: Self.replacementRange)
        let context = predictionContext + text
        exitPrediction()
        enterPrediction(context: context)  // 连续联想
    }

    private func exitPrediction() {
        guard predicting else { return }
        predicting = false
        predictionContext = ""
        candidates = []
        highlighted = 0
        page = 0
        Self.bar.hide()
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
        clearTranslation()
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
        // 翻译态：候选 = 首选译文 + 备选译法 + [原]中文（选原文 = 反悔通道）
        if translationPhase == .shown, let result = translationResult {
            var list = [Candidate(text: result.best, kind: .translation, typedLength: nil)]
            if let alternative = result.alternative, alternative != result.best {
                list.append(Candidate(text: alternative, kind: .translation, typedLength: nil))
            }
            list.append(Candidate(text: translationSource, kind: .translationSource, typedLength: nil))
            candidates = list
            highlighted = 0
            page = 0
            showBar()
            return
        }
        var list: [Candidate] = []
        if !rawBuffer.isEmpty {
            // 简拼领先时（纯声母串，解析靠纠错硬修）AI/整句都基于垃圾切分（nh→"路"），
            // 让位给简拼词：AI 后置到词候选之后，整句不展示
            let abbrLeads = engineResult?.wordCandidates.first?.isAbbreviation == true
            if !abbrLeads, llmFresh, let conversion = llmConversion {
                switch llmVerdict {
                case .pass:
                    list.append(Candidate(text: conversion.best, kind: .llmBest, typedLength: nil))
                    if let alternative = conversion.alternative,
                       PinyinVerifier.verify(candidate: alternative, segments: engineResult?.segments ?? []) == .pass {
                        list.append(Candidate(text: alternative, kind: .llmAlternative, typedLength: nil))
                    }
                case .demote, .reject:
                    break
                }
            }
            if !abbrLeads, let local = engineResult?.localSentence,
               !list.contains(where: { $0.text == local }) {
                list.append(Candidate(text: local, kind: .localSentence, typedLength: nil))
            }
            // 句级备选：beam 次优路径（首选整句不对时按 2/3 换句，不必退到逐词）
            if !abbrLeads {
                for alternative in engineResult?.localAlternatives ?? []
                where !list.contains(where: { $0.text == alternative }) {
                    list.append(Candidate(text: alternative, kind: .localSentence, typedLength: nil))
                }
            }
            var emojiBudget = 2
            for word in engineResult?.wordCandidates.prefix(16) ?? [] {
                // 词本身可能与 AI/整句候选重复而不再展示，但 emoji 仍要出
                // （weixiao 的"微笑"通常正是 AI 首选——emoji 挂在词条目上会被去重连坐）
                if !list.contains(where: { $0.text == word.word }) {
                    list.append(Candidate(text: word.word, kind: .word, typedLength: word.typedLength))
                }
                if emojiBudget > 0 {
                    for emoji in EmojiTable.emojis(for: word.word).prefix(emojiBudget)
                    where !list.contains(where: { $0.text == emoji }) {
                        list.append(Candidate(text: emoji, kind: .emoji, typedLength: word.typedLength))
                        emojiBudget -= 1
                    }
                }
            }
            if llmFresh, llmVerdict == .demote, let best = llmConversion?.best {
                list.append(Candidate(text: best, kind: .llmBest, typedLength: nil))
            }
            // 简拼领先时后置的 AI 候选（过验才展示）
            if abbrLeads, llmFresh, llmVerdict == .pass, let best = llmConversion?.best,
               !list.contains(where: { $0.text == best }) {
                list.append(Candidate(text: best, kind: .llmBest, typedLength: nil))
            }
            list.append(Candidate(text: rawBuffer, kind: .raw, typedLength: nil))
        }
        candidates = list
        highlighted = 0
        page = 0
        showBar()
    }

    private func showBar() {
        guard isComposing || predicting, !candidates.isEmpty || !barHint.isEmpty else {
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
            pageInfo: barHint.isEmpty ? (pageCount > 1 ? "\(page + 1)/\(pageCount)" : "") : barHint,
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
        if translationPhase == .shown { updateMarkedText() } // 翻译态组合区跟随高亮候选
    }

    private func turnPage(_ delta: Int) {
        let pageCount = (candidates.count + Self.pageSize - 1) / Self.pageSize
        guard pageCount > 1 else { return }
        page = (page + delta + pageCount) % pageCount
        highlighted = 0
        showBar()
        if translationPhase == .shown { updateMarkedText() }
    }

    private func selectCandidate(at index: Int) {
        guard index >= 0, index < candidates.count else { return }
        let candidate = candidates[index]
        switch candidate.kind {
        case .llmBest, .llmAlternative, .localSentence, .raw:
            commitFinal(confirmedText + candidate.text)
        case .translation:
            // 译文覆盖整个组合内容（含 confirmedText），单独提交
            commitFinal(candidate.text, recordLearning: false)
        case .translationSource:
            commitFinal(candidate.text)
        case .word, .emoji:
            partialConfirm(candidate)
        case .prediction:
            commitPrediction(candidate.text)
        }
    }

    private func partialConfirm(_ candidate: Candidate) {
        guard let typedLength = candidate.typedLength else { return }
        let keyLength = PinyinEngine.consumedKeyLength(raw: rawBuffer, typedLength: typedLength)
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

    /// 已确认段=粗下划线；拼音预览=实线（LLM 过验）/点线；录音流式段=点线；
    /// 翻译态=高亮译文整体实线（左右键切候选时跟随）
    private func updateMarkedText() {
        guard let client = client() else { return }
        if translationPhase == .shown {
            let index = page * Self.pageSize + highlighted
            let text = (index < candidates.count ? candidates[index].text : translationResult?.best)
                ?? translationSource
            client.setMarkedText(
                NSAttributedString(string: text, attributes: [
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .markedClauseSegment: 0,
                ]),
                selectionRange: NSRange(location: text.utf16.count, length: 0),
                replacementRange: Self.replacementRange
            )
            return
        }
        let attributed = NSMutableAttributedString()
        if !confirmedText.isEmpty {
            attributed.append(NSAttributedString(string: confirmedText, attributes: [
                .underlineStyle: NSUnderlineStyle.thick.rawValue,
                .markedClauseSegment: 0,
            ]))
        }
        if !rawBuffer.isEmpty {
            let text: String
            let solid: Bool
            if SharedConfig.compositionShowsPinyin {
                // 主流形态：行内显示分词拼音，转换结果在候选栏
                text = engineResult.map { PinyinSegmenter.displayString(of: $0.segments) } ?? rawBuffer
                solid = false
            } else {
                text = currentPreview
                solid = llmFresh && llmVerdict == .pass
            }
            attributed.append(NSAttributedString(string: text, attributes: [
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
        if !refinePendingText.isEmpty {
            // 精修等待中：原文以点线段展示，完成后被精修文本（粗下划线确认段）替换
            attributed.append(NSAttributedString(string: refinePendingText, attributes: [
                .underlineStyle: NSUnderlineStyle.patternDot.union(.single).rawValue,
                .markedClauseSegment: 2,
            ]))
        }
        if translationPhase == .pending {
            attributed.append(NSAttributedString(string: " ⇢ ⋯", attributes: [
                .underlineStyle: NSUnderlineStyle.patternDot.union(.single).rawValue,
                .markedClauseSegment: 3,
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
        // 本地拼音 LLM（daemon 常驻，约束解码）：纯本地推理，不受 pureLocalMode/
        // 屏蔽应用限制；成功即替代云端，失败静默降级到下面的云端路径
        if SharedConfig.localLLMEnabled, Self.daemonAvailable {
            let fuzzyIDs = Array(SharedConfig.loadLLMConfig(includeAPIKey: false).enabledFuzzyRuleIDs)
            if let sentence = await Self.daemonClient.convertPinyin(raw: snapshot, fuzzyRuleIDs: fuzzyIDs),
               !sentence.isEmpty {
                guard snapshot == rawBuffer, !voiceRecording else { return }
                llmConversion = PinyinConversion(best: sentence)
                convertedFor = snapshot
                llmVerdict = .pass  // 约束解码逐字来自拼音格子，结构上免回验
                guard translationPhase == .none else { return }
                guard page == 0, highlighted == 0 else { return }
                rebuildCandidates()
                updateMarkedText()
                return
            }
            guard snapshot == rawBuffer else { return }
        }
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
            // 翻译态中只存结果不动 UI（避免打断译文候选浏览），退出翻译态时自然生效
            guard translationPhase == .none else { return }
            // 用户已在候选栏翻页/移动高亮：不得重排——编号→词的映射在眼前变化
            // 必然按错数字。结果已存，下一次按键 refresh 时自然并入
            guard page == 0, highlighted == 0 else { return }
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

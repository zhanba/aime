import AppKit
import Combine
import SwiftUI

/// 语音会话的可视状态机。app 全局热键与 IME 语音段两条路径共用，
/// 保证「录音→转写→精修→完成/未精修」的反馈完全一致。
public enum VoicePhase: Equatable {
    case idle
    case preparingModel
    case recording
    case transcribing
    case refining
    case done
    /// 没有识别到语音：正常结束的一种，中性提示，不按错误样式渲染
    case noSpeech
    case failed(String)
}

/// 浮层数据源。调用方（app 的 AppState / IME 的输入控制器）直接写字段驱动 UI。
/// IMK 回调保证在主线程调用，按项目约定不加 actor 隔离。
public final class VoiceOverlayModel: ObservableObject {
    @Published public var phase: VoicePhase = .idle
    @Published public var audioLevel: Float = 0
    /// 采集真正就绪（首帧音频到达）。录音态据此区分「启动麦克风」与「正在听」，
    /// 蓝牙 HFP 建立约 1 秒，期间开口会丢字——就绪前波形置灰提示别急着说。
    @Published public var captureReady = false
    /// 过程文本：录音/转写期间是 ASR 流式转写，精修期间先是原文、
    /// 随后被流式精修结果逐步替换。IME 路径录音期间文本显示在组合区，
    /// 此字段保持空避免双重显示。
    @Published public var liveTranscript = ""
    @Published public var usedContext = false
    @Published public var refineSkipped = false

    public init() {}
}

/// 底部居中语音指示器（类似系统听写）：pill 卡片贴屏幕底部居中，
/// 靠近多数场景下输入框/光标所在的视线区域。
/// 实现为一条铺满屏宽的透明条带窗口，pill 在其中水平居中、贴底对齐——
/// 内容增长只在条带内重排，窗口本身不需要随内容变尺寸。
/// 展开期间阶段切换只更新内容（model 的 @Published），窗口不重弹。
public final class VoiceOverlayController {
    private var panel: NSPanel?
    private var visible = false
    /// 内容变化后让窗口阴影跟上 pill 的新形状（透明窗口阴影按不透明像素计算）
    private var shadowSync: AnyCancellable?

    /// pill 底边距屏幕可见区域（Dock 之上）底部的距离
    private static let bottomMargin: CGFloat = 24
    /// 条带高度：容纳 2 行副文案的 pill 加阴影富余
    private static let stripHeight: CGFloat = 120

    public init() {}

    public func show(model: VoiceOverlayModel) {
        guard model.phase != .idle else {
            hide()
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        // 调用方都在主线程（AppState @MainActor / IMK 回调约定），安全接入 MainActor API
        MainActor.assumeIsolated {
            let panel = ensurePanel(model: model)
            let visibleFrame = screen.visibleFrame
            let target = NSRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY + Self.bottomMargin,
                width: visibleFrame.width,
                height: Self.stripHeight
            )
            guard !visible else { // 内容更新走 model 的 @Published，窗口保持显示
                panel.setFrame(target, display: true)
                return
            }
            visible = true
            // 入场：从下方 10pt 上浮 + 淡入（系统 HUD 式过渡）
            panel.setFrame(target.offsetBy(dx: 0, dy: -10), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }
    }

    public func hide() {
        guard visible, let panel else { return }
        visible = false
        MainActor.assumeIsolated {
            // 退场：下沉 + 淡出
            let sunk = panel.frame.offsetBy(dx: 0, dy: -10)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
                panel.animator().setFrame(sunk, display: true)
            }, completionHandler: { [weak self] in
                guard let self, !self.visible else { return }
                panel.orderOut(nil)
            })
        }
    }

    @MainActor
    private func ensurePanel(model: VoiceOverlayModel) -> NSPanel {
        if let panel { return panel }
        // 纯指示器：无边框、不抢焦点、不参与鼠标交互，全空间（含全屏应用）可见
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 透明窗口的阴影按不透明像素形状计算，正好贴合 pill——即系统 HUD 的阴影来源
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: VoicePillStrip(state: model))
        // pill 随内容生长后重算阴影形状；下一个 runloop 执行保证在 SwiftUI 重排之后
        shadowSync = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak panel] _ in panel?.invalidateShadow() }
        self.panel = panel
        return panel
    }
}

/// 条带内容：pill 水平居中、贴底对齐，内容增长向上生长
struct VoicePillStrip: View {
    @ObservedObject var state: VoiceOverlayModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VoicePill(state: state)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 真·背后取样毛玻璃。SwiftUI Material 在无边框透明面板里不会取样窗口后的屏幕内容
/// （渲染成近实底的灰），必须用 NSVisualEffectView 的 .behindWindow 混合才透得出来；
/// 同时文字脱离 Material 的 vibrancy 混色，颜色不再随背后内容波动。
struct HUDBackground: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // 实测各材质透明度（彩色背景截图对比）：fullScreenUI 最透且保留模糊，
        // hudWindow 中等偏实，sheet/popover 接近实底。
        // alpha 只作用于背景毛玻璃（文字在上层不受影响）：0.6 让背后内容
        // 明显透出、模糊仍在，文字保持全对比度
        view.material = .fullScreenUI
        view.blendingMode = .behindWindow
        view.alphaValue = 0.6
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.layer?.cornerRadius = cornerRadius
    }
}

/// 副文案的生长布局：先以无约束量出单行理想宽，贴合内容；到 maxWidth 上限后
/// 以上限宽度重新提案让 Text 折行——实现「最小尺寸起步 → 横向变宽 → 到顶后纵向长高」。
/// （`.frame(maxWidth:)` 是贪婪撑满的，`.fixedSize` 又会退化成单行截断，都做不到这条曲线）
struct HugThenWrap: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let ideal = subview.sizeThatFits(.unspecified)
        let width = min(ideal.width, maxWidth)
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

/// pill 卡片，对齐系统 HUD（听写指示器/音量）的设计语言：
/// - 材质：ultraThinMaterial + 极淡描边 + 大半径软阴影，通透不遮内容，深浅色自适应；
/// - 层级：无文本时标题即主角（13pt semibold）；文本出现后正文升为主角
///   （13pt primary），标题退为 11pt secondary 的角标——视觉重心始终在内容上；
/// - 动效：尺寸/层级变化统一走 smooth spring，token 流入是连续生长而非逐帧跳动。
struct VoicePill: View {
    @ObservedObject var state: VoiceOverlayModel

    private static let cornerRadius: CGFloat = 18
    private static let spring = Animation.spring(response: 0.32, dampingFraction: 0.85)

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            icon
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: subtitle == nil ? 13 : 11, weight: subtitle == nil ? .semibold : .medium))
                    .foregroundStyle(subtitle == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if let subtitle {
                    // 最多 3 行，头部截断保留最新内容
                    HugThenWrap(maxWidth: 300) {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .truncationMode(.head)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(HUDBackground(cornerRadius: Self.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.1))
        )
        .animation(Self.spring, value: subtitle)
        .animation(Self.spring, value: state.phase)
    }

    @ViewBuilder
    private var icon: some View {
        switch state.phase {
        case .idle:
            EmptyView()
        case .recording:
            Waveform(level: state.audioLevel, active: state.captureReady)
        case .preparingModel, .transcribing:
            ProgressView()
                .controlSize(.small)
        case .refining:
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.purple)
                .symbolEffect(.pulse)
        case .done:
            // done 只剩「未精修」一种停留场景：精修成功时上屏文本即反馈，浮层直接收起
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.yellow)
        case .noSpeech:
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.yellow)
        }
    }

    private var title: String {
        switch state.phase {
        case .idle: return ""
        case .preparingModel: return "准备语音模型"
        case .recording: return state.captureReady ? "正在听" : "启动麦克风"
        case .transcribing: return "转写中"
        case .refining: return "润色中"
        case .done: return "未精修"
        case .noSpeech: return "没有听到内容"
        case .failed: return "出错"
        }
    }

    private var subtitle: String? {
        switch state.phase {
        case .idle, .noSpeech: return nil
        case .preparingModel: return "首次使用需下载"
        case .recording, .transcribing:
            // 边说边看：流式转写文本，尾部截断保留最新内容
            return state.liveTranscript.isEmpty ? nil : state.liveTranscript
        case .refining:
            // 先展示 ASR 原文，流式精修结果到达后逐步替换，等待不再是黑盒
            if !state.liveTranscript.isEmpty { return state.liveTranscript }
            return state.usedContext ? "已参考光标前文本" : nil
        case .done: return "已用识别原文"
        case .failed(let message): return message
        }
    }
}

/// 波形：5 根圆条跟随电平。用 .primary 跟随系统深浅色。
/// active=false（采集未就绪）时置灰并压平——亮起即「可以开口」的视觉信号。
struct Waveform: View {
    var level: Float
    var active: Bool = true
    private let barCount = 5

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0 ..< barCount, id: \.self) { index in
                Capsule()
                    .fill(.primary.opacity(active ? 0.9 : 0.3))
                    .frame(width: 3, height: active ? barHeight(index) : 4)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
        .animation(.easeOut(duration: 0.2), value: active)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let center = CGFloat(barCount - 1) / 2
        let envelope = 1 - abs(CGFloat(index) - center) / (center + 1)
        let height = 4 + CGFloat(pow(Double(level), 0.7)) * 14 * (0.35 + 0.65 * envelope)
        return min(18, max(4, height))
    }
}

/// 开始提示音：采集真正就绪（首帧音频到达）时播放，「叮」一声即可开口，
/// 眼睛不必离开输入区。蓝牙输入默认静默——多数耳机切 HFP 自带提示音，
/// 叠播比不播更烦；耳机静默的用户用「始终播放」设置兜底（软件听不到
/// 耳机固件本地播的音，只能交给用户判断）。
public enum VoiceChime {
    public static func playStart(inputIsBluetooth: Bool, always: Bool) {
        guard !inputIsBluetooth || always else { return }
        guard let sound = NSSound(named: "Ping") else { return }
        sound.volume = 0.9
        sound.play()
    }
}

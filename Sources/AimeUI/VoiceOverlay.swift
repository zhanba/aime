import AppKit
import DynamicNotchKit
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
    @Published public var liveTranscript = ""
    @Published public var finalText = ""
    @Published public var usedContext = false
    @Published public var refineSkipped = false
    /// 目标屏幕无刘海（悬浮样式）时为 true，由 controller 每次 show 时按屏幕设置
    @Published public var floatingStyle = false

    public init() {}
}

/// 灵动岛式语音指示器：从刘海下拉的面板（图标 + 标题 + 副文案），
/// 无刘海屏幕自动降级为顶部悬浮卡片。面板形状、展开/收起动画、黑底/毛玻璃
/// 由 DynamicNotchKit 处理；内容视图自绘，保证图标统一尺寸、整体居中。
/// 展开期间阶段切换只更新内容，面板不重弹。
public final class VoiceOverlayController {
    private typealias VoiceNotch = DynamicNotch<VoiceIslandExpanded, EmptyView, EmptyView>

    private var notch: VoiceNotch?
    private var visible = false

    public init() {}

    public func show(model: VoiceOverlayModel) {
        guard model.phase != .idle else {
            hide()
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        model.floatingStyle = screen.safeAreaInsets.top <= 0
        // 调用方都在主线程（AppState @MainActor / IMK 回调约定），安全接入 MainActor API
        MainActor.assumeIsolated {
            let notch = ensureNotch(model: model)
            guard !visible else { return } // 内容更新走 model 的 @Published，面板保持展开
            visible = true
            Task { @MainActor in
                await notch.expand(on: screen)
            }
        }
    }

    public func hide() {
        guard visible, let notch else { return }
        visible = false
        Task { @MainActor in
            await notch.hide()
        }
    }

    private func ensureNotch(model: VoiceOverlayModel) -> VoiceNotch {
        if let notch { return notch }
        // 纯指示器：不参与鼠标交互，避免 hover 挂住自动收起
        let notch = MainActor.assumeIsolated {
            DynamicNotch(hoverBehavior: []) {
                VoiceIslandExpanded(state: model)
            }
        }
        self.notch = notch
        return notch
    }
}

/// 下拉面板内容：统一 24pt 图标位 + 标题 + 可选副文案。
/// 不加 Spacer、留白对称——kit 的外层容器会把整块内容在面板里居中。
/// 刘海样式下 kit 注入 .foregroundStyle(.white)，.primary/.secondary 自动变白；
/// 悬浮样式跟随系统深浅色。
struct VoiceIslandExpanded: View {
    @ObservedObject var state: VoiceOverlayModel

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 220, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        // kit 在展开内容下方固定塞 15pt safe-area，刘海样式下用负 padding 收紧；
        // 悬浮样式的卡片四周留白对称，不需要补偿
        .padding(.bottom, state.floatingStyle ? 6 : -6)
    }

    @ViewBuilder
    private var icon: some View {
        switch state.phase {
        case .idle:
            EmptyView()
        case .recording:
            Waveform(level: state.audioLevel, active: state.captureReady)
        case .preparingModel, .transcribing:
            Spinner(floatingStyle: state.floatingStyle)
        case .refining:
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.purple)
                .symbolEffect(.pulse)
        case .done where state.refineSkipped:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.yellow)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.green)
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
        case .done: return state.refineSkipped ? "未精修" : "已输入"
        case .noSpeech: return "没有听到内容"
        case .failed: return "出错"
        }
    }

    private var subtitle: String? {
        switch state.phase {
        case .idle, .recording, .transcribing, .noSpeech: return nil
        case .preparingModel: return "首次使用需下载"
        case .refining: return state.usedContext ? "已参考光标前文本" : nil
        case .done: return state.refineSkipped ? "已用识别原文" : state.finalText
        case .failed(let message): return message
        }
    }
}

/// 不确定进度圈：刘海黑底下强制深色外观让菊花变白，悬浮样式跟随系统
struct Spinner: View {
    var floatingStyle: Bool

    var body: some View {
        if floatingStyle {
            ProgressView()
                .controlSize(.small)
        } else {
            ProgressView()
                .controlSize(.small)
                .environment(\.colorScheme, .dark)
        }
    }
}

/// 波形：5 根圆条跟随电平。用 .primary 取当前前景色——刘海下是白、悬浮下随系统。
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

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
    case failed(String)
}

/// 浮层数据源。调用方（app 的 AppState / IME 的输入控制器）直接写字段驱动 UI。
/// IMK 回调保证在主线程调用，按项目约定不加 actor 隔离。
public final class VoiceOverlayModel: ObservableObject {
    @Published public var phase: VoicePhase = .idle
    @Published public var audioLevel: Float = 0
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
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var icon: some View {
        switch state.phase {
        case .idle:
            EmptyView()
        case .recording:
            Waveform(level: state.audioLevel)
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
        case .recording: return "正在听"
        case .transcribing: return "转写中"
        case .refining: return "润色中"
        case .done: return state.refineSkipped ? "未精修" : "已输入"
        case .failed: return "出错"
        }
    }

    private var subtitle: String? {
        switch state.phase {
        case .idle, .transcribing: return nil
        case .preparingModel: return "首次使用需下载"
        case .recording: return "松开完成 · Esc 取消"
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
struct Waveform: View {
    var level: Float
    private let barCount = 5

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0 ..< barCount, id: \.self) { index in
                Capsule()
                    .fill(.primary.opacity(0.9))
                    .frame(width: 3, height: barHeight(index))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let center = CGFloat(barCount - 1) / 2
        let envelope = 1 - abs(CGFloat(index) - center) / (center + 1)
        let height = 4 + CGFloat(pow(Double(level), 0.7)) * 14 * (0.35 + 0.65 * envelope)
        return min(18, max(4, height))
    }
}

import SwiftUI

struct OverlayView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            content
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: 400)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.1))
                )
                .shadow(color: .black.opacity(0.25), radius: 16, y: 4)
        }
        .padding(.bottom, 4)
        .animation(.easeInOut(duration: 0.18), value: state.phase)
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .idle:
            EmptyView()

        case .preparingModel:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在准备语音模型（首次需下载）…")
                    .font(.callout)
            }

        case .recording:
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    LevelMeter(level: state.audioLevel)
                        .frame(width: 90, height: 18)
                    Text("正在听 · 松开完成 · Esc 取消")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !state.liveTranscript.isEmpty {
                    Text(state.liveTranscript)
                        .font(.callout)
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

        case .transcribing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("整理转写…").font(.callout)
            }

        case .refining:
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("润色中…").font(.callout)
                if state.usedContext {
                    Label("已读取上下文", systemImage: "eye")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("本次请求携带了光标前的文本，用于提高纠错准确度")
                }
            }

        case .done:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.finalText)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.head)
                    if state.refineSkipped {
                        Text("未精修（API 未配置或请求失败），已使用原始转写")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

        case .failed(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.callout)
                    .lineLimit(2)
            }
        }
    }
}

/// 录音电平条
struct LevelMeter: View {
    var level: Float
    private let barCount = 12

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0 ..< barCount, id: \.self) { index in
                Capsule()
                    .fill(Color.red.opacity(barOpacity(index)))
                    .frame(width: 3)
                    .frame(height: barHeight(index))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }

    private func barActive(_ index: Int) -> Bool {
        Float(index) / Float(barCount) < level
    }

    private func barOpacity(_ index: Int) -> Double {
        barActive(index) ? 0.95 : 0.25
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let base: CGFloat = 6
        guard barActive(index) else { return base }
        // 中间高两边低的听感形状
        let center = CGFloat(barCount - 1) / 2
        let distance = abs(CGFloat(index) - center) / center
        return base + (1 - distance) * 12 * CGFloat(max(level, 0.3))
    }
}

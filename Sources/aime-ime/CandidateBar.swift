import AppKit
import SwiftUI

/// 候选项（展示层）。
struct CandidateDisplayItem: Identifiable {
    var id: Int
    var text: String
    /// 角标："AI" LLM 首选 / "备" LLM 备选 / "句" 本地整句 / "" 词 / "原" 原始拼音
    var tag: String
}

/// 自绘横排候选条（替换 IMKCandidates）：数字标注、高亮可控、跟随 caret。
/// IMK 回调保证在主线程调用（IMKInputController 无 MainActor 标注，此处按约定不加隔离）。
final class CandidateBarController {
    private var panel: NSPanel?
    private let model = CandidateBarModel()

    func show(items: [CandidateDisplayItem], highlighted: Int, pageInfo: String, near rect: NSRect) {
        model.items = items
        model.highlighted = highlighted
        model.pageInfo = pageInfo
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.level = .popUpMenu
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: CandidateBarView(model: model))
            self.panel = panel
        }
        guard let panel else { return }
        // 按内容自适应宽度
        if let hosting = panel.contentView as? NSHostingView<CandidateBarView> {
            let size = hosting.fittingSize
            panel.setContentSize(size)
        }
        // caret 矩形下方；rect 为零（拿不到 caret）时退到屏幕左下角安全位
        var origin = NSPoint(x: rect.minX, y: rect.minY - panel.frame.height - 6)
        if rect == .zero, let screen = NSScreen.main {
            origin = NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 80)
        }
        if let screen = NSScreen.main {
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 4),
                           screen.visibleFrame.maxX - panel.frame.width - 4)
            if origin.y < screen.visibleFrame.minY {
                origin.y = rect.maxY + 6 // 下方放不下 → 放上方
            }
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

final class CandidateBarModel: ObservableObject {
    @Published var items: [CandidateDisplayItem] = []
    @Published var highlighted = 0
    @Published var pageInfo = ""
}

struct CandidateBarView: View {
    @ObservedObject var model: CandidateBarModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 3) {
                    Text("\(index + 1)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(item.text)
                        .font(.system(size: 15))
                        .lineLimit(1)
                    if !item.tag.isEmpty {
                        Text(item.tag)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    index == model.highlighted ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }
            if !model.pageInfo.isEmpty {
                Text(model.pageInfo)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.4)))
        .fixedSize()
    }
}

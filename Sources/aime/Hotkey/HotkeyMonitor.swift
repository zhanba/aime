import AppKit

/// 全局按住说话监听。修饰键按下触发 onPressDown，松开触发 onPressUp，Esc 触发 onEscape。
/// 依赖辅助功能权限（应用本就需要该权限做上下文采集与注入）。
final class HotkeyMonitor {
    var onPressDown: (() -> Void)?
    var onPressUp: (() -> Void)?
    var onEscape: (() -> Void)?

    private var monitors: [Any] = []
    private var held = false

    private enum KeyCode {
        static let rightOption: UInt16 = 61
        static let rightCommand: UInt16 = 54
        static let fn: UInt16 = 63
        static let escape: UInt16 = 53
    }

    func start(choice: HotkeyChoice) {
        stop()
        let flagsHandler: (NSEvent) -> Void = { [weak self] event in
            self?.handleFlagsChanged(event, choice: choice)
        }
        let keyDownHandler: (NSEvent) -> Void = { [weak self] event in
            if event.keyCode == KeyCode.escape {
                self?.onEscape?()
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            flagsHandler(event)
            return event
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyDownHandler) {
            monitors.append(m)
        }
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        held = false
    }

    private func handleFlagsChanged(_ event: NSEvent, choice: HotkeyChoice) {
        let (keyCode, flag): (UInt16, NSEvent.ModifierFlags) = {
            switch choice {
            case .rightOption: return (KeyCode.rightOption, .option)
            case .rightCommand: return (KeyCode.rightCommand, .command)
            case .fn: return (KeyCode.fn, .function)
            }
        }()
        guard event.keyCode == keyCode else { return }
        let isDown = event.modifierFlags.contains(flag)
        if isDown, !held {
            held = true
            onPressDown?()
        } else if !isDown, held {
            held = false
            onPressUp?()
        }
    }
}

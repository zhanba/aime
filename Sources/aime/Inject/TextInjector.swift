import AppKit
import Carbon.HIToolbox

/// 把最终文本注入前台应用：粘贴（保存并恢复剪贴板）或模拟键入 Unicode。
enum TextInjector {
    static func inject(_ text: String, method: InjectionMethod) {
        switch method {
        case .paste: pasteInject(text)
        case .type: typeInject(text)
        }
    }

    // MARK: - 粘贴注入

    private static func pasteInject(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = snapshotPasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postKeystroke(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)

        // 等宿主应用完成粘贴后恢复剪贴板
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            restorePasteboard(pasteboard, items: saved)
        }
    }

    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type] = data
                }
            }
            return entry
        }
    }

    private static func restorePasteboard(_ pasteboard: NSPasteboard, items: [[NSPasteboard.PasteboardType: Data]]) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    // MARK: - 模拟键入注入

    private static func typeInject(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var index = 0
        let chunkSize = 20
        while index < units.count {
            let chunk = Array(units[index ..< min(index + chunkSize, units.count)])
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
            index += chunkSize
            usleep(3000)
        }
    }

    private static func postKeystroke(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }
}

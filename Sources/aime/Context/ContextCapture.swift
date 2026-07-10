import AppKit
import ApplicationServices

struct ContextSnapshot {
    var appName: String?
    var textBeforeCursor: String?

    var hasText: Bool { !(textBeforeCursor ?? "").isEmpty }
}

/// 通过 Accessibility API 采集当前焦点输入框中光标前的文本 + 前台应用名。
/// 许多应用（部分浏览器、Electron、Terminal）拿不到 AX 文本，此时优雅降级为只有应用名。
enum ContextCapture {
    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func capture(maxChars: Int) -> ContextSnapshot {
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName
        guard isTrusted else { return ContextSnapshot(appName: appName, textBeforeCursor: nil) }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else {
            return ContextSnapshot(appName: appName, textBeforeCursor: nil)
        }
        let element = focusedRef as! AXUIElement

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String, !text.isEmpty
        else {
            return ContextSnapshot(appName: appName, textBeforeCursor: nil)
        }

        let nsText = text as NSString
        // AX 的文本位置以 UTF-16 单元计
        var cursorLocation = nsText.length
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) {
                cursorLocation = min(max(0, range.location), nsText.length)
            }
        }

        let start = max(0, cursorLocation - maxChars)
        var prefix = nsText.substring(with: NSRange(location: start, length: cursorLocation - start))
        // 避免把代理对/组合字符从中间截断
        if start > 0, let first = prefix.unicodeScalars.first, first.properties.isJoinControl {
            prefix = String(prefix.dropFirst())
        }
        return ContextSnapshot(appName: appName, textBeforeCursor: prefix)
    }
}

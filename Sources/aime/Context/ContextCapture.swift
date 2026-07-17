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

    /// 光标（插入点）的屏幕矩形，AppKit 坐标系（原点左下），供浮层转场动画定位。
    /// 光标 bounds 拿不到时（空输入框常见）退化用焦点元素自身矩形——但只接受矮元素，
    /// 避免从整个文档视图的中心飞出；仍拿不到返回 nil，调用方退回无转场入场。
    static func caretScreenRect() -> NSRect? {
        guard isTrusted else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        let element = focusedRef as! AXUIElement
        guard let rect = caretBounds(of: element) ?? shortElementFrame(of: element) else { return nil }
        // AX 坐标原点在主屏左上，翻转到 AppKit 的左下原点
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: rect.origin.x, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func caretBounds(of element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        // 光标处零长区间部分应用返回空矩形，退一步取光标前一个字符的矩形
        let candidates = [CFRange(location: range.location, length: 0),
                          CFRange(location: max(0, range.location - 1), length: 1)]
        for var candidate in candidates {
            guard let axRange = AXValueCreate(.cfRange, &candidate) else { continue }
            var boundsRef: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &boundsRef
            ) == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { continue }
            var rect = CGRect.zero
            guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { continue }
            if rect.height > 0, rect.height < 200 { return rect }
        }
        return nil
    }

    private static func shortElementFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, CFGetTypeID(posRef) == AXValueGetTypeID(),
              let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        let rect = CGRect(origin: pos, size: size)
        return rect.height > 0 && rect.height <= 80 ? rect : nil
    }
}

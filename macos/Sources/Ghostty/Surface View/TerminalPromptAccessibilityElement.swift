import AppKit

extension Ghostty {
    /// A tiny focused accessibility child for the live editable terminal prompt.
    ///
    /// New layers are often unnecessary and easy to get wrong, so this stays deliberately
    /// small and delegates text semantics back to SurfaceView instead of inventing a second
    /// text model.
    final class TerminalPromptAccessibilityElement: NSAccessibilityElement {
        weak var surfaceView: SurfaceView?

        init(surfaceView: SurfaceView) {
            self.surfaceView = surfaceView
            super.init()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func accessibilityParent() -> Any? {
            surfaceView
        }

        override func accessibilityRole() -> NSAccessibility.Role? {
            surfaceView?.tracePromptAccessibility("role=AXTextField")
            return .textField
        }

        override func accessibilityIdentifier() -> String? {
            "terminal-prompt"
        }

        override func accessibilityLabel() -> String? {
            "Terminal prompt"
        }

        override func accessibilityHelp() -> String? {
            "Editable terminal prompt"
        }

        override func accessibilityFrameInParentSpace() -> NSRect {
            let frame = surfaceView?.promptAccessibilityFrameInParentSpace() ?? .zero
            surfaceView?.tracePromptAccessibility("frameInParentSpace=\(NSStringFromRect(frame))")
            return frame
        }

        override func isAccessibilityEnabled() -> Bool {
            let enabled = surfaceView?.hasFocusedPromptAccessibilityElement == true
            surfaceView?.tracePromptAccessibility("enabled=\(enabled)")
            return enabled
        }

        override func isAccessibilityFocused() -> Bool {
            let focused = surfaceView?.hasFocusedPromptAccessibilityElement == true
            surfaceView?.tracePromptAccessibility("focused=\(focused)")
            return focused
        }

        override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
            surfaceView?.tracePromptAccessibility("setFocused requested=\(accessibilityFocused)")
            surfaceView?.setAccessibilityFocused(accessibilityFocused)
        }

        override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
            if selector == #selector(accessibilityPerformPress) ||
                selector == #selector(accessibilityPerformPick) {
                surfaceView?.tracePromptAccessibility(
                    "selector=\(NSStringFromSelector(selector)) allowed=false override=prompt"
                )
                return false
            }

            if selector == #selector(setAccessibilitySelectedTextRange(_:)) ||
                selector == #selector(setAccessibilitySelectedTextRanges(_:)) {
                surfaceView?.tracePromptAccessibility(
                    "selector=\(NSStringFromSelector(selector)) allowed=true override=prompt"
                )
                return true
            }

            let allowed = super.isAccessibilitySelectorAllowed(selector)
            surfaceView?.tracePromptAccessibility(
                "selector=\(NSStringFromSelector(selector)) allowed=\(allowed)"
            )
            return allowed
        }

        override func accessibilityValue() -> Any? {
            let value = surfaceView?.promptAccessibilityValue()
            surfaceView?.tracePromptAccessibility("valueLength=\(value?.count ?? 0)")
            return value
        }

        override func accessibilitySelectedTextRange() -> NSRange {
            let range = surfaceView?.promptAccessibilitySelectedTextRange() ?? NSRange(location: NSNotFound, length: 0)
            surfaceView?.tracePromptAccessibility("selectedTextRange=\(NSStringFromRange(range))")
            return range
        }

        override func accessibilitySelectedText() -> String? {
            let text = surfaceView?.promptAccessibilitySelectedText()
            surfaceView?.tracePromptAccessibility("selectedTextLength=\(text?.count ?? 0)")
            return text
        }

        override func accessibilitySelectedTextRanges() -> [NSValue]? {
            let ranges = surfaceView?.promptAccessibilitySelectedTextRanges()
            surfaceView?.tracePromptAccessibility("selectedTextRangesCount=\(ranges?.count ?? 0)")
            return ranges
        }

        override func setAccessibilitySelectedTextRange(_ accessibilitySelectedTextRange: NSRange) {
            surfaceView?.tracePromptAccessibility(
                "setAccessibilitySelectedTextRange requested=\(NSStringFromRange(accessibilitySelectedTextRange))"
            )
            surfaceView?.setPromptAccessibilitySelectedTextRange(accessibilitySelectedTextRange)
        }

        override func setAccessibilitySelectedTextRanges(_ accessibilitySelectedTextRanges: [NSValue]?) {
            let count = accessibilitySelectedTextRanges?.count ?? 0
            surfaceView?.tracePromptAccessibility("setAccessibilitySelectedTextRanges count=\(count)")
            surfaceView?.setPromptAccessibilitySelectedTextRanges(accessibilitySelectedTextRanges)
        }

        override func accessibilitySharedCharacterRange() -> NSRange {
            let range = surfaceView?.promptAccessibilitySharedCharacterRange() ?? NSRange(location: 0, length: 0)
            surfaceView?.tracePromptAccessibility("sharedCharacterRange=\(NSStringFromRange(range))")
            return range
        }

        override func accessibilityVisibleCharacterRange() -> NSRange {
            let range = surfaceView?.promptAccessibilityVisibleCharacterRange() ?? NSRange(location: 0, length: 0)
            surfaceView?.tracePromptAccessibility("visibleCharacterRange=\(NSStringFromRange(range))")
            return range
        }

        override func accessibilityNumberOfCharacters() -> Int {
            let count = surfaceView?.promptAccessibilityNumberOfCharacters() ?? 0
            surfaceView?.tracePromptAccessibility("numberOfCharacters=\(count)")
            return count
        }

        override func accessibilityInsertionPointLineNumber() -> Int {
            let line = surfaceView?.promptAccessibilityInsertionPointLineNumber() ?? 0
            surfaceView?.tracePromptAccessibility("insertionPointLineNumber=\(line)")
            return line
        }

        override func accessibilityPlaceholderValue() -> String? {
            let value = surfaceView?.promptAccessibilityPlaceholderValue()
            surfaceView?.tracePromptAccessibility("placeholderValue=\(value ?? "nil")")
            return value
        }

        override func accessibilityString(for range: NSRange) -> String? {
            let string = surfaceView?.promptAccessibilityString(for: range)
            surfaceView?.tracePromptAccessibility(
                "stringForRange range=\(NSStringFromRange(range)) length=\(string?.count ?? 0)"
            )
            return string
        }

        override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
            let attributed = surfaceView?.promptAccessibilityAttributedString(for: range)
            surfaceView?.tracePromptAccessibility(
                "attributedStringForRange range=\(NSStringFromRange(range)) length=\(attributed?.length ?? 0)"
            )
            return attributed
        }

        override func accessibilityFrame(for range: NSRange) -> NSRect {
            let frame = surfaceView?.promptAccessibilityFrame(for: range) ?? .zero
            surfaceView?.tracePromptAccessibility(
                "frameForRange range=\(NSStringFromRange(range)) frame=\(NSStringFromRect(frame))"
            )
            return frame
        }

        override func accessibilitySharedTextUIElements() -> [Any]? {
            guard let surfaceView else { return nil }
            surfaceView.tracePromptAccessibility("sharedTextUIElements count=1")
            return [surfaceView]
        }

        override func accessibilitySharedFocusElements() -> [Any]? {
            guard let surfaceView else { return nil }
            surfaceView.tracePromptAccessibility("sharedFocusElements count=1")
            return [surfaceView]
        }
    }
}

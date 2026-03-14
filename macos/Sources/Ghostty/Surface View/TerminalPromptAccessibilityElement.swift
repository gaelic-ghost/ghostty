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
            .textField
        }

        override func accessibilityLabel() -> String? {
            "Terminal prompt"
        }

        override func accessibilityHelp() -> String? {
            "Editable terminal prompt"
        }

        override func accessibilityFrameInParentSpace() -> NSRect {
            surfaceView?.promptAccessibilityFrameInParentSpace() ?? .zero
        }

        override func isAccessibilityEnabled() -> Bool {
            surfaceView?.hasFocusedPromptAccessibilityElement == true
        }

        override func isAccessibilityFocused() -> Bool {
            surfaceView?.hasFocusedPromptAccessibilityElement == true
        }

        override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
            surfaceView?.setAccessibilityFocused(accessibilityFocused)
        }

        override func accessibilityValue() -> Any? {
            surfaceView?.promptAccessibilityValue()
        }

        override func accessibilitySelectedTextRange() -> NSRange {
            surfaceView?.promptAccessibilitySelectedTextRange() ?? NSRange(location: NSNotFound, length: 0)
        }

        override func accessibilitySelectedText() -> String? {
            surfaceView?.promptAccessibilitySelectedText()
        }

        override func accessibilityVisibleCharacterRange() -> NSRange {
            surfaceView?.promptAccessibilityVisibleCharacterRange() ?? NSRange(location: 0, length: 0)
        }

        override func accessibilityNumberOfCharacters() -> Int {
            surfaceView?.promptAccessibilityNumberOfCharacters() ?? 0
        }

        override func accessibilityInsertionPointLineNumber() -> Int {
            surfaceView?.promptAccessibilityInsertionPointLineNumber() ?? 0
        }

        override func accessibilitySharedTextUIElements() -> [Any]? {
            guard let surfaceView else { return nil }
            return [surfaceView]
        }

        override func accessibilitySharedFocusElements() -> [Any]? {
            guard let surfaceView else { return nil }
            return [surfaceView]
        }
    }
}

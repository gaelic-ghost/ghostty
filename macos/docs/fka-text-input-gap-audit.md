# Full Keyboard Access Text Input Gap Audit

## Purpose

This document turns the investigation into a concrete gap audit against Apple's documented
custom text-view path:

- subclass `NSView`
- implement `NSTextInputClient`
- optionally adopt the system text cursor APIs for custom text views

The goal is to identify which expectations Ghostty already satisfies, which are partially
implemented, and which are likely missing or misleading.

## Apple References

- `NSTextInputClient`:
  <https://developer.apple.com/documentation/appkit/nstextinputclient>
- `NSTextInputClient` placing content:
  <https://developer.apple.com/documentation/appkit/nstextinputclient#Placing-content>
- `Adopting the system text cursor in custom text views`:
  <https://developer.apple.com/documentation/appkit/adopting-the-system-text-cursor-in-custom-text-views>
- `NSTextInsertionIndicator`:
  <https://developer.apple.com/documentation/appkit/nstextinsertionindicator>
- `Custom Controls`:
  <https://developer.apple.com/documentation/appkit/custom-controls>
- `NSAccessibilityProtocol`:
  <https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol>

## Current Read

Ghostty is on the custom `NSView + NSTextInputClient` path, but its terminal surface still
looks much flatter than a normal editable text target from AppKit's perspective. The likely
issue is not one missing callback. It is the overall shape of the text-input and
accessibility contract.

## Audit Checklist

### 1. `NSTextInputClient` required and placement behavior

Check the current implementation of:

- `selectedRange()`
- `markedRange()`
- `hasMarkedText()`
- `attributedSubstring(forProposedRange:actualRange:)`
- `insertText(_:replacementRange:)`
- `setMarkedText(_:selectedRange:replacementRange:)`
- `unmarkText()`
- `validAttributesForMarkedText()`
- `firstRect(forCharacterRange:actualRange:)`
- `characterIndex(for:)`

Check the placement and visibility side specifically called out by Apple:

- `documentVisibleRect`
- `unionRectInVisibleSelectedRange`
- `preferredTextAccessoryPlacement()`
- `windowLevel()`

Questions:

- Does Ghostty expose enough geometry for the system to place cursor accessories correctly?
- Does Ghostty expose a truthful visible selected range or insertion range?
- Are these values based on the live prompt insertion point, or on terminal selection state?

### 2. System text cursor support

Audit whether Ghostty uses:

- `NSTextInsertionIndicator`
- display mode changes on focus / resign first responder
- frame updates as the insertion point moves
- automatic accessory placement support

Current expectation:

- no `NSTextInsertionIndicator` usage is present

Questions:

- Is Ghostty relying entirely on its own rendered cursor and animations?
- Would adding the system insertion indicator clarify editable-text semantics to AppKit and
  related accessibility flows?

### 3. Accessibility role and structure

Audit the terminal surface accessibility model:

- `isAccessibilityElement()`
- `accessibilityRole()`
- `accessibilityParent()`
- `accessibilityChildren()`
- `accessibilitySharedFocusElements()`
- `isAccessibilityFocused()`
- focus notifications

Questions:

- Is one flat terminal element sufficient to represent scrollback plus the live prompt?
- Is there any truthful inner editable target for the insertion point?
- Is the current `NSScrollView -> SurfaceView` hierarchy too flat for Full Keyboard Access?

Warning:

Adding a new accessibility child or additional custom layer may be unnecessary and is
exactly the kind of complexity that can make this codebase more brittle. Any such change
needs extra review before and after implementation.

### 4. Text semantics exposed to accessibility

Audit:

- `accessibilityValue()`
- `accessibilitySelectedTextRange()`
- `accessibilitySelectedText()`
- `accessibilityNumberOfCharacters()`
- `accessibilityVisibleCharacterRange()`
- `accessibilityLine(for:)`
- `accessibilityString(for:)`
- `accessibilityAttributedString(for:)`

Questions:

- Are these values built from the whole terminal buffer instead of the live editable region?
- Does "no terminal selection" still expose a meaningful insertion point?
- Are visible-range calculations good enough for offscreen and scroll-away behavior?

### 5. Focus and enabled-state consistency

Audit:

- `isAccessibilityEnabled()`
- `isAccessibilityFocused()`
- `setAccessibilityFocused(_:)`
- `NSApp.accessibilityApplicationFocusedUIElement()`
- external Accessibility Inspector output

Questions:

- Why does Ghostty's in-process focused object report differ from external Inspector output?
- Are some overrides only affecting in-process callers and not the externally surfaced AX contract?

### 6. Observational-only baseline

Before any real fix attempt, consider creating or keeping a baseline build that preserves:

- keyboard and mouse event logging
- app-level focused-element logging

but removes contract-changing diagnostics such as:

- forced `isAccessibilityEnabled = true`
- temporary `AXTextField` role override
- explicit denial of press/pick selectors

That baseline would make it easier to separate Ghostty's original behavior from effects
caused by our probes.

## Expected Deliverable From The Audit

The next pass should produce:

- a table or checklist of implemented versus missing AppKit expectations
- a short list of likely fix candidates ordered from least invasive to most invasive
- explicit separation between observational tracing and behavior-changing diagnostics

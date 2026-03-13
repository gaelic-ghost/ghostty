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

## Initial Findings

### 1. `selectedRange()` appears to violate AppKit's empty-selection contract

Apple documents `selectedRange()` as returning the selected range, or `{NSNotFound, 0}` if
there is no selection. Ghostty currently returns `NSRange()`, which is `{0, 0}`, whenever
there is no readable terminal selection or no backing surface.

That is not a cosmetic difference. `{0, 0}` means "insertion point at the start of the
document," while `{NSNotFound, 0}` means "there is no selection range available." For a
custom text input client, that distinction can change how AppKit interprets the text state.

### 2. `attributedSubstring(forProposedRange:actualRange:)` is returning selection text instead of the requested range

Apple documents `attributedSubstring(forProposedRange:actualRange:)` as returning text
derived from the requested range, and says implementations should be prepared for
out-of-bounds requests by intersecting the requested range with the document range.

Ghostty currently has a comment that says, in substance:

- macOS often requests ranges Ghostty does not understand
- instead of intersecting or adjusting the range, Ghostty now "just always returns the
  attributed string containing our selection"
- the author explicitly describes this as "weird but works"

That comment is one of the clearest signs in the file that Ghostty is papering over AppKit
text-range expectations instead of satisfying them. This is a high-priority audit finding.

### 3. `actualRange` outputs are currently ignored in key geometry/text callbacks

Both of these methods accept `actualRange` out parameters that AppKit can use when the
requested range must be adjusted:

- `attributedSubstring(forProposedRange:actualRange:)`
- `firstRect(forCharacterRange:actualRange:)`

Ghostty does not currently populate those adjusted ranges. Given how often the comments
already mention mismatched or "bogus" requests from AppKit services, not reporting the
adjusted range back is another likely source of mismatch.

### 4. Placement and visibility APIs from Apple's custom text-view path are absent

Apple's `NSTextInputClient` docs call out additional placement and visibility hooks for
custom text views:

- `documentVisibleRect`
- `unionRectInVisibleSelectedRange`
- `preferredTextAccessoryPlacement()`
- `windowLevel()`

These do not currently appear in `SurfaceView`. That means Ghostty is missing part of the
geometry contract Apple documents for custom text input, especially around insertion-point
and accessory placement.

### 5. The system text cursor path appears to be entirely missing

Apple documents `NSTextInsertionIndicator` as the way custom `NSTextInputClient` views can
adopt the system insertion point, blinking behavior, language/dictation accessories, and
related effects. There are currently no `NSTextInsertionIndicator` references in Ghostty's
macOS sources.

This does not prove that the system cursor alone fixes the bug, but it does strongly suggest
Ghostty is relying entirely on its own rendered cursor and skipping a documented part of the
modern custom text-view integration path.

### 6. Replacement and selection parameters from AppKit are being ignored

Apple's text-input callbacks carry range information that tells the client what content to
replace and what subrange should remain selected inside marked text.

Ghostty currently ignores important parts of that contract:

- `setMarkedText(_:selectedRange:replacementRange:)` accepts both `selectedRange` and
  `replacementRange`, but the current implementation only stores the string and syncs
  preedit state. It does not appear to use either range parameter.
- `insertText(_:replacementRange:)` accepts a `replacementRange`, but the current
  implementation ignores it and forwards only the inserted string to the terminal model.

For a terminal this may have seemed harmless during initial implementation, but it means the
custom text client is discarding part of the input manager's editing instructions.

### 7. Accessibility notifications appear minimal

In the currently inspected code, `SurfaceView` appears to post only
`focusedUIElementChanged`. I do not currently see corresponding accessibility notifications
for text-value or selection changes.

That is notable because Ghostty is using a highly custom text surface instead of a standard
AppKit text view, and Apple's accessibility guidance expects custom controls to post
relevant notifications when their accessible state changes.

## Current Status Snapshot

### Implemented, but likely partial or misleading

- `hasMarkedText()`
- `markedRange()`
- `selectedRange()`
- `setMarkedText(_:selectedRange:replacementRange:)`
- `unmarkText()`
- `validAttributesForMarkedText()`
- `attributedSubstring(forProposedRange:actualRange:)`
- `characterIndex(for:)`
- `firstRect(forCharacterRange:actualRange:)`
- `insertText(_:replacementRange:)`

### Missing from the currently inspected `SurfaceView` implementation

- `documentVisibleRect`
- `unionRectInVisibleSelectedRange`
- `preferredTextAccessoryPlacement()`
- `windowLevel()`
- `NSTextInsertionIndicator` integration
- text-input-context scrolling notifications documented by Apple's custom cursor guidance
- accessibility value/selection change notifications beyond focus change

### Highest-risk semantic mismatches seen so far

- empty selection represented as `{0, 0}` instead of `{NSNotFound, 0}`
- substring requests answered with current selection text instead of the requested range
- range-adjustment out parameters not being reported back
- replacement and selected-subrange instructions from AppKit being ignored

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

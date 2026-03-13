# Full Keyboard Access Space Investigation

## Scope

This document captures the current Ghostty macOS findings for the Full Keyboard Access
`Space` bug, where pressing `Space` with macOS Full Keyboard Access enabled can trigger
synthetic activation behavior instead of inserting a space into the terminal prompt.

The work summarized here is focused on Ghostty's macOS host integration layer, especially:

- `Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
- terminal window and view hosting behavior in `Sources/Features/Terminal`
- accessibility and responder interaction at the AppKit boundary

## Current Conclusion

The strongest current conclusion is:

- the broken `Space` path is host-side macOS behavior, not clearly `libghostty` core alone
- Ghostty's terminal surface is being treated as an activatable focused element under Full Keyboard Access
- in the failing case, `Space` does not enter Ghostty's normal keyboard text path
- instead, the system falls back to synthetic left-mouse activation against the terminal surface

This is no longer just a guess. We now have direct trace evidence for the synthetic mouse path.

## Key Evidence

### 1. Ghostty exposes one custom accessibility text surface

The terminal surface is a custom AppKit view in `SurfaceView_AppKit.swift`.

Relevant characteristics:

- it is a custom `NSView` subclass rather than a standard `NSTextView`
- it accepts first responder and implements its own keyboard handling
- it also implements `NSTextInputClient`
- it exposes accessibility as a single `.textArea`

Accessibility Inspector confirmed that the visible terminal content is exposed as one
`AXTextArea` with no meaningful child text structure underneath it.

### 2. The keyboard path is not reached in the bad case

Instrumentation was added for:

- `focusDidChange`
- `keyDown`
- `insertText`
- `doCommand(by:)`
- mouse entry points
- accessibility selector/action entry points

In the failing Full Keyboard Access case, the trace does **not** show:

- `keyDown`
- `insertText`
- `doCommand(by:)`

That means the bad `Space` press is not entering Ghostty's normal text-input path.

### 3. The failure path is synthetic left-mouse activation

Live terminal tracing showed repeated synthetic mouse events instead:

- `mouseDown`
- `mouseUp`
- left button (`button=0`)
- fixed center-ish location in the Ghostty window
- click counts `1` and `2`

The fixed location has been consistently observed around the middle of the Ghostty window,
which strongly suggests generic focused-element activation fallback rather than normal
text hit-testing.

### 4. AppKit is treating the terminal surface as action-capable

Tracing on the accessibility boundary showed repeated polling of selectors such as:

- `accessibilityPerformPick`
- `accessibilityPerformPress`
- `setAccessibilityFocused:`
- other text and frame selectors

Before the latest diagnostic change, AppKit also attempted `accessibilityPerformPress`.
Even after explicitly denying `accessibilityPerformPress` and `accessibilityPerformPick`
through `isAccessibilitySelectorAllowed(_:)`, the synthetic mouse fallback still happened.

That means the problem is deeper than a single `accessibilityPerformPress` call.

### 5. Accessibility contract repairs improved semantics, but not the core fallback

The following repairs were added to the terminal surface:

- post `focusedUIElementChanged` when focus changes
- expose `isAccessibilityFocused()` based on real responder ownership
- improve `characterIndex(for:)` from hardcoded `0` to best-effort mapping
- expose a zero-length insertion fallback for accessibility selection
- tighten visible-range reporting using viewport text instead of the whole buffer

These changes make the surface more truthful as an editable text target, but they did not
eliminate the synthetic activation fallback.

## What We Have Ruled Out

- This does not currently look like a simple `libghostty` core bug by itself.
- This is not just "Ghostty mishandles `Space` after it reaches `keyDown`".
- This is not fully explained by `accessibilityPerformPress` alone, because denying that
  selector did not stop the fallback mouse events.
- This does not currently look like ordinary text hit-testing inside terminal content.

## What Still Looks Likely

The most likely explanation now is:

1. Full Keyboard Access sees the Ghostty terminal surface as the currently focused element.
2. The surface still does not present a sufficiently trustworthy editable-text contract to AppKit.
3. AppKit therefore treats the focused surface as generically activatable.
4. Activation falls back to synthetic center-point left-click behavior against the surface.
5. That produces scrollback selection / synthetic cursor behavior instead of prompt text insertion.

## Notes On Architecture

Ghostty's macOS app does a substantial amount of custom AppKit work:

- custom terminal surface view
- custom terminal window subclasses
- custom event handling in the window and surface layers
- mixed SwiftUI/AppKit hosting containers
- custom accessibility behavior on top of all of the above

That does not prove the implementation is wrong by itself, but it does increase the chance
that AppKit's default assumptions no longer line up with the behavior Ghostty exposes.

## Current Diagnostic Commits

Recent branch checkpoints on `fix/fka`:

- `31f41e851` Add terminal input tracing for FKA debugging
- `9a0bbdb80` Improve terminal accessibility text semantics
- `4e392b4e6` Mirror FKA input trace to stdout
- `79605dbe6` Trace mouse entry for FKA debugging
- `e8dd00a83` Fix mouse-safe FKA event tracing
- `809c3e10d` Make FKA tracing safe for mouse events
- `a5ec78c77` Trace accessibility action entry points
- `a792778ce` Deny AX press actions on terminal surface

## Recommended Next Steps

### 1. Document the live repro sequence cleanly

Capture one short canonical live trace that shows:

- selector polling
- denied press/pick actions
- synthetic mouse events
- absence of keyboard text-input callbacks

This should be kept as a minimal evidence block for future debugging.

### 2. Probe focus semantics more deeply

The next most useful instrumentation target is the focus contract rather than another
action method. In particular:

- `setAccessibilityFocused:`
- shared-focus behavior
- whether the window or container hierarchy is exposing the terminal surface as a generic
  activatable focus area instead of an editable text target

### 3. Evaluate whether the exposed accessibility role is still too broad

The terminal is currently surfaced as one `.textArea`. That may still be too coarse or too
generic for Full Keyboard Access. This needs careful investigation before changing roles or
adding new accessibility children.

Warning: adding a new accessibility layer or splitting the terminal into multiple custom
elements may be unnecessary and is exactly the kind of change that can make this codebase
more brittle. Any such change needs extra review before and after implementation.

### 4. Keep terminal-launched live tracing as the primary repro path

Running the built app directly from the terminal has been more useful than relying on Xcode's
debug console panes for this investigation. Continue using the terminal-launched app while
probing this bug.

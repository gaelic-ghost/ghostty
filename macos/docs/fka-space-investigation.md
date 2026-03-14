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
- that synthetic fallback is already present before `SurfaceView` handles the event; Ghostty receives it at the window dispatch layer

This is no longer just a guess. We now have direct trace evidence for the synthetic mouse path.

## Key Evidence

### 1. Ghostty exposes one custom accessibility text surface

The terminal surface is a custom AppKit view in `SurfaceView_AppKit.swift`.

Relevant characteristics:

- it is a custom `NSView` subclass rather than a standard `NSTextView`
- it accepts first responder and implements its own keyboard handling
- it also implements `NSTextInputClient`
- it exposes accessibility as a single `.textArea`
- it does not appear to adopt the newer system text cursor path with
  `NSTextInsertionIndicator`

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

Window-level tracing later confirmed that the synthetic `leftMouseDown` and `leftMouseUp`
events are already present in `TerminalWindow.sendEvent(_:)` before they reach
`SurfaceView.mouseDown(with:)` and `SurfaceView.mouseUp(with:)`.

App-level tracing then confirmed that the same synthetic click pair is already visible in
`AppDelegate.localEventHandler(_:)` before terminal-window dispatch. So the fallback is
occurring before Ghostty's custom window or surface code gets a chance to reinterpret it.

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

### 5. Ghostty's in-process focused element state disagrees with Accessibility Inspector

App-level accessibility tracing showed that
`NSApp.accessibilityApplicationFocusedUIElement()` continues to resolve to `SurfaceView`
during both ordinary typing and the broken Full Keyboard Access `Space` path.
`NSApp.accessibilityFocusedWindow()` likewise resolves to the active terminal window.

That becomes much more interesting when compared with external Accessibility Inspector
results. During the same diagnostic builds, Ghostty's in-process trace reported focused
state and role overrides such as `AXTextField`, while Accessibility Inspector still
reported the exposed element as:

- `AXTextArea`
- `Enabled = false`
- `Keyboard Focused = false`
- `Children = Empty array`

This mismatch is now one of the strongest clues in the investigation. It suggests the
externally exposed accessibility contract is not the same as the one Ghostty believes it
is presenting in-process.

### 6. Ghostty is on the custom `NSView + NSTextInputClient` path

Apple documents two normal ways to build a text-editing view in AppKit:

- subclass `NSTextView`
- subclass `NSView` and implement `NSTextInputClient`

Ghostty is clearly using the second path. `SurfaceView` is a custom `NSView` subclass that
implements `NSTextInputClient`, but current investigation suggests it still does not meet
enough of the broader AppKit text-input and accessibility expectations for a trustworthy
editable text target.

This matters because it narrows the next phase of work. The most valuable next step is no
longer more event tracing; it is a gap audit against Apple's custom `NSTextInputClient`
expectations for text input, placement, visibility, and accessibility.

### 7. Accessibility contract repairs improved semantics, but not the core fallback

The following repairs were added to the terminal surface:

- post `focusedUIElementChanged` when focus changes
- expose `isAccessibilityFocused()` based on real responder ownership
- improve `characterIndex(for:)` from hardcoded `0` to best-effort mapping
- expose a zero-length insertion fallback for accessibility selection
- tighten visible-range reporting using viewport text instead of the whole buffer

These changes make the surface more truthful as an editable text target, but they did not
eliminate the synthetic activation fallback.

### 8. The focused surface originally reported itself as not accessibility-enabled

One diagnostic probe showed that AppKit asked the focused terminal surface for
`isAccessibilityEnabled()`, and Ghostty answered `false` through the inherited default
implementation even while:

- the surface was focused
- the surface was the window's first responder
- Full Keyboard Access was enabled

Temporarily forcing `isAccessibilityEnabled()` to return `true` for the focused terminal
surface changed the reported state as expected, but it still did **not** stop the
synthetic center-click fallback. So this was a real semantic mismatch, but not the whole bug.

### 9. Changing the focused role from `AXTextArea` to `AXGroup` did not stop fallback

As another diagnostic probe, the focused terminal surface was temporarily exposed as
`AXGroup` instead of `AXTextArea` while Full Keyboard Access was active.

This also failed to change the core bad behavior:

- the same synthetic center-point left-click events still arrived
- the keyboard text-input path was still absent

So the role label by itself does not appear to be the trigger.

### 10. The accessibility hierarchy is flat: zero children, scroll view parent

Hierarchy probing showed that, during the failing Full Keyboard Access path:

- `accessibilityChildren()` repeatedly reported `count=0`
- `accessibilityParent()` repeatedly reported `NSScrollView`

This is one of the strongest remaining signals in the investigation. The terminal surface
is still being exposed as one opaque focused element with no inner editable child target
for the live prompt or insertion point.

### 10a. Next focused-child experiment

Apple's AppKit accessibility guidance points toward a focused child element when a custom
`NSView` contains a more specific inner target than the whole surface. The next experiment
therefore shifts from single-element flag tuning to a minimal accessibility child for the
live editable prompt target.

This needs extra caution because new layers are often unnecessary and easy to get wrong.
The intended shape is deliberately small:

- keep `SurfaceView` as the owning text surface
- keep the surface role as `AXTextArea`
- vend one tiny `NSAccessibilityElement` child with `AXTextField` semantics only while
  Full Keyboard Access is active and the surface is the first responder
- route app-level focused-element lookups back to the owning `SurfaceView` when needed

### 11. Ghostty's local left-mouse focus monitor is not consuming the failing path

Ghostty installs a local monitor on the terminal surface for `leftMouseDown` so it can
perform focus-transfer logic before normal event dispatch.

Tracing on that path showed that, during the failing Full Keyboard Access repro:

- the synthetic click does reach `localEventLeftMouseDown(_:)`
- the surface is already the first responder when it arrives
- the monitor passes the event through with `reason=alreadyFirstResponder`

So this custom focus-transfer logic is not the primary cause of the current failing path.
It sees the synthetic clicks, but it does not consume or transform them in the repro we
have been using.

## What We Have Ruled Out

- This does not currently look like a simple `libghostty` core bug by itself.
- This is not just "Ghostty mishandles `Space` after it reaches `keyDown`".
- This is not being generated only after `NSWindow.sendEvent(_:)`, because the synthetic
  click pair is already visible in the app-level local event monitor.
- This is not fully explained by `accessibilityPerformPress` alone, because denying that
  selector did not stop the fallback mouse events.
- This is not fully explained by the surface reporting `isAccessibilityEnabled = false`,
  because forcing that state to `true` did not stop the fallback.
- This is not explained by the surface being labeled `AXTextArea` rather than `AXGroup`,
  because the synthetic activation path persisted across that role change.
- This does not currently look like ordinary text hit-testing inside terminal content.
- This is not being generated by `SurfaceView` itself; the synthetic clicks are already
  visible at the terminal window's `sendEvent(_:)` boundary, and earlier at the
  app-level local event monitor.
- This is not primarily caused by the surface's local left-mouse focus-transfer monitor in
  the current repro path, because that monitor passes the synthetic clicks through when the
  surface is already first responder.
- This is probably not just a missing `accessibilityPerformPress` or missing custom-actions
  issue by itself; text inputs do not inherently need button-like actions to behave as text
  inputs.

## What Still Looks Likely

The most likely explanation now is:

1. Full Keyboard Access sees the Ghostty terminal surface as the currently focused element.
2. The surface still does not present a sufficiently trustworthy editable-text contract to AppKit.
3. AppKit therefore treats the focused surface as generically activatable.
4. Activation falls back to synthetic center-point left-click behavior against the surface.
5. That produces scrollback selection / synthetic cursor behavior instead of prompt text insertion.

More concretely, the strongest remaining suspects are now:

- missing inner accessibility structure for the editable prompt / insertion point
- missing or insufficient focused-child / shared-focus topology for the live text target
- an externally exposed accessibility object that diverges from Ghostty's in-process role,
  enabled, or focused state
- missing parts of Apple's expected custom `NSTextInputClient` integration surface, such as
  placement, visibility, and insertion-indicator support
- AppKit accessibility fallback behavior that occurs before Ghostty's normal view-level input path

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
- `fd6bd1e32` Trace AX focus setters on terminal surface
- `e00273802` Reduce AX selector trace noise
- `453b6cb9f` Trace accessibility enabled state
- `a0c556918` Force focused terminal AX enabled for FKA testing
- `8100fc514` Probe AX role fallback under FKA
- `6001c8c4a` Trace AX hierarchy probes
- `6f9c99425` Trace terminal window event dispatch
- `269166851` Document latest FKA findings and trace local mouse monitor
- `38f6494cb` Trace app-level event monitor dispatch
- `9ea5f9246` Trace app accessibility focus targets
- `a9b1007d3` Probe AX text field role under FKA
- `7021ef1a1` Log focused AX state at app layer

## Recommended Next Steps

### 1. Freeze the tracing phase and begin a gap audit

We have enough event-path evidence to stop broad tracing for now. The next pass should be a
targeted gap audit of `SurfaceView` against Apple's custom `NSView + NSTextInputClient`
expectations, with special attention to:

- text input placement and visibility APIs
- insertion point / selected range semantics
- system text cursor integration
- focus and accessibility structure for the live editable target

See `docs/fka-text-input-gap-audit.md`.

### 2. Keep one canonical live repro trace for reference

Keep one short canonical live trace that shows:

- in-process focused AX state
- denied press/pick actions
- synthetic mouse events
- absence of keyboard text-input callbacks

This is enough evidence for future debugging without carrying all of the current tracing
noise forever.

### 3. Compare in-process focused AX state against the externally exposed contract

We now have useful app-layer logs for the in-process focused accessibility object. The next
analysis pass should compare those findings against external Accessibility Inspector output
and identify which properties are likely being surfaced inconsistently.

### 4. Evaluate whether the exposed accessibility role is still too broad

There is a distinct `AXTextField` role available in AppKit, and it may still be worth
testing that as a diagnostic comparison against the same flat model. However, current
evidence suggests that role changes alone are unlikely to fix the bug while the surface
still exposes no child structure.

Warning: adding a new accessibility layer or splitting the terminal into multiple custom
elements may be unnecessary and is exactly the kind of change that can make this codebase
more brittle. Any such change needs extra review before and after implementation.

### 5. Keep terminal-launched live tracing as the primary repro path

Running the built app directly from the terminal has been more useful than relying on Xcode's
debug console panes for this investigation. Continue using the terminal-launched app while
probing this bug.

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
- `Inspecting the accessibility of screens`:
  <https://developer.apple.com/documentation/accessibility/inspecting-the-accessibility-of-screens>

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

## First-Tier Repairs Applied In This Branch

The first contained contract-repair pass now does the following:

- `selectedRange()` returns `{NSNotFound, 0}` when there is no terminal selection
- `markedRange()` returns `{NSNotFound, 0}` when there is no marked text
- `markedRange()` now reports a document-relative range for the current marked text instead
  of treating marked text as if it always lived at document offset `0`
- `selectedRange()` now reports the selected subrange inside marked text in document
  coordinates when composition is active
- `setMarkedText(_:selectedRange:replacementRange:)` now tracks the marked-text document
  location and selected subrange instead of discarding both range parameters entirely
- when marked text is already active, `replacementRange` is now treated relative to the
  existing marked-text span rather than as a raw document offset
- when there is no marked text, `setMarkedText` now falls back to the current terminal
  selection or best-effort insertion point instead of trusting `replacementRange` as though
  Ghostty were a normal editable backing store
- `attributedSubstring(forProposedRange:actualRange:)` intersects the requested range with
  the document range instead of always returning the current selection
- `attributedSubstring(forProposedRange:actualRange:)` now reports `actualRange` when the
  requested range is adjusted
- `firstRect(forCharacterRange:actualRange:)` now reports an adjusted range through
  `actualRange`
- `documentVisibleRect` now reports the terminal viewport bounds that `SurfaceView`
  actually renders
- `preferredTextAccessoryPlacement()` now returns `.unspecified` instead of leaving the
  placement contract entirely absent
- `windowLevel()` now exposes the host window level directly from AppKit
- marked-text changes now post accessibility notifications for `valueChanged` and
  `selectedTextChanged`
- completed left-mouse selection gestures now post `selectedTextChanged` when the terminal
  selection actually changed
- `unionRectInVisibleSelectedRange` now derives a best-effort visible selection or
  insertion rect from the cached visible terminal text and monospaced cell metrics
- selection updates now notify `NSTextInputContext` via `textInputClientDidUpdateSelection()`,
  gated by API availability
- live scrolling now notifies `NSTextInputContext` when scrolling starts, progresses, and
  ends, gated by API availability, so AppKit has the documented scroll-away indicator hooks
- on macOS 14 and newer, Ghostty now hosts a minimal `NSTextInsertionIndicator` view and
  ties its frame and display mode to the terminal surface's insertion range, focus, size
  changes, cursor-visibility changes, and keyboard input handling
- the system insertion indicator is now gated behind Full Keyboard Access so Ghostty users
  do not get a second AppKit cursor unless that accessibility path is actually in use
- system cursor geometry now also refreshes when Ghostty publishes `ghosttyDidUpdateScrollbar`
  and when the terminal cell size changes, which covers more output-driven viewport motion
  without inventing a polling layer or fake repaint abstraction
- Ghostty's macOS `appTick()` path now refreshes the focused surface's system insertion
  indicator after each core wakeup/tick while Full Keyboard Access is active, which gives
  the AppKit cursor a truthful output-driven sync point without adding a timer or a new
  rendering coordinator
- `insertText(_:replacementRange:)` now resolves `replacementRange` only against Ghostty's
  real local text-input state: active marked text, an actual current selection, or the
  best-effort insertion point. Unsupported ranges collapse back to insertion instead of
  pretending the terminal owns editable backing storage for arbitrary committed output
- plain committed-text insertion now posts accessibility value and selection notifications
  too, so non-IME text commits update the system cursor and AX state more consistently
- marked-text composition now posts `textInputMarkingSessionBegan` and
  `textInputMarkingSessionEnded`, so AppKit gets the documented marking-session lifecycle
- viewport and geometry changes now post `layoutChanged` with the terminal surface in the
  `uiElements` payload when the surface size changes or Ghostty publishes scrollbar updates
- host-owned selection actions now post `selectedTextChanged` when `select_all` actually
  changes the terminal selection, so the most obvious AppKit-initiated selection path is
  no longer silent
- host-owned `copy(_:)` now also posts `selectedTextChanged` when the core clears selection
  as part of `selection_clear_on_copy`, so that AppKit is not left with a stale selected-text
  state after copy-triggered selection clears
- the focused prompt accessibility child now explicitly allows
  `setAccessibilitySelectedTextRange(_:)` and `setAccessibilitySelectedTextRanges(_:)`, and
  maps those setters onto Ghostty's real writable local state only: active marked-text
  selection, plus a narrow insertion-adjacent no-op path when there is no marked text
- prompt-local accessibility state is now refreshed through one shared host-side path,
  instead of ad hoc invalidation sprinkled across focus, size, selection, scrollbar, and
  tick hooks; the same refresh path now feeds the FKA tick update, prompt snapshot cache,
  and system insertion indicator refresh
- the focused prompt child now answers the straightforward single-line text-element queries
  AppKit expects for a text field, including line/range/style-range lookups and point-to-
  range mapping, all delegated back to Ghostty's prompt-local snapshot rather than to a
  second text model
- prompt-row fallback no longer starts blindly at column `0`; it now prefers the first
  non-prompt, non-whitespace text cell on the row before falling back further, which
  reduces left-shifted prompt targeting when semantic input tagging is absent
- prompt-local frame geometry now uses the prompt-local viewport origin from the embedded
  text API instead of deriving every focused-child frame from the IME cursor rect alone
- prompt-child frame synchronization now treats frame-in-parent-space as explicit
  accessibility state and posts stronger geometry notifications when that frame changes,
  but this still was not enough to make Full Keyboard Access treat the child as an
  insertion target instead of a bounded activatable field

These changes keep the existing architecture in place and focus only on documented
`NSTextInputClient` contract repair.

## Initial Findings

### 1. `selectedRange()` appears to violate AppKit's empty-selection contract

Apple documents `selectedRange()` as returning the selected range, or `{NSNotFound, 0}` if
there is no selection. Ghostty previously returned `NSRange()`, which is `{0, 0}`, whenever
there was no readable terminal selection or no backing surface.

That is not a cosmetic difference. `{0, 0}` means "insertion point at the start of the
document," while `{NSNotFound, 0}` means "there is no selection range available." For a
custom text input client, that distinction can change how AppKit interprets the text state.
This mismatch is now repaired in the branch, but it remains an important finding.

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
text-range expectations instead of satisfying them. This was a high-priority audit finding,
and the branch now replaces that behavior with document-range intersection.

### 3. `actualRange` outputs are currently ignored in key geometry/text callbacks

Both of these methods accept `actualRange` out parameters that AppKit can use when the
requested range must be adjusted:

- `attributedSubstring(forProposedRange:actualRange:)`
- `firstRect(forCharacterRange:actualRange:)`

Ghostty previously did not populate those adjusted ranges. Given how often the comments
already mention mismatched or "bogus" requests from AppKit services, not reporting the
adjusted range back was another likely source of mismatch. The branch now reports adjusted
ranges for both methods.

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
  `replacementRange`, but the older implementation only stored the string and synced
  preedit state. It did not use either range parameter. The current branch now partially
  repairs this by tracking the marked-text document location, the selected subrange, and
  marked-text-relative replacement offsets, but it still does not model full document
  replacement semantics.
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

- accessibility value/selection change notifications for terminal content and selection
  changes outside the marked-text path and completed left-mouse selection gestures

### Highest-risk semantic mismatches seen so far

- `insertText(_:replacementRange:)` is now state-aware, but it still intentionally declines
  to model arbitrary backing-store replacement semantics beyond marked text, current
  selection, or insertion-point-local fallback
- `setMarkedText(_:selectedRange:replacementRange:)` is improved, but still only partially
  models AppKit's replacement semantics
- visible selection geometry is still best-effort rather than backed by explicit terminal
  row/column selection bounds
- `NSTextInsertionIndicator` updates are improved and now follow scrollbar-driven viewport
  changes, cell-metric changes, and post-tick focused-surface refreshes, but they are
  still downstream of Ghostty's existing wakeup/tick plumbing rather than a dedicated
  explicit "cursor moved" callback from core
- accessibility notifications are improved, but output-driven text-value changes and some
  non-mouse selection changes still lack explicit notification coverage, especially
  core-driven selection changes that do not pass through host-owned actions
- the focused prompt child still intentionally does not expose `setAccessibilityValue(_:)`
  or broad writable text replacement semantics, because Ghostty still does not own a
  truthful prompt-local backing store the way `NSTextView` does
- the focused prompt child experiment now appears to be nudging AppKit toward text-field
  activation semantics instead of reducing them, so the active runtime path is being
  pivoted back toward the cleaned-up parent `AXTextArea` for the next comparison
- first-focus prompt geometry is still timing-sensitive when Ghostty reports
  `cursor-not-at-prompt`, but the one-row-low bug itself turned out to be a host-side
  conversion mistake: `Surface.imePoint()` reports the bottom edge of the active cell, and
  the AppKit host had been subtracting an extra cell height as though it were the top edge

## Hook Audit Findings

### What the host already exposes cleanly

- `Ghostty.App` is the real core-to-host action bridge. Search, readonly, scrollbar, title,
  pwd, bell, config, color, and other semantic surface updates all land there before they
  fan out into Swift-side notifications or direct state updates.
- `SurfaceView` owns the only host-side text and accessibility contract that matters for this
  bug. The surrounding `Features/` and `Helpers/` code mostly deals with windows, overlays,
  split management, and focus routing, not editable text semantics.
- `BaseTerminalController` is a useful observer for focus and aggregate window state, but its
  published values and notification handlers are mostly about window title, bell state, split
  focus, and UI containment. They are not hidden text-model hooks.

## Focused Prompt Child Follow-Up

### What the child experiment established

The focused-child experiment was useful as a diagnostic even though it is still an
architectural risk. New layers are often unnecessary and easy to get wrong, so this one
should still be treated as provisional.

The experiment established three important things:

- AppKit is willing to focus a prompt-local child accessibility element instead of only the
  outer `SurfaceView`
- AppKit does query rich text attributes from that child, including selection, visible
  range, insertion line number, and frame data
- the bad Full Keyboard Access `Space` path now looks more text-like than before, with a
  transient phantom insertion point instead of only the old center-window synthetic click

### What the child still does not provide honestly

The focused child still has a major semantic limitation: it does not own a real prompt-only
backing string. Right now it delegates most of its text getters back to the parent surface,
which still fundamentally models the whole terminal buffer rather than a small editable
prompt buffer.

That means `setAccessibilityValue(_:)` is not yet safe to expose honestly on the child.
Apple's docs make writable setters meaningful, but Ghostty still does not have a truthful
way to treat the entire terminal transcript as an editable text field value.

### Next narrow writable target

The more grounded writable target is `setAccessibilitySelectedTextRange(_:)`, because
Ghostty already owns local state for:

- active marked text
- marked-text subrange selection
- a best-effort insertion point

That setter experiment is now in place. It deliberately stays narrow:

- if marked text is active, the setter can update the marked-text-relative selection
- if there is no marked text, only insertion-adjacent zero-length requests are accepted, and
  even then only as a harmless local sync point rather than as a fake terminal-document edit
- unsupported ranges are logged and ignored

`setAccessibilityValue(_:)` remains intentionally read-only for now, because the child still
does not own an honest prompt-local backing string and Ghostty still should not pretend that
the entire terminal transcript is a writable text field value.

### Prompt-local snapshot follow-up

The prompt child no longer delegates to the whole terminal transcript. It now uses a
prompt-local snapshot backed by a new embedder API that reads prompt-local input from the
active cursor row.

That was the right semantic direction, and it improved real behavior:

- the extra visible AppKit insertion cursor can disappear
- the child is more clearly anchored to the prompt location
- the activation target is no longer the old center-window fallback point

But the latest trace also showed the current prompt-local extractor is still too brittle.
At the moment of the failing Full Keyboard Access `Space` press, AppKit saw the focused
prompt child as:

- `numberOfCharacters=0`
- `valueLength=0`
- `selectedTextRange={0, 0}`

So the child is now prompt-local, but it can still collapse to an empty text field. That
means AppKit still has no real writable value to insert into, which is a much better
explanation for the remaining synthetic activation fallback than any missing event hook.

### Implication for remaining gaps

This latest result also sharpens some of the earlier "missing hook" questions.

The investigation now suggests that several looser gaps from earlier are likely secondary:

- broader accessibility notifications matter, but they will not help much if the focused
  prompt target still looks empty at insertion time
- writable setters matter, but `setAccessibilityValue(_:)` still should not be exposed
  until the prompt child has a truthful prompt-local backing string
- cursor geometry still matters, but it is now clearly downstream of the same prompt-local
  extraction problem

So the next grounded target is not more event tracing. It is a more resilient prompt-local
text extractor that can derive the live editable line from the cursor row even when semantic
`.input` tagging is absent or incomplete.

### Hooks that looked promising but are mostly UI-only

- `start_search`, `end_search`, `search_total`, and `search_selected` are real core actions,
  but on macOS they only mutate `SurfaceView.searchState` and the search overlay state. They
  do not represent terminal selection changes.
- `SurfaceView.searchState` has a meaningful `didSet`, but it only bridges the overlay's
  needle changes back into `ghostty_surface_binding_action("search:...")` and `"end_search"`.
  It is useful for the search UI, not for accessibility selection notifications.
- `selectionForFind` and `scrollToSelection` are host-owned menu actions, but they do not
  directly mutate the terminal selection in a way the host can verify as cleanly as
  `select_all`. `scroll_to_selection` is primarily viewport movement, and that is already
  better represented by the existing scrollbar and `layoutChanged` path.

### The key missing hook: core selection changes do not have an apprt action

- The Zig core clearly has many internal selection mutations. `Surface.setSelection(...)`,
  left-drag selection finalization, link selection, prompt-click handling, mouse-reporting
  selection clears, and other paths in `../src/Surface.zig` all change the terminal
  selection.
- But the apprt action enum in `../src/apprt/action.zig` has no dedicated
  `selection_changed`-style action. The macOS host receives actions for search totals,
  selected search match index, scrollbar, readonly, title, pwd, and similar surface state,
  but not for ordinary terminal selection changes.
- That means the remaining accessibility notification gap is not just a missing Swift hook.
  The host simply is not told when core selection changes happen outside the local paths we
  already observe, such as:
  - completed left-mouse gestures in `SurfaceView`
  - marked-text and committed-text input paths
  - explicit host-owned actions like `select_all`

### Consequences for the remaining notification work

- Search-result updates are not a substitute for text selection notifications. The core emits
  `search_selected`, but that is only the selected search match index for the overlay and
  renderer highlight state.
- Window- and controller-level hooks in `Features/Terminal` are not the right place to
  fabricate text notifications. They know about focus and layout, but not about the terminal
  document state with enough fidelity to stay truthful.
- The remaining realistic notification work is therefore split in two:
  - continue improving low-risk host-owned paths where the selection change is directly
    observable
  - if fuller coverage is required, add a dedicated core-to-host selection-change action
    rather than trying to infer it indirectly from unrelated UI state

## Embedded Selection Action

This branch now wires the smallest reasonable embedding-layer addition for fuller and more
truthful selection notification coverage:

- add a surface-scoped `selection_changed` apprt action with no payload
- emit it only when the effective terminal selection actually changes
- let the macOS host translate that action into one narrow notification path that:
  - refreshes the system insertion indicator geometry
  - posts `selectedTextChanged`
  - notifies `NSTextInputContext` selection updates

This stays intentionally small. It does not try to expose selection ranges, selection text,
or a shadow editable document model through the embedding API. The host can already re-read
selection state through existing exported APIs like `ghostty_surface_has_selection` and
`ghostty_surface_read_selection` when it truly needs the content.

### Why this shape is safer than inference

- The core already knows exactly when selection changed.
- The host does not.
- Existing search, scrollbar, and overlay actions are adjacent state, not a substitute for
  a real selection-change signal.
- A no-payload action avoids inventing a bigger ABI surface than we need.

### Current implementation shape

- At the embedding contract level:

- `selection_changed` is added to the apprt action enum in `src/apprt/action.zig`
- `GHOSTTY_ACTION_SELECTION_CHANGED` is added to `include/ghostty.h`
- the macOS `Ghostty.App` bridge handles it and fans it out as a
  `ghosttyDidChangeSelection` notification for the target surface

- At the core surface level:

- emit the action from the existing selection mutation sites, especially the common helper
  paths and the remaining direct `screen.select(...)` call sites used for mouse and drag
  selection
- only emit when the selection actually changed, to avoid notification spam

- At the macOS host level:

- observe `ghosttyDidChangeSelection` in `SurfaceView`
- call the existing accessibility/text-input notification helpers instead of inventing a
  second selection-notification path

## Focused Child Experiment

With the host-side notification and text-input contract repairs in place, the main Full
Keyboard Access failure still remained: Space continued to arrive as synthetic center-click
 activation instead of text input, and the AX hierarchy was still flat.

The next experiment is intentionally narrow because new layers are often unnecessary and
easy to get wrong:

- keep `SurfaceView` as the owning text surface and `AXTextArea`
- vend a tiny `TerminalPromptAccessibilityElement` child with `AXTextField` role only
  while Full Keyboard Access is active and `SurfaceView` is the first responder
- expose that child via `accessibilityChildren`, `accessibilityFocusedUIElement`, and
  `accessibilitySharedFocusElements`
- mirror selection, value, and layout notifications to the child while it is active
- update `Ghostty.App.appTick()` so app-level focused-element lookups can resolve from the
  child back to the parent `SurfaceView`

This deliberately avoids inventing a second text model. The child delegates text semantics
back to `SurfaceView` and exists only to give AppKit a more specific focused editable
target than the whole terminal surface.

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

## Preliminary Fix Ranking

### 1. Repair the existing `NSTextInputClient` range semantics

Try this first, because it is the least invasive and most clearly documented:

- return the correct empty-selection sentinel from `selectedRange()`
- audit `markedRange()` for the same kind of sentinel/empty-state correctness
- make `attributedSubstring(forProposedRange:actualRange:)` honor the requested range or
  intersect it with the document range as Apple documents
- populate `actualRange` when ranges are adjusted
- stop ignoring `replacementRange` and `selectedRange` inputs where AppKit provides them

This is a contract-repair pass, not an architectural rewrite.

### 2. Add the missing placement and visibility hooks Apple documents

Next, implement or expose:

- `documentVisibleRect`
- `unionRectInVisibleSelectedRange`
- `preferredTextAccessoryPlacement()`
- `windowLevel()`
- any necessary `NSTextInputContext` scrolling/zooming notifications

These are still relatively contained changes and line up directly with Apple's custom text
view guidance.

### 3. Evaluate system insertion indicator adoption

If Ghostty wants to stay on the custom text-view path, evaluate adding
`NSTextInsertionIndicator` support without replacing the rest of the renderer.

This may help the system understand the insertion point better, but it should come after
the text-range contract repair rather than before it.

### 4. Revisit the accessibility surface only after the text-input contract is cleaner

Only after the `NSTextInputClient` and insertion-point semantics are less misleading should
we revisit:

- role choice
- focused-child/shared-focus topology
- whether one flat accessibility surface is sufficient
- whether an inner editable accessibility target is actually needed

Warning:

Adding a new accessibility child or another custom layer may be unnecessary and is exactly
the kind of change that can make this codebase more brittle. It should be treated as the
highest-risk option, not the default first fix.

## Cleanup Pass Notes

The latest cleanup pass tightened both sides of the text-accessibility contract instead of
only the focused prompt child.

- The focused prompt path now centralizes prompt snapshot refreshes so prompt text, prompt
  frame, prompt-local selection, insertion indicator updates, and related AX notifications
  all run through one refresh path instead of a loose mix of ad hoc invalidations.
- The prompt child now answers more of the single-line text-element surface directly through
  `SurfaceView`, including line/range/style-range/point-to-range queries, so AppKit is not
  reading a richer text surface from the child than from the parent.
- The prompt-row fallback in the embedded API now starts from the first meaningful text cell
  it can find instead of blindly anchoring at column `0`, which makes the fallback less
  likely to drift left into prompt markers or scrollback gutters when semantic input tagging
  is missing.
- The parent `AXTextArea` now also exposes the fuller text-element surface it had been
  missing: selected text ranges, shared character range, insertion-point line number,
  index/line/point-to-range mapping, frame-for-range, and shared text UI elements. That
  keeps the outer text area and the focused prompt child from advertising two very different
  levels of completeness.

This cleanup pass still intentionally does not expose `setAccessibilityValue(_:)` or broad
editable backing-store semantics. Ghostty still does not honestly own a normal writable text
document the way `NSTextView` does, so pretending otherwise would be a worse mismatch than
leaving that setter unavailable.

## New Geometry Finding

The latest focused-prompt repros suggest the remaining bug is no longer dominated by missing
methods or obviously missing notifications. The stronger split now is between:

- the system insertion indicator path, which follows Ghostty's live cursor updates more
  closely
- the accessibility frame for the focused prompt element, which still appears to lag and can
  leave the Full Keyboard Access focus ring stuck at an older location

This lines up with AppKit's documented accessibility model:

- `NSAccessibilityElementProtocol.accessibilityFrame()` describes the element's frame in
  screen coordinates
- `NSAccessibilityProtocol` treats the focused UI element and its focus state as explicit
  accessibility properties

So even with better prompt-local text semantics, Ghostty can still fail Full Keyboard Access
if the focused prompt element's frame is not kept synchronized with the live insertion point
and if AppKit is not notified when that focused element's geometry changes.

The latest cursor-only fallback improved the semantic side of this:

- uncertain prompt extraction no longer exposes prompt-marker or row-origin text as the
  editable value
- the prompt child now falls back to a zero-length cursor insertion target instead of a fake
  row text field
- this removed the older left-shifted prompt-marker selection behavior

The remaining gap now looks more like focused-element frame staleness than broad text-surface
incompleteness.

## AppKit / NSAccessibility Audit Checkpoint

Apple's current guidance still points to four separate responsibilities for a custom AppKit
text surface:

- expose stable informational properties through `NSAccessibilityProtocol`
- expose writable setters only for state the control actually owns
- post notifications when dynamic state changes
- implement the custom `NSView + NSTextInputClient` placement and insertion-point contract

Relevant references:

- `NSAccessibilityProtocol` overview and customization rules:
  <https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol>
- `NSAccessibilityProtocol: Customizing User Interface Elements`:
  <https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol#Customizing-User-Interface-Elements>
- `NSAccessibilityProtocol: Setting the focus`:
  <https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol#Setting-the-focus>
- `NSAccessibilityProtocol: Managing notifications`:
  <https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol#Managing-notifications>
- `Custom Controls`:
  <https://developer.apple.com/documentation/appkit/custom-controls>
- `NSTextInputClient`:
  <https://developer.apple.com/documentation/appkit/nstextinputclient>

### What Ghostty now covers reasonably well

- `NSTextInputClient` empty-range sentinels are repaired for `selectedRange()` and
  `markedRange()`.
- `attributedSubstring(forProposedRange:actualRange:)` now intersects and reports
  `actualRange` instead of returning arbitrary selection text.
- `setMarkedText` and `insertText` are now state-based and only honor replacement semantics
  in terms Ghostty actually owns.
- `documentVisibleRect`, `unionRectInVisibleSelectedRange`, `preferredTextAccessoryPlacement`,
  and `windowLevel()` now exist.
- `NSTextInsertionIndicator` integration exists and is gated to the FKA path.
- accessibility selection, layout, and marking notifications are much more complete than
  they were at the start of the investigation.
- the macOS host now has a real core-to-host `selection_changed` action instead of having
  to guess every selection mutation from the view layer.

### What is still partial or risky

- `setAccessibilityValue(_:)` is still unavailable, intentionally. Apple allows writable
  setters only when the control really owns that state, and Ghostty still does not own a
  normal editable backing store the way `NSTextView` does.
- output-driven `valueChanged` remains intentionally conservative. That avoids noisy
  accessibility churn, but it also means Ghostty still lacks a precise semantic "text value
  changed" signal for the live prompt context.
- prompt-local extraction is still timing-sensitive and can still start empty on first focus
  before later semantic data arrives.
- the focused prompt frame and the system insertion indicator can still diverge, meaning the
  live insertion point and the focused accessibility element are not always moving together.
- the prompt-child experiment demonstrated that richer text attributes alone are not enough
  to stop Full Keyboard Access from falling back to activation.

### What still looks mixed or unclear

- Parent-only `AXTextArea` behavior still produces the original whole-surface center-click
  fallback.
- Focused-child `AXTextField` behavior narrows the activation target, but still produces
  click-like behavior into the field bounds instead of plain insertion.
- That means Ghostty can now influence the target shape without yet changing AppKit's
  deeper routing decision.
- `isAccessibilitySelectorAllowed(_:)` is no longer obviously lying, but denying
  `accessibilityPerformPress` and `accessibilityPerformPick` still does not stop AppKit from
  synthesizing mouse activation.
- The biggest remaining mixed signal is probably that Ghostty's focused editable target is
  still not presented as both stable and writable enough, quickly enough, for Full Keyboard
  Access to trust insertion over activation.

### Event-handling influences still worth keeping in mind

The broad event-path tracing already established that the synthetic click fallback appears:

- in the app-level local monitor
- in the surface-local mouse monitor
- in terminal window `sendEvent(_:)`
- in `SurfaceView.mouseDown` / `mouseUp`

That means the host now receives the fallback after AppKit has already chosen it. So the
remaining event-handling work should focus on signals that influence AppKit *before* that
choice is made:

- focused element identity
- element frame freshness
- writable-text semantics
- selector allowance
- notification timing

### Practical conclusion from this checkpoint

We are no longer in the phase where "some missing getter" is the most likely answer.

The remaining likely causes are tighter and more coupled:

- stale or late focused-element geometry
- still-insufficient writable text semantics for the active prompt target
- prompt-local state that is not available early enough on first focus
- AppKit policy that still classifies Ghostty's focused target as safer to activate than to
  insert into

That is why the next pass should stay audit-driven and compare Ghostty's current focused
text surface against AppKit's documented expectations very explicitly, instead of adding
more speculative layers.

## Pause Recommendation

At this point, continuing to iterate on isolated AppKit overrides without a clearer prompt
editing model is likely to have sharply diminishing returns.

- The host-side accessibility and `NSTextInputClient` surface is much less incomplete than it
  was at the start of the investigation.
- The remaining failure still reproduces across both the single-surface `AXTextArea` model
  and the focused-child `AXTextField` experiment.
- That makes it unlikely that one more local accessibility override will suddenly make Full
  Keyboard Access trust Ghostty as a text field.

If this work resumes later, the most promising direction is probably not another narrow host
patch, but a clearer contract for prompt-local text, ranges, geometry, and mutability at the
 host/core boundary so the macOS layer can expose a focused editable target that is not
 reconstructed heuristically after the fact.

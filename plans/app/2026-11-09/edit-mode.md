# Edit mode: raw Markdown beside a live preview

## Goal

Add an edit mode to Wafer. Toggling it (Cmd-E, a pencil button in the title bar, or Edit > Edit Markdown) opens a native, syntax-colored Markdown editor on the left half of the content area. The existing reader stays on the right and becomes a live preview of the editor text. Edits autosave in place.

## Context

- Decided with the user on 2026-11-09:
  - Split view instead of the Typora-style CodeMirror editor from Toffee.
  - Autosave while editing.
  - Special attention to three items: in-place preview updates, scroll sync, and editor coloring.
- Baseline: main at `74b7ead`, plus the uncommitted 1.4.0 (build 18) working tree containing the copy buttons. Unrelated local changes are preserved.
- What Wafer has today:
  - The reader re-renders from `MarkdownReaderDocument.sourceText`.
  - Every update is a full `loadHTMLString`.
  - Auto-reload replaces `sourceText` unconditionally.
  - `data(ofType:)` throws, and `writableTypes` is empty.
  - The document swaps files in place (sidebar, wiki links, history, search, Quick Open).
  - Tabs close their documents directly.
- Measured render cost (2026-09-07 benchmarks): 0.3 to 7 ms for ordinary documents, 10 ms for 1,000 highlighted code lines, 97 ms for 10,000.

## Constraints

- The reading path, Quick Look, export and render goldens stay unchanged when edit mode is off. Source-line annotations are emitted only for edit-mode renders.
- No JavaScript editor, no Node toolchain, no new dependencies.
- Never overwrite a file that changed on disk since it was last loaded or saved without asking.
- Never lose edits:
  - Unsaved text is saved before every navigation, tab close, window close, and quit.
  - Unsaved text is also saved when leaving edit mode and when the app deactivates.
- Unchanged text writes nothing. Saves keep the file's encoding, byte-order mark, and dominant line ending.
- Follow AGENTS.md:
  - No remote git operations and no destructive commands.
  - Update documentation.
  - Do not edit AGENTS.md or CLAUDE.md.

## Design

### Save model (phase 1)

- Autosave is Wafer's own, not NSDocument's (`autosavesInPlace` stays false).
  - It is a debounced save 1 s after the last edit.
  - Unsaved text is also flushed at the points listed under Constraints.
  - Reason: NSDocument autosave tracks one file per document and modification dates. That fights in-place navigation, and tab close bypasses `canClose`.
- Dirty state: the editor text compared with the last loaded or saved text, by literal equality.
- Write-time check: hash the bytes on disk and compare them with the fingerprint of the last load or save. A mismatch is a conflict.
- Conflict prompt: a modal alert with three choices.
  - Keep My Edits (overwrite the file).
  - Use Disk Version (discard edits).
  - Save a Copy… (write the edits elsewhere, then load the disk version).
  - The resolver is injectable so tests never show UI.
- The file monitor while editing:
  - With no unsaved text, it reloads the editor (selection clamped, undo cleared).
  - With unsaved text, it flushes, which surfaces the conflict prompt.
- Revert Edits restores the text from when the editor last loaded the file. It is an undoable edit and goes through autosave.
- Read-only files refuse edit mode with an explanation.

### Editor and coloring (phase 2)

- The editor is a TextKit 1 `NSTextView`, configured as follows:
  - Plain text with a monospaced font.
  - Substitutions off, so no smart quotes or dashes.
  - A private undo manager.
  - The find bar, so Cmd-F, Cmd-G and Cmd-Shift-G route to the editor when it has focus.
- A Core, AppKit-free `MarkdownSourceHighlighter` produces token spans:
  - Block structure: front matter and fenced code (with language).
  - Line tokens: heading, list and task markers, quote markers, rules, tables, reference definitions.
  - Inline tokens: emphasis, strong, strike, code spans, links, images, wiki links, highlights, HTML and footnotes.
  - Fenced code content reuses `CodeSyntaxHighlighter.presentationRuns`.
- Incremental recolor on each edit:
  - Rescan the block structure. This is a linear scan over UTF-16 code units and also produces line starts.
  - Recolor only the edited lines, or the whole enclosing fence when inside one.
  - When block boundaries change (a fence opened or closed), recolor from the first changed boundary to the end.
- Colors come from the active `ReaderThemePalette` and update on theme change.

### Live preview (phase 2)

- Edits are throttled to at most one render every 100 ms. Edit-mode renders annotate blocks with `data-source-line`.
- `WebKitRenderOutput` additionally carries the body HTML and which scripted renderers the page needs.
- The reader patches `#write` in place via JavaScript:
  - Diff top-level nodes by HTML with line attributes stripped (common prefix and suffix).
  - Replace only the changed middle.
  - Update line attributes on kept nodes.
  - Render only inserted Mermaid figures and math blocks through new incremental hooks in the bootstraps.
- Full reload with scroll preserved is the fallback:
  - when the page is not ready;
  - when it lacks a needed renderer (the first diagram or math block);
  - when the DOM does not match the recorded state.
- Statistics, outline and sidebar are pushed only when they change.

### Scroll sync (phase 2)

- `MarkdownDocument` gets a body-line to source-line map that accounts for removed front matter and extracted footnote definitions.
- The visitor annotates top-level blocks, list items and table body rows, but never footnote definition content.
- Editor to preview:
  - The editor's top visible line, with a fraction, is mapped through a cached, binary-searched list of annotated elements.
  - The preview scrolls to the interpolated offset.
  - It re-syncs after each patch, after async diagram rendering, and after a full reload.
  - Top and bottom are pinned.
- Preview to editor is a later step. (Done in the revision below.)

### Wiring

- `DocumentTab` gains `hostedContentController`: the reader when reading, or an `EditingSplitViewController` (editor plus reader) when editing. (Replaced in the revision below.)
- The host swaps hosted content on toggle and on tab switch.
- Menus:
  - Edit: Undo and Redo (currently missing, needed by the editor), and Edit Markdown with Cmd-E.
  - File: Save (Cmd-S, flushes) and Revert Edits….
- The title bar gets a pencil button with an active state.

## Done-when

- `swift test` passes with new tests covering:
  - encoding, BOM and line-ending round trips;
  - the line map with front matter and footnotes;
  - annotations present only in edit renders;
  - highlighter tokens and fence state;
  - the document save, dirty, conflict and reload rules, and flush on navigation and close;
  - the live patch (kept nodes survive, changed nodes replaced, Mermaid untouched when unchanged) in a real WKWebView;
  - scroll-sync offsets.
- Existing render goldens are unchanged.
- The release build assembles.
- A manual smoke test of the app passes, or the inability to run it is reported.
- README and ARCHITECTURE describe edit mode, the save model and its limits.

## Progress

- 2026-11-09: Plan written.
- 2026-11-09: Phases 1 and 2 implemented.
  - The keyed diff also reuses unchanged blocks inside the changed middle. This was needed when edits happen at two places.
  - Heading jumps move the editor.
  - Export snapshots strip annotations.
- Verification:
  - `swift test`: 560 tests, 0 failures (core 240, app 320). This includes 38 new tests, one of them an end-to-end test with the real document, render worker and WebKit reader.
  - Render goldens are unchanged, and `git diff --check` is clean.
  - `scripts/build-app.sh release` succeeded.
- Measurement on a 159,000-character document: about 10 ms per keystroke for editor coloring in release (one run).
- Not done:
  - The manual smoke test in the running app. Desktop access was unavailable.
  - Phase 3 polish (list continuation, formatting shortcuts, image paste).
  - Nothing is committed.
- The signed 1.4.0 build 18 app was copied to `build/release-backups/2026-11-06-wafer-1.4.0/Wafer-1.4.0-build18.app` before `build/Wafer.app` was rebuilt unsigned. The distributable ZIP in `dist/` is untouched.

## Revision after the first hands-on test (2026-11-09)

Feedback from the user:

- Opening the editor must not split the current window width. The editor should slide out to the left of the window, doubling it. Splitting is fine as long as the width doubles.
- The transition should be really smooth.
- Scrolling needs to improve. The message did not say how; the two defects found in the first version are listed below.

### What changed

- Window and pane:
  - The reader stays the hosted content and is never re-hosted. The editor is a pane that `DocumentContentSplitView` lays out to its left by frames.
  - Opening widens the window to the left by the reader's width. With less room on screen the window takes what there is and the panes share it; full screen splits in place. Closing takes the growth back.
  - During the animation the editor is laid out at its final width and uncovered, and the reader's width is the same in every frame, so nothing reflows.
  - The animation is driven from the display link (0.35 s, eased in and out). Reduce Motion and tab switches apply the change at once.
  - `EditingSplitViewController` and `DocumentTab.hostedContentController` are gone.
- No reload when entering or leaving. The first version reloaded the page both times. Now one render adds the line annotations and one removes them, both applied as live patches.
- Scroll sync:
  - Defect 1: at the first scroll away from the top, and on reaching the bottom, the preview jumped, because the ends were pinned separately from the line mapping. The mapping is now one continuous, monotonic function that reaches both ends together.
  - Defect 2: scrolling the preview did not move the editor. Sync now runs both ways; the pane the user scrolls leads.
  - The editor's scroll range is exact for texts up to 80,000 UTF-16 units (full layout before reading it).

### Verification

- `swift test`: 576 tests, 0 failures (core 240, app 336).
- New tests cover:
  - the expansion plan (room, no room on the left, screen too narrow, full screen, sidebar);
  - every animation frame keeping the reader width and right edge, in a real window and with the real showcase document;
  - toggling mid-animation and tab switches;
  - annotating and de-annotating a page in place with a Mermaid diagram kept;
  - the mapping being continuous and monotonic and reaching both ends;
  - preview scrolls reported to the editor and not echoed;
  - an end-to-end run where entering keeps the reader at its offset and each pane follows the other.
- Measurements are in ARCHITECTURE.md under "Editor pane and window".
- `swift test -c release` is not a usable check: about 30 tests fail there because bundled resources (style rules, KaTeX, Mermaid, gemoji) do not resolve in that configuration. Most of them predate edit mode, and two checked on a clean copy of commit `74b7ead` fail the same way. The edit-mode tests that do not need those resources pass in release. The documented check is the debug `swift test`.
- Not done: seeing it. Desktop access remained unavailable, so smoothness was judged from frame measurements and invariants, not by eye.
- Nothing is committed.

## Released (2026-11-09)

- The user tried the revised build and accepted it.
- Committed as `046fef5`, pushed to origin/main, and released as Wafer 2.0.0 (build 19). See `docs/logs/2026-11-09-wafer-2.0.0-release.md`.
- Still open: phase 3 polish (list continuation, formatting shortcuts, image paste).

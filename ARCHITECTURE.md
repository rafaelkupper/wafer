# Wafer Architecture

Wafer is a SwiftPM-based macOS document viewer for Markdown files. The app is split into a reusable rendering core and an AppKit app target that owns windows, editing, and presentation.

## Modules

- `WaferCore` owns Markdown parsing, semantic formatting, syntax highlighting, sidebar data, reader theme data, document statistics, asset resolution, and WebKit HTML generation.
- `WaferApp` owns the macOS application lifecycle, document windows, AppKit controllers, menu wiring, WebKit presentation, document opening, local asset loading, and user preferences.
- `WaferQuickLook` owns the Quick Look preview extension glue. It depends on `WaferCore` for static preview composition and keeps Finder preview presentation isolated in the extension target.
- `Tests/WaferCoreTests` and `Tests/WaferAppTests` cover the renderer, document model, UI controller behavior, and app integration seams that can run in unit tests.

## App Bundle

`scripts/build-app.sh` builds the SwiftPM executable product in debug or release mode, then assembles `build/Wafer.app` with:

- `App/Info.plist`
- `App/Wafer.entitlements`, the app's App Sandbox entitlements
- `App/container-migration.plist`, copied to `Contents/Resources` only with `--release-identity` (see [file access](#file-access))
- `App/QuickLook-Info.plist`
- `App/QuickLook.entitlements`
- `App/Resources/Wafer.icns`
- the Swift executable from `.build/<configuration>/Wafer` (copied to `Contents/MacOS/Wafer` to match `CFBundleExecutable`)
- the Quick Look extension executable from `.build/<configuration>/WaferQuickLook`
- exactly the SwiftPM resource bundles `Wafer_WaferCore.bundle` and `Wafer_WaferApp.bundle` (the appex gets only `Wafer_WaferCore.bundle`); a missing bundle fails assembly, and `scripts/verify-appex.sh` fails on any other bundle, so test-fixture bundles from the shared build directory never ship
- `Sparkle.framework` from `.build/<configuration>`, copied whole into `Contents/Frameworks`

The script signs the Quick Look extension and then the app ad hoc, each with its entitlements, so a local build runs in the App Sandbox exactly as a release does. Ad hoc signatures have no team identity, so the hardened runtime (whose library validation needs one) is added only by the Developer ID signing in `scripts/package-release.sh`. `scripts/verify-app.sh` checks the signature, the exact entitlement set, Sparkle's sandbox keys, and the bundled migration manifest.

Local and CI builds use `dev.wafer.app.dev`, omit the release migration manifest and update feed, and rewrite Sparkle's mach names to match. `package-release.sh` passes `--release-identity` to produce `dev.wafer.app` with the shipping manifest, feed and public key unchanged. The minimum macOS version is 14.0. The build uses one SwiftPM build invocation and one `--show-bin-path` query.
`CFBundleShortVersionString` follows a three-component marketing version format.
The build script copies SwiftPM resource bundles into `Contents/Resources`; `ReaderTheme` and the app-local `ReaderScriptResource` lookup check that packaged location before using SwiftPM `Bundle.module` in debug and test contexts. Release script lookup never evaluates the SwiftPM accessor when packaging is broken; it logs a resource fault instead.

The Quick Look extension is hand-assembled at `Contents/PlugIns/WaferQuickLook.appex`. Its bundle identifier is `dev.wafer.app.dev.quicklook` locally and `dev.wafer.app.quicklook` for distribution, its extension point is `com.apple.quicklook.preview`, and its principal class is the Objective-C-visible `PreviewProvider`. SwiftPM builds it as the `WaferQuickLook` executable product with the `_NSExtensionMain` linker entry point and links QuickLookUI explicitly because the repository does not use an Xcode appex target. The appex also receives `Wafer_WaferCore.bundle` in `Contents/Resources` so `Bundle.module` can resolve reader CSS and emoji data from inside the extension process. `build-app.sh` removes the Mermaid and KaTeX runtime files from the appex copy because Quick Look is scriptless, and `verify-appex.sh` checks they are absent while the needed resources are present. SwiftPM 6.4 and later emit resource bundles in the standard macOS layout (`Contents/Resources`), while earlier toolchains emitted them flat; runtime lookup goes through `Bundle` APIs and `scripts/verify-appex.sh` accepts either layout.

## Document Windows

`AppDelegate.sharedScrollStateStore` owns the persistent app-wide scroll store. `DocumentHostWindowController` receives that store and passes it to every tab document it creates, along with a snapshot provider for its injected library controller.

`DocumentWindowController` owns the AppKit document window shell and initial placement policy. Link clicks, anchor navigation, wiki-link resolution, relative document opening, and history pushes live in `MarkdownReaderDocument`; the window routes navigation accessory actions to that document. `DocumentHostWindowController` routes sidebar selections to the active tab or opens a new tab for modified clicks. New reader windows default to 1150 points wide and use the full `NSScreen.visibleFrame.height`, so the initial height fills the usable display area while respecting the macOS menu bar and any visible Dock. The width is capped only when the visible frame is narrower than the default, with the existing 520 x 360 minimum window size preserved.

`DocumentChromeViewController` animates the sidebar by animating constraint constants (`constraint.animator().constant`), so the reader is laid out at every step. An implicit frame animation would lay the web view out at its final width at once and only slide its layer, which makes the reader's scroll bar jump by the sidebar width. Exactly one content-leading constraint is active during transitions and at rest. A reversal finishes the previous target first, and generation checks discard stale animation completions.

`WindowChromeSuppression` owns optional AppKit decoration styling. It runs during window setup and showing, and on theme or appearance changes. Reader layout and navigation do not traverse window chrome. Private decoration matching is restricted to macOS 14, 15, 26, and 27; unknown systems keep the public transparent-titlebar settings. Traversal skips the document content subtree, and absent private views are left alone. `ReaderFindBarView` owns the reader's find controls and layout.

`DocumentStatisticsAccessoryViewController` uses a frame-sized accessory root with constraint-based contents. Updates change its preferred size and root size without forcing layout inside the titlebar's constraint pass. The stack's trailing constraint can yield during AppKit's temporary narrow sizing, while controls retain their intrinsic sizes.

`MarkdownDocumentOpener` and `DocumentHostWindowController.openTab` register and display a loading document before calling `MarkdownReaderDocument.loadInitialSource`. Initial opens, navigation, and reload use `MarkdownSourceLoader` for bounded reads, decoding, fingerprinting, reload-on-change decisions, and coalescing. Its `LoadState` (idle, opening, navigating, reloading) names the read in progress, and a load generation discards its completion after another request or close. Reads and save sessions share a disk-state revision. Before applying a read, the loader finishes any pending save and repeats the read if a completed write advanced that revision, so a stale reload cannot replace newer saved editor text. The loader holds the loaded file as one `LoadedMarkdownSource` value: text, `MarkdownTextFormat`, and the fingerprint of the bytes last loaded or saved. Failed initial opens remove the placeholder document or tab before presenting the error, including navigation that supersedes an opening placeholder. Unread placeholders do not enter history. Already registered pending documents are reused, and successful reads enter Open Recent.

The loader reads at most 32 MB (32,000,000 bytes) through `BoundedFileReader`. A larger file fails as a whole with a too-large error that names the limit, so nothing is rendered or edited in part; `read(from:ofType:)` applies the same limit.

Clicked links go through the document. Wiki links and links to Markdown files open in Wafer, and anchor IDs are taken from the clicked URL's fragment, percent-decoded (`MarkdownDocumentOpener.anchorID(in:)`), so `#café` reaches the heading `café`. Other targets go to `LinkTargetOpener`:

- External links open only for `http`, `https`, and `mailto`; other schemes are ignored.
- Known passive regular files open directly: images, PDF, audio, movies, RTF, explicit plain-text formats, and macro-free Office formats (`docx`, `xlsx`, `pptx`). The check resolves symlinks and rejects executable files. Types conforming to SVG, XML, HTML (including XHTML), or web archives require confirmation before either passive allowlist is considered, because they can carry active content. All other files, directories, and packages ask first, offering Show in Finder (the default), Open, or Cancel. HTML, disk images, projects, shortcuts, configuration profiles, notebooks, and unknown types require confirmation.

## Edit Mode

Edit mode is a per-document toggle (`MarkdownReaderDocument.toggleEditing`). `MarkdownEditCoordinator` holds its state: the editor, the save session, the autosave and live-render timers, and the scroll-sync alignment. The document keeps the file, the reader, and the window. The reader stays the window's hosted content; the document's `MarkdownSourceEditorViewController` is shown as an editor pane to its left (`DocumentWindowController.setEditorPane`). The tab host applies the pane of the selected tab, so tab switches show or hide it. With edit mode off, rendered output, export, Quick Look, and render goldens are unchanged; the only reader-script additions are the incremental Mermaid and KaTeX hooks and a copy-button observer, which stay idle. Export snapshots strip `data-source-line`, so exporting while editing produces the same HTML as reading.

### Editor pane and window

`DocumentContentSplitView` is the window's content area. It lays out the reader and the editor pane by setting frames, not constraints, so a transition can hold both layout widths fixed:

- `EditorPaneExpansion.plan` decides the open frame. The window grows to the left by the content width (the reader's width; a visible sidebar is not doubled), so the reader keeps its size and screen position. With less room it takes what the screen has, moving right only when the left edge runs out, and the panes share the result equally. A full-screen window does not resize and splits in place.
- During the transition the editor is laid out at its final width inside a clipping slot whose width follows the animation, and the window frame follows the same progress with the same rounding. When the window can double, the reader's width is identical in every frame, so WebKit never reflows it and the text view never rewraps.
- Closing reverses the remembered growth and right shift.
- `DisplayLinkedAnimation` drives it from the display's refresh (0.35 s, eased in and out along a half cosine, so it starts and ends at rest with a low peak speed). Each step sets final values once: pane width first, then the window frame, which triggers a single layout. A toggle or sidebar change during the animation finishes it first. Reduce Motion, hidden windows, and tab switches apply the end state at once.

Neither entering nor leaving reloads the page. Entering runs one render with source-line annotations and leaving one without, and both are applied as live patches (see below): every block keeps its DOM and only gains or loses its `data-source-line` attribute. The reader therefore keeps its scroll position, images, and rendered diagrams.

Measured on 2026-11-09 with `EditModeEndToEndTests.testPaneAnimationWithRealDocumentStaysCheapPerFrame` (`RenderingShowcase.md`, a 720-point window, 240 Hz display; three debug and three release runs). Its 50 ms slowest-step threshold runs only with `WAFER_PERF_TESTS=1`; the default suite keeps the width checks.

| | Result |
| --- | --- |
| Work before the first frame when opening (editor, coloring, text layout) | 19 to 39 ms |
| Work before the first frame when closing | 1 to 3 ms |
| Frames drawn in 0.35 s | 54 to 67 |
| Slowest step in a run | 5.2 to 9.1 ms |
| Reader width | identical in every frame |

A step is one `NSWindow.setFrame`. Resizing an empty window the same way takes 0.4 to 7 ms per step on this machine, so most of the step cost is the window resize itself, not Wafer's layout. One of six earlier runs, with a 0.3 s cubic curve, had a single 19.7 ms step.

### Saving

Saving does not use NSDocument autosave. `autosavesInPlace` stays false and `writableTypes` stays empty. NSDocument autosave tracks one file and its modification date per document, which conflicts with in-place navigation, and tab close bypasses `canClose`. Instead, `MarkdownEditSession` owns the saved text (LF-normalized), the fingerprint of the bytes last loaded or saved, the file's `MarkdownTextFormat` (encoding, byte-order mark, dominant line ending), the baseline text used by Revert Edits, and the editor revision whose text is saved.

The editor keeps its text LF-only: pasted, dropped, or inserted CR and CRLF become LF as one undo step, with the insertion point after the text. It counts revisions; every change to its text increases the count, so checking for unsaved text compares two integers instead of two texts.

When the save runs:

- Autosave is a 1 s debounce after the last edit. It saves in the background (below); if that finds a conflict, an interactive save asks on the main actor.
- App deactivation saves in the background without prompting.
- `Cmd-S`, leaving edit mode, `Cmd-R`, tab close, window close (`DocumentWindow.performClose` and `prepareToCloseWindow`), and quit (`applicationShouldTerminate`) save interactively and resume from a completion after the write, without waiting on the main thread. Cancel keeps unsaved text in the editor and cancels the action.
- Navigation saves before it reads the next file, and again before the editor switches to it, because the editor stays editable while the file is read. If that second save fails or is cancelled, the navigation is abandoned and the current file, text, and history stay.
- `close()` also defers teardown until an interactive flush completes; cancellation keeps the document open. Repeated close requests share one flush. Tab and window close hooks continue only after their flush succeeds. Quit returns `.terminateLater`, then calls `reply(toApplicationShouldTerminate:)` once all editors are settled; another quit request joins that operation, including when a close is already saving.

How the write is made:

1. The main thread copies the editor text and its revision (a snapshot). The file I/O runs on `MarkdownSaveWorker`, one serial queue per document, so saves never overlap. A flush asynchronously waits for earlier writes and their bookkeeping, then saves newer editor text until no unsaved revision remains. Repeated flush requests coalesce and receive their completions together. Results and conflict prompts are handled on the main actor; overwrite and Save a Copy writes also run on the worker. A background save requested while one runs starts when it finishes. A window close or quit rechecks earlier documents after flushing later ones, since editors remain usable during the writes.
2. Unchanged text writes nothing. Before staging a save or writing a copy, the save path checks the encoded byte count against the same 32,000,000-byte limit used for opening, including byte-order marks, UTF-16, and restored CRLF line endings. An oversized save leaves the original and unsaved editor text intact and asks the user to shorten the document.
3. The encoded bytes are written to an item-replacement directory. Immediately before they replace the file, the worker reads and hashes the file on disk through `BoundedFileReader`, with the same 32 MB limit as opening. An oversized disk version is a changed-on-disk conflict without retaining its bytes. A mismatch with the last loaded or saved fingerprint is a conflict, and so are a missing file and a read or write failure. The file's identity, size, and modification time are compared before and after that read, so a write that lands while it is hashed is caught too; only the moment between that check and the swap remains. NSFileCoordinator is not used, because most programs that write these files (editors, agents) do not coordinate.
4. `FileManager.replaceItemAt` swaps the new file in, keeping permissions and creation date. Symlinks are resolved first. There is no in-place fallback: when the replacement fails, the original is left as it was (and moved back if the failed swap moved it aside), and the error reaches the prompt as a write failure.
5. Conflicts go to an injectable resolver. The default is an app-modal alert offering Keep My Edits, Use Disk Version, or Save a Copy… (for a write failure: Save a Copy…, Discard My Edits, or Cancel). The writer is injectable too, for tests. If text was typed while the conflicting write ran, Use Disk Version and Save a Copy… show the disk version with the newer text one Undo away ("Undo Use Disk Version"), and the action that asked for the save (navigation, close, quit) stops so that history survives.

Measured on 2026-11-13 with `EditSavePerformanceTests` (`WAFER_PERF_TESTS=1`; a 5 MB document, ten autosaves per run, two debug runs and one release run), as the longest main-thread turn per keystroke-triggered autosave:

| Build | Before (save on the main thread) | After (save on the worker) |
| --- | ---: | ---: |
| Debug | 19.8 and 20.0 ms median, 22.6 to 38.3 ms max | 3.6 ms median, 4.6 to 14.1 ms max |
| Release | 19.5 ms median, 99.2 ms max | 4.2 ms median, 8.0 ms max |

The main thread still copies the text for the snapshot and applies the result. These historical measurements predate asynchronous interactive flushes (2026-11-14). Interactive saves and reload delivery no longer synchronously drain the worker. A reload waits through a completion for save bookkeeping, then checks the captured disk revision and repeats a read made stale by a save. Deterministic blocked-writer tests cover this ordering and main-actor responsiveness; no new throughput or latency measurements were made.

The file monitor stays active while editing:

- If there are no unsaved edits, a changed file is adopted into the editor (selection kept, undo cleared).
- Otherwise the change triggers an interactive save, which reports the conflict.

The editor has a private `UndoManager` (via `undoManager(for:)`), so typing never marks the NSDocument edited.

### Editor coloring

`MarkdownSourceHighlighter` in WaferCore is AppKit-free and covered by unit tests. It works in two passes:

- `structure(of:)` makes one linear pass over UTF-16 code units. It finds line starts, front matter (same rules as `MarkdownParser`), and fenced code blocks; an unclosed fence runs to the end of the text.
- `tokens(in:structure:lines:)` emits line tokens (headings, quotes, lists and tasks, rules, tables, reference definitions) and inline tokens (strong, emphasis, strike, highlight, HTML, links, autolinks, wiki links, footnotes, escapes, code spans last). Fenced code content is colored with `CodeSyntaxHighlighter.presentationRuns` over the whole block.

How the editor recolors after each user edit (TextKit 1 with non-contiguous layout):

1. It rescans the structure.
2. It predicts the block list from the previous one: blocks after the edit shift, and the block containing it grows or shrinks.
3. It recolors only the edited lines, widened to any enclosing fence. When the prediction fails, for example when a fence opened or closed, it recolors from the first differing block to the end.

Colors come from `MarkdownEditorColors(palette:)`, so built-in and custom themes apply without new theme fields.

Measured on 2026-11-09 with `MarkdownSourceEditorTests.testLargeDocumentHighlightAndEditStayFast`, two release and three debug runs on a 159,000-character document with 1,500 fenced blocks. Its 0.25 s keystroke threshold runs only with `WAFER_PERF_TESTS=1`; the default suite checks that the edit lands and keeps its coloring.

| Build | Full coloring on load | One keystroke |
| --- | ---: | ---: |
| Release | 97 to 127 ms | 8 to 10 ms |
| Debug | 137 to 140 ms | 23 ms |

The keystroke cost scales with document length because of the linear structure scan; ordinary notes are far smaller.

### Live preview

Edit-mode renders set `WebKitHTMLRenderer(annotatesSourceLines: true)`. The document passes the flag with each render request, so the render worker keeps no edit-mode state:

- Top-level blocks, list items, and table body rows get `data-source-line`.
- Lines are mapped back through `MarkdownDocument.sourceLineMap`, which accounts for stripped front matter and extracted multi-line footnote definitions. Footnote content is never annotated.

Every reader render carries `bodyHTML` and whether Mermaid or math is present, so a page loaded for reading can later be patched.

Typing requests a render every 100 ms while the worker is available. If a render is still running, it finishes and reaches the preview before the newest pending text starts. Intermediate requests coalesce, so continuous typing cannot starve the preview. Navigation and explicit refreshes still supersede older renders. They push statistics and the sidebar only when those changed.

`ReaderScriptResource` first loads app scripts from `Contents/Resources/Wafer_WaferApp.bundle`, then lazily uses `Bundle.module` in debug and tests. This small app-local lookup mirrors `ReaderTheme.resourceURL` without changing WaferCore. Static properties cache each source once. Missing or unreadable scripts log a fault through `WaferLog.resources` and return an empty source. Without the scroll script, reading and navigation completion continue but scroll reporting, active-heading tracking, and script-provided controls are unavailable. Without the live-preview installer, edit updates fall back to full renders that preserve the last known scroll fraction, and scroll sync is disabled. `ReaderLivePreviewScript` keeps the live-preview installer in `reader-live-preview.js`; `reader-scroll.js` holds the reader instrumentation. The former remains in the page world and installs lazily on the first live-preview call. The latter runs in the named reader content world after navigation finishes, as before.

`WebKitReaderViewController.applyLiveUpdate` runs `ReaderLivePreviewScript` in the page world. It patches `#write` in place:

1. Top-level nodes are keyed by their rendered HTML with line attributes stripped. Keys come from the HTML as rendered, not from the live DOM, so Mermaid SVG, KaTeX output, and copy buttons do not affect matching.
2. The diff keeps the common prefix and suffix. Inside the changed middle, any old node whose key still appears is reused.
3. Kept nodes get their line attributes updated. When the set of annotated elements differs (the render that starts or ends edit mode), elements are paired by tag and position and attributes are added or removed. Only new nodes are inserted.
4. New Mermaid figures and math blocks render through `window.waferRenderMermaidFigures` and `window.waferRenderMathBlocks`. These are incremental hooks in the bootstraps; theme re-renders re-query figures, so added diagrams follow theme changes.
5. A content-world MutationObserver adds copy buttons to new code blocks.

The reader falls back to a full load that keeps the scroll position when:

- the page is not ready;
- the page lacks a renderer the new content needs (the first diagram or math block);
- the DOM no longer matches the recorded state.

### Scroll sync

Both panes are aligned by the source line at their top, and either can lead.

The editor describes its position as an `EditorScrollPosition`: the fractional source line at the top, the lines at the top when scrolled all the way up and all the way down (its scroll range), how many lines are visible, and the line count. Texts up to 80,000 UTF-16 units are fully laid out before the position is read, so the range is exact; this costs about 0.4 ms per 1,000 units, once per text or width change. Longer texts use TextKit's estimate until background layout catches up.

The isolated reader script builds one mapping from editor line to preview offset for that geometry:

1. Annotated elements are cached as sorted `(line, top)` pairs with non-decreasing tops. A line's raw offset is interpolated between the pairs around it.
2. The editor's first and last scroll positions map to offset 0 and the preview's scroll limit. The difference between those and the raw offsets is blended in with a smoothstep over about one screen of lines at each end.
3. The result is continuous and monotonic, so its inverse (a bisection) maps a preview offset back to a line.

Who leads:

- Editor scrolls (reported once per run-loop turn, skipping notifications that change nothing) call `scrollToLine`; at most one call is in flight.
- Preview scrolls are detected in the page. A scroll event at the offset the script last set is its own; anything else (wheel, scroll bar, keyboard, anchor link, outline jump) is inverted to a line and posted to `waferLiveScroll`, and the editor scrolls there without reporting back.
- After a patch, an image load, a `details` toggle, a size change, or async diagram rendering, the script realigns: the preview moves to the editor's line, unless the preview was scrolled in the last 250 ms, in which case the editor follows.
- After a live patch completes in the page world, the app realigns the isolated scroll mapping with the editor position. A mutation observer invalidates that mapping when page-world patches change blocks or source-line attributes.

Entering edit mode never moves the reader. The editor is first placed by the reader's scroll fraction, then `lineAtTop` returns the exact line for the preview's current offset and the page adopts that as the synced position. Until that answer arrives neither pane follows the other.

## Folder Library

The folder library is split between reusable indexing/search code in `WaferCore` and AppKit orchestration in `WaferApp`.

`LibraryScanner` walks a selected directory off the main thread, collecting markdown files with extensions `.md`, `.markdown`, `.mdown`, and `.mkd`. It skips hidden files, symbolic links, and generated/heavy directories named `.git`, `.build`, `build`, `dist`, and `node_modules`, and it caps scans at 2,000 markdown files so large trees stay responsive.

Reads use `BoundedFileReader` with a 2 MiB per-file limit and a 128 MiB aggregate source-byte allowance (2,000 files averaging 64 KiB), including reused entries. Oversized files are skipped and counted alongside unreadable items. Existing entries are retained on read failures; a retained snapshot can exceed a newly lowered byte allowance, and exhausted allowances prevent new body text from entering the index. Each file retains one whitespace-collapsed plain-text body for readable snippets. The public `searchableText` property derives folded text for accent-insensitive matching; a full-text query folds once per candidate file and releases that temporary body after matching and scoring. Search fields retain only metadata, not body text or a dictionary of body words. The original initializer remains source-compatible, but derives search text from `plainText` rather than retaining the supplied `searchableText`; new callers can omit that argument.

Each `LibraryFile` stores normalized identity and relative path, display title, outline items, plain text, prepared search fields, outgoing references, and a fingerprint containing modification date, size, device/inode identity, status-change date and content digest. Every refresh enumerates the tree, including recovery scans after directory or dropped events and File > Retry Library. Except for File > Retry Library, which rereads every file because some volumes keep timestamps too coarse to reveal an edit, a single `stat` metadata check reuses unchanged parsed entries without reading their bodies; new files, replacements and changed metadata are read and parsed. Status-change time also catches writes that restore modification time. Explicit changed-file events force a reread even when metadata matches. Metadata is checked again after parsing; a file changed during the read is marked for rereading on the next scan. `Result.parsedFileCount` makes actual parsing observable in tests and benchmarks. A content change means a different modification date, size or digest; a metadata-only change such as a Finder tag updates the stored fingerprint without announcing a content change.

The scanner reuses the same document semantics as the reader sidebar: `DocumentSidebarDataBuilder` provides title and outline extraction, and `FileIdentity` centralizes normalized path identity for the library, linked-document sidebar, and `MarkdownDocumentOpener`. This avoids separate slugging or file-identity rules between library search, current-window navigation, and open-window reuse.

`LibrarySearch` owns ranking for both library entry points. Quick Open fuzzy-matches filename and relative path subsequences, ranks tighter and boundary-aligned matches higher, and returns at most 50 files. Full-text search tokenizes the query, searches filename, relative path, title, headings, and body text, ranks filename/path/title/heading/body hits in that order, and returns snippets plus an optional matched heading anchor.

`LibraryController` owns app-level library state. Its directory check is shared by library selection and the app's incoming-URL routing. It persists the selected folder through `LibraryPreferenceStore` and allows one active scan plus one pending refresh, with cancellation checkpoints between files. It computes the diff and complete `LibrarySnapshot`, including backlinks and a shared wiki index, off the main thread. Publication only swaps the immutable snapshot. `LibraryChange` travels as one typed value in each `.libraryDidChange` notification. `LibraryChange.value(from:)` extracts the scanning, content, availability, and diff state without reconstructing individual fields.

`DirectoryChangeMonitor` gives FSEvents a retained weak box, so a stream cannot dereference a released monitor even if its owner omits `stop()`. It retains FSEvents file paths and filters excluded directories and unrelated files. `LibraryController` debounces relevant changes for 500 ms after the last event. Continuous changes trigger a rescan request at most two seconds after the first pending event. An active scan finishes and publishes before one coalesced follow-up starts. Dirty paths accumulate separately from the active scan's captured paths, and a full-rescan request promotes the follow-up to a recovery walk. Publishing preserves events still inside the debounce window. Closing or selecting a library advances the generation and cancels the old scan, whose results are discarded before starting any replacement. Tests inject fake monitors, gated scanner closures, and a monotonic clock and scheduler to verify the deadline and publication under continuous writes without sleeps.

`LibraryScanner.Result.failure` reports root enumeration failures separately from a successful empty scan. A failure below the root keeps the previous entries for that file or subtree, or skips it if no prior entry exists, while readable siblings continue to update. `Result.skippedItemCount` counts unreadable and oversized items for future UI reporting. Root failures retain the previous complete snapshot and dirty paths. `scanFailure` publishes availability separately from content; the sidebar labels stale results without rebuilding the tree on ordinary scanning-status updates. Persisted folders remain selected when unavailable. File > Retry Library forces a recovery scan and restarts the monitor; Close Library explicitly clears the preference. Successful recovery clears the warning, and successful deletions still update the snapshot normally.

`DocumentHostWindowController` selects the app library at the window composition root and injects it through `DocumentWindowController` and `DocumentChromeViewController` into `DocumentSidebarViewController`. Window command validation and sidebar data use that same controller. Standalone window, chrome, and sidebar controllers default to an empty local library. `DocumentSidebarViewController` adds a window-local `Library` mode with a collapsible tree keyed by relative folder path, a pinned search field, result rows, no-results state, current-file highlighting by normalized URL, and theme reapplication through the existing `ThemeApplying` walk. Search snapshots are value-copied and evaluated off the main thread; result activation routes through `DocumentWindowController` to `MarkdownReaderDocument.navigateInCurrentWindow(to:anchorID:)`, reusing the existing pending-anchor render completion path. `QuickOpenPanelController` is built lazily from the File menu and reads the same library files without doing work at app launch.

The sidebar uses one reusable `NSTableView` for all modes. Its row models, cells, tree builder, and row views live in `SidebarRowViews.swift`; the controller owns selection and data updates. Folder expansion determines a flat row model, but AppKit realizes only the viewport's rows. Stable identities allow updates to existing rows without rebuilding the constraint graph. Scanning-status notifications do not rebuild content. Both search entry points use a serial `LatestWorkQueue` with a 60 ms debounce and cooperative cancellation. Filename/path fuzzy characters and folded metadata fields are prepared during indexing; ranking counts substring occurrences directly in the folded body instead of walking a dictionary of unique words; the sidebar generates snippets only for realized results.

`LibraryInitialDocumentOpener` bridges the app-level library state to the document UI without doing its own filesystem walk. `LibraryController.openLibrary(at:onFirstScanCompletion:)` pairs a one-shot hook with the background scan generation started by the folder open; when that scan completes, the opener checks whether a markdown window is still absent and opens the first scanned `LibraryFile` through `MarkdownDocumentOpener`.

## Preferences

The preference stores persist values in `UserDefaults` and post their existing NotificationCenter names only when values change. `AppearancePreferenceChange`, `DocumentStatisticPreferenceChange`, `LibraryPreferenceChange`, and `ReaderBehaviorPreferenceChange` own the payload keys and expose `value(from:)` to observers. The legacy keys remain available for integration with existing observers. Reader behavior changes distinguish automatic reload from remote image loading, and clearing the library folder produces a typed change with a nil URL.

`AppearancePreferenceStore` is main-actor isolated, including theme application and native alerts, and needs no unchecked Sendable conformance. The other preference stores hold only immutable references to thread-safe `UserDefaults` and `NotificationCenter`; their unchecked Sendable conformances document that reason. They retain their nonisolated API for callers outside the main actor.

## Reader Rendering

`WaferLimits` documents Core's byte budgets and scan file-count cap. Document and asset constants are also public for app callers; existing `PreviewComposer` limit properties remain aliases. `ScrollStateStore` construction does not enumerate preferences. The existing app-launch `pruneEntries(olderThan:)` also removes all v1 entries; `pruneLegacyEntries()` supports migration without age pruning. Both preserve unrelated keys.

`MarkdownSourceDecoding` is the single Markdown byte-decoding path for the app reader sidebar, library indexer, and Quick Look composer. It accepts UTF-8 and UTF-16 with a BOM or a strong alternating zero-byte pattern so in-app indexing and Finder previews agree on which documents are readable.

The renderer has a narrow dialect-compatibility layer around swift-markdown rather than a forked parser. `MarkdownParser` strips valid YAML front matter before AST construction and carries the metadata on `MarkdownDocument`; it also extracts GitHub-style footnote definitions with a fenced-code-aware block scanner after front matter is removed. Footnote references are resolved at render time from text nodes so inline code and fenced code stay literal. `WebKitHTMLRenderVisitor.visitText` autolinks bare URLs and email addresses while staying disabled inside existing links and code nodes, then decorates plain text segments with Gemoji-derived Unicode shortcodes and same-node `==highlight==` pairs. GitHub alert blockquotes are detected in `MarkdownSemanticFormatting` and rendered through the same callout path as directive callouts, while sidebar preview and plain-text extraction strip the alert marker. These compatibility features are expected to hold across the reader, standalone export, and Quick Look preview whenever the feature does not require JavaScript.

Footnotes are document-scoped sidecar data, not swift-markdown AST nodes. Each render visitor builds its known-label set once and reuses it for text and headings. The reader and Quick Look append a static `<section class="md-footnotes">` after the rendered body once a known reference is encountered; export keeps that section as ordinary sanitized HTML. Sidebar titles, outline slug input, library indexing, and statistics use document-aware stripping so known references do not leak into headings or search snippets, while the referenced definition text is indexed and counted once. References without definitions remain literal.

Emoji shortcodes use the bundled `gemoji-shortcodes.json` resource generated from GitHub's MIT-licensed Gemoji aliases, with `gemoji-LICENSE.txt` shipped beside it. Replacement is intentionally renderer-only: known `:shortcode:` values become Unicode emoji in reader, Quick Look, and export, unknown shortcodes stay literal, and library/sidebar/search text keeps the raw Markdown source. Highlight rendering is similarly local to text nodes; it does not pair markers across Markdown node boundaries and leaves unmatched or triple-equals text literal.

`DocumentRenderCoordinator` owns each document's render generation, active work item, pending live request, and completed page palette. Full renders supersede active work. Typing lets the active render finish, then snapshots only the newest text and edit-mode annotation flag. The document supplies source snapshots and applies output to its reader and window chrome. Theme changes compare against the completed page palette after reader readiness, so an older render cannot leave the arriving page on an old theme. Live patches retain the page palette.

Each coordinator owns a serial render worker retaining only its last parsed source and source-derived metadata. Wiki-index changes reuse that parse. The first reader render includes filename placeholders for linked notes and performs no linked-file reads. Visible Documents rows request summaries through a shared 256-entry cache or reuse the library snapshot. Summaries read at most the first 256 KiB of each linked note; initial row order stays stable while titles arrive. Preview rendering omits reader statistics and sidebar metadata.

Empty files follow the normal render path. Source loads, render completions, WebKit navigation completion, and scripted-renderer readiness are generation checked. Pending anchors are consumed only after renderable content is ready, never by a loading placeholder. WebKit message handlers hold weak reader references; production document close cancels rendering and shuts down the reader. The remote-image session owns a separate delegate with no reference back to its fetcher, allowing fetcher teardown to invalidate the session.

`WebKitReaderViewController` owns the WebKit surface and bridges platform callbacks to three smaller types:

- `ReaderNavigationState` owns load UUIDs, one-use load authorization, same-document fragment policy, navigation and renderer readiness, and pending theme-update identity. WebKit navigation object identity stays in the controller.
- `ReaderFindController` owns `ReaderFindBarView`, query normalization, search direction and status, selection clearing, and find commands. Its injected find and JavaScript calls keep tests independent of a WebKit view.
- `ReaderLivePreviewController` owns the current body HTML, helper and patch-baseline flags, available renderers, patch-or-reload decisions, and active and pending scroll-sync requests. An injected script executor preserves the page and isolated reader content worlds. Full page loads reset its generation, so old patches cannot apply to a new page.

Existing DEBUG test hooks on the document and reader remain available. Coordinator tests use controlled snapshots and completions without WebKit or sleeps; existing reader integration tests still exercise WebKit.

`WebKitHTMLRenderer` emits the complete reader document, including the bundled CSS from `reader-theme.css`. `WebKitRendererScripts.swift` owns script/CSP assembly and cached KaTeX CSS; `WebKitAssets.swift` owns custom asset URLs and preview attachment collection. Fenced code blocks continue through the native Swift syntax highlighter unless the fence language is `mermaid`, `mmd`, or `math`.
`CodeSyntaxHighlighter` uses one token-kind enum for rules and presentation runs and keeps compiled syntax regexes in a static cache keyed by options and pattern. It, `DocumentSummaryCache`, and `WorkCancellation` use `OSAllocatedUnfairLock` with typed state and checked `Sendable` conformance, including on macOS 14. It intentionally uses shallow semantic regex rule sets; the goal is readable fenced-code coloring for common README languages, not full compiler-grade tokenization.

Rendered headings keep Wafer's existing primary IDs for outline selection, search navigation, and scroll restoration. When a GitHub-compatible slug differs from the primary ID, the renderer inserts an empty `md-anchor-alias` anchor inside the heading so GitHub-authored fragment links still resolve. Alias generation reserves the complete primary heading ID set before emission, so aliases never duplicate current or later primary IDs; reader scroll tracking queries heading elements only and ignores alias anchors.

`AssetResolver` decodes local URL path and fragment escapes once, preserving literal plus signs. Percent-encoded traversal is standardized before the existing asset-root checks; a literal percent escape in a filename must itself be encoded. Local file assets referenced by rendered HTML are served through the custom `wafer-local://asset` scheme. The scheme handler only serves files inside the current document directory or the bundled WaferCore resource directory. `FileContainment` in WaferCore standardizes and resolves symlinks, snapshots each root's volume case sensitivity, and compares path components. The library scanner, preview attachment collector and `LocalAssetLoader` share it. Preview compositions capture attachment-parent roots and recheck containment before inlining, rejecting symlink escapes introduced after composition. It opens the resolved path once with `O_NOFOLLOW`, verifies the opened regular file's path with `F_GETPATH` against those roots, and reads bounded bytes from that same descriptor. A parent-directory symlink swap between the first check and open cannot redirect the read outside the allowed roots. Absolute image paths and `..` traversals that escape the document directory are intentionally rejected and render as failed asset requests. `WebKitLocalAssetSchemeHandler` uses that descriptor-based reader with a 25 MiB per-file limit. A shared operation queue allows two reads at a time across windows. Stopping a scheme task cancels its pending operation; a descriptor read already in progress may finish, but its result is discarded. Oversized assets fail without delivering partial bytes.

Remote images referenced by Markdown or sanitized raw HTML are never emitted as bare `https://` image sources. `AssetResolver` accepts only `https` remote image URLs, and `WebKitHTMLRenderer` rewrites them to `wafer-remote://image?url=...`. `RemoteImageURL` parses that proxy URL for both reader fetches and export inlining. `RemoteImageSchemeHandler` performs the fetch through an ephemeral `URLSession` with no cookie storage, no credential storage, no persistent cache, a 15-second timeout, and a Wafer user agent carrying the app bundle marketing version (`unknown` when absent). The handler rejects non-HTTPS URLs and redirects, non-image MIME types, and responses over 25 MB by content length or accumulated bytes. It also cancels and suppresses task callbacks after WebKit stops a scheme task.

`RemoteAssetURLGuard` is shared by the URLSession fetcher used for reader images and export assets. It allows only HTTPS URLs, including redirects, and rejects non-public special-purpose addresses from the [IANA IPv4](https://www.iana.org/assignments/iana-ipv4-special-registry/) and [IPv6](https://www.iana.org/assignments/iana-ipv6-special-registry/) registries, including documentation, benchmarking, discard-only, dummy and deprecated relay ranges. The entire IPv4 protocol-assignment block `192.0.0.0/24` is blocked, including its anycast exceptions. Before a request resumes, it resolves host names with `getaddrinfo` on one shared operation queue with at most two workers and rejects the request if any returned address is loopback, RFC 1918 private, IPv6 ULA, link-local, CGNAT, unspecified, multicast, or IPv4 reserved high space. Literal IPv4, IPv6 and IPv4-mapped IPv6 addresses receive the same checks. The well-known NAT64 /96 prefix and 6to4 addresses reuse the IPv4 check for their embedded destination. Teredo checks both its server and decoded client IPv4. The local-use NAT64 /48 prefix is rejected outright because the site controls its embedded-address layout. Resolution failure rejects the request. `willPerformHTTPRedirection` queues the same validation for every hop and completes asynchronously, so DNS never blocks the serial URLSession delegate queue. The inliner only consumes prefetched remote bytes and performs no network requests.

The guard does not pin the resolved address to the connection. A DNS rebind between validation and URLSession's connection lookup remains a residual risk. Remote-image loading is still an opt-out network feature, not an isolation boundary against that race.

Remote image loading is controlled by `ReaderBehaviorPreferenceStore.loadsRemoteImages`, defaulting to true. The checkable File > Load Remote Images item toggles the preference and shows its current state. The scheme handler reads the preference at fetch time, so disabling it applies to subsequent loads and a manual Cmd-R reload applies the choice to already-rendered documents.

Raw HTML is sanitized by `HTMLSanitizer` before rendering. The reader column uses `<main id="write">`, and `main` is outside the raw HTML allowlist, so browser repair of raw elements across Markdown containers cannot close the column. Deterministic seeded tests check sanitizer output and reader/preview DOMs with WebKit's HTML parser. The sanitizer is a token-level streaming filter rather than a per-fragment tree parser so cross-block Markdown patterns like `<details><summary>Click</summary>` followed by Markdown content and a later `</details>` keep working. Tags and attributes are allowlisted; unsafe tags, event handlers, inline styles, classes, IDs, `data-*` attributes, unsafe URL schemes, `data:` images, and raw-text payloads such as scripts/styles/iframes are dropped or unwrapped safely. Raw HTML images reuse the same local and remote proxy paths as Markdown images. The allowlist includes the GitHub-compatible structural subset used by common README content, including lists, headings, blockquotes, figure/figcaption, captions, definition lists, small/u/q/cite/time/wbr, and `picture/source` image candidates. `source srcset` URLs are resolved through the same image policy as `img src`; unresolved candidates are removed and empty `source` elements are dropped. Quick Look preview strips `source` elements and keeps the fallback `img`, while reader WebKit keeps valid `source` candidates so `prefers-color-scheme` media queries follow the active reader theme appearance.

Render compatibility changes use a standing reader/export/preview triangle. Reader HTML is the primary WebKit output, export starts from that DOM and must not strip newly supported markup, and `.preview` mode must remain scriptless with `cid:` local images and no remote fetches. Fixture goldens are used only for deterministic output: reader/preview corpus hashes normalize local fixture paths, the reader golden excludes Mermaid and path-dependent images, and any intentional golden drift must be committed with an explanation of the behavior that changed.

Mermaid diagrams render offline inside WebKit using the full bundled `mermaid.min.js` resource from Mermaid 11.14.0. The renderer emits stable diagram containers and a single bootstrap script per document; the bootstrap configures Mermaid with strict security, Wafer theme colors, Gantt/ER dark-mode variables, and no network dependency. Reader CSS also scopes SVG overrides under `.md-mermaid-output` for Mermaid classes whose generated styles otherwise wash out text on the dark reader background, including ER table rows emitted as `row-rect-odd` and `row-rect-even` paths. Invalid Mermaid source stays visible with a quiet inline error instead of replacing the block with a blank area.

Rendered Mermaid diagrams also expose an explicit `Open` control in the figure corner. The diagram body itself is passive reader content; only the control opens the shared in-reader diagram inspector. The inspector is implemented in the bundled Mermaid bootstrap script, clones the already-rendered SVG, rewrites cloned SVG IDs to avoid collisions, captures wheel and trackpad gestures while open, and provides pan, zoom, fit, reset, copy SVG, and close actions without network access.

Math fences render offline inside WebKit using bundled KaTeX 0.17.0 runtime assets from the WaferCore resource bundle. The renderer emits `md-math-display` figures only for `math` fenced blocks in reader mode; preview mode keeps the same source as a highlighted code fence so Quick Look remains scriptless. KaTeX CSS is loaded and rewritten once per process, only when a math fence is present, and its bundled `fonts/...` URLs are rewritten to `wafer-local://asset` URLs that resolve inside the app and Quick Look resource bundle. KaTeX uses `displayMode: true` and `throwOnError: false`, so invalid TeX stays visible as red source text instead of becoming a blank block. Inline `$...$` math is intentionally not parsed.

Because Mermaid SVG generation and KaTeX rendering can change document height after WebKit finishes navigation, documents with either renderer set `waitsForContentReady` on `WebKitRenderOutput`. `WebKitHTMLRenderer` emits one shared page-world readiness coordinator when scripted renderers are present, and `WebKitReaderViewController` waits for the resulting `waferContentReady` script message before restoring scroll position, consuming pending anchor navigation, or allowing export snapshots.
The injected reader scroll script still clamps page-level horizontal rubber-band scrolling, but it lets horizontally scrollable inner elements handle horizontal wheel gestures natively.

Theme changes replace a palette stylesheet in the current DOM and rerender only Mermaid figures through the page's existing renderer. Ordinary Markdown, images, KaTeX, and scroll state remain in place. The render coordinator records a full render's palette at completion, then the document asks it to compare with the current theme after navigation finishes. A theme change during rendering therefore patches the arriving page too. Live body patches preserve the current page's palette. Tabs compare their rendered palette on activation, so inactive tabs catch up without reparsing. Export waits for a pending diagram theme update. The scroll bridge coalesces its animation-frame and timer callbacks, caches heading offsets, and uses binary search during scrolling. Resize, DOM changes, image loads, details toggles, and font readiness invalidate the offsets.

## Export Pipeline

Print and PDF export use the visible `WKWebView` from the active document window. `DocumentExportController`
builds a shared `NSPrintOperation` with 36-point margins, fit-to-width horizontal pagination, automatic
vertical pagination, and WebKit's modal print operation path. Print shows the system panel; PDF export
sets `NSPrintInfo.jobDisposition` to save with the user-selected URL and hides the print panels. Both
paths are enabled only after the reader has finished navigation and any scripted-renderer `waferContentReady`
signal has arrived.

Standalone HTML export also starts from the visible reader. `WebKitReaderViewController` snapshots
`document.documentElement.outerHTML` only when the same export-readiness gate is satisfied, then
`ExportSanitizer` rewrites the document for offline use. It removes scripts, strips nodes marked with
the shared `data-wafer-chrome` export-chrome contract, rewrites the CSP to `default-src 'none'; img-src
data:; style-src 'unsafe-inline'`, removes remaining `wafer-*` scheme attributes, preserves already
rendered Mermaid SVG and KaTeX HTML, and ensures a doctype. KaTeX font files are not inlined in exported
HTML, so exported math can fall back to system fonts outside Wafer. `ExportAssetInliner` turns allowed local images into
`data:` URIs through `LocalAssetLoader`, so symlink and root-directory validation is identical to the
live WebKit local-asset scheme. Remote image export is lookup-only inside the sanitizer; the controller
prefetches `https` images asynchronously when File > Load Remote Images is enabled, uses a 10-second
request timeout, omits unavailable images, rejects byte-budget overflow, and writes the final HTML atomically.
`source srcset` candidates are discovered, prefetched, and inlined through the same path as `img src`;
if any candidate in a `source` element cannot be inlined, that `source` is dropped so exported HTML
never contains unresolved `wafer-*` image URLs. The total raw inlined image payload is capped at 20 MB.

The HTML export controller keeps UI-facing state on the main actor, but the heavy sanitize, inline, and atomic-write stage runs in a detached utility-priority task. The inliner is created inside that background task so its mutable state never crosses actor boundaries, and completion hops back to the main actor only to clear the re-entry guard or present errors.

Document construction requires explicit `ScrollStateStore` and library snapshot provider dependencies. Production code shares one persistent scroll store, `AppDelegate.sharedScrollStateStore`, across document opens and host-created tabs, and `MarkdownDocumentOpener` supplies the production snapshot provider; the NSDocument construction path passes those dependencies explicitly too. Tests pass an empty snapshot helper or a test-owned library and get preferences from the shared `makeTestUserDefaults` helper, including nested document factories. The helper keeps values in a thread-safe, in-memory `UserDefaults` subclass because cfprefsd can recreate deleted suite files after cleanup. Test teardown clears the values and checks that the generated suite never reached disk.

Reader scroll positions are persisted by `ScrollStateStore` with one key per document path; the fingerprint is stored in the entry and must match on load. Saving another version replaces that entry. Initialization prunes legacy fingerprint-keyed entries, so launch-time age pruning needs no app change. Scroll updates use a trailing debounce in `MarkdownReaderDocument`, flush immediately when a document closes or navigates in the current window, and prune entries older than 180 days once per app launch.

Live reload starts at the document's `FileChangeMonitor` seam and runs through `MarkdownSourceLoader`. `FileChangeMonitor` watches the open file with a kqueue-backed `DispatchSourceFileSystemObject`, debounces write bursts for 250 ms with a 1-second maximum delivery delay during sustained writes, and re-arms by path after rename/delete events so atomic saves continue to be observed. While the path is missing, one-shot retries back off from 0.5 seconds to a 5-second cap; reappearance restores the base delay, and teardown cancels the watch. Automatic reload fingerprints bytes before rendering, so metadata-only changes and re-arm false positives do not refresh the reader. Explicit Cmd-R renders even with an unchanged fingerprint, retrying assets and applying the remote-image preference while reusing the cached parse. Both preserve the live scroll fraction and pin to the bottom when the reader was already there. Explicit read failures are reported; automatic failures leave the current reader available.

The outline sidebar rebuilds rows when documents or outline data changes, but active-heading updates only change existing row selection state in place so scrolling does not recreate the outline list.

HTML export fetches remote images serially, passing the remaining aggregate 20 MiB byte allowance to the streaming fetcher before each request. Local image reads use the same validated descriptor path as the reader, with the remaining inline budget enforced while reading. Remote image requests and redirects use `RemoteAssetURLGuard`; rejected images are omitted. Closing the exporting window cancels outstanding work. Resolved wiki links are rewritten relative to the chosen output location, with absolute file URLs when needed; copy-code controls follow the shared export-chrome contract.

## Quick Look Preview Rendering

Quick Look uses `PreviewComposer` in `WaferCore` plus a view-based `NSViewController` and `QLPreviewingController` bridge in `WaferQuickLook`. The composer reads markdown through the shared `MarkdownSourceDecoding` path used by the app and library indexer, accepting UTF-8 plus UTF-16 with a BOM or the shared zero-byte heuristic, then applies the 2 MB source budget before parsing. The truncation note is appended to the markdown source so the renderer handles it like normal content. Unreadable or undecodable files throw instead of returning empty HTML, allowing Quick Look to fall back to another provider.

`WebKitHTMLRenderer` has an explicit `RenderTarget.preview` mode that keeps reader output unchanged while producing scriptless preview HTML. Preview mode does not emit CSP script tags, Mermaid figure chrome, KaTeX mounts, Wafer custom URL schemes, or remote image URLs. Mermaid and math fences render through the normal code-block path, remote images become placeholders, and local images become `cid:` references with a matching `previewAttachments` map. `PreviewComposer` enforces the 10 MB total local-attachment budget and removes skipped `cid:` images from the HTML so Quick Look never receives dangling attachment references. `PreviewComposer` can inline accepted attachments as `data:` URLs for callers with folder access. The sandboxed `PreviewProvider` passes `allowsLocalImages: false`, so Finder previews deterministically omit sibling images and never try to read them. The extension has only the app-sandbox entitlement, and the requested file does not grant a general folder-access scope. Local image support therefore remains available to unsandboxed core callers but is intentionally unavailable in Finder previews.

`PreviewProvider` presents the preview with a native `NSScrollView` and non-editable `NSTextView`. It imports the scriptless preview HTML as an attributed string, forces the selected light/dark palette foreground and background colors for readability, and keeps the content selectable and scrollable. The extension intentionally does not set `QLIsDataBasedPreview`; empirical validation showed the data-based path produced unreadably small or blank previews on this macOS release. An embedded WKWebView also produced blank captured surfaces, so the shipped view-based path avoids a WKWebView and uses native AppKit text presentation.

`PreviewRequestCoordinator` in the small `WaferQuickLookSupport` library target owns request replacement and delivery on the main actor. It uses WaferCore's `PreviewRequest` to complete each callback once. Replacement cancels and completes the previous request immediately; late results cannot change the view. Teardown cancels pending composition and completes its callback on the main actor. Presentation errors, including a missing preview text view, reach the request completion rather than trapping. `Tests/WaferQuickLookTests` imports this support target to cover overlapping requests, callback reentry, failure delivery, and teardown without inheriting the executable's extension entry point. The appex still links QuickLookUI and has no WebKit dependency.

`PreviewProvider` chooses `.dark` or `.light` from `NSAppearance.currentDrawing()` and falls back to the `AppleInterfaceStyle` user default only if the current drawing appearance cannot be matched. App-selected custom themes are intentionally not available in the extension; Finder previews follow the system appearance.

## Theming

Wafer uses a single `ReaderThemePalette` model for both the WebKit reader and native AppKit chrome.
The built-in palettes are `ReaderThemePalette.dark` and `.light`; Dark remains the compatibility
baseline for the pre-v0.6 look. `ReaderTheme.current` is the process-wide active palette and posts
`.readerThemeDidChange` whenever it changes. That state and the native colors derived from it live
in the app target (`ReaderTheme+Current.swift`); WaferCore holds no global theme state and takes a
palette as an explicit parameter. WaferCore still imports AppKit for stateless palette-to-`NSColor`
conversion, the editor color set, and Quick Look's attributed-text import, all of which the app and
the extension share.

`BundledResources.resourceURL(named:bundleName:)` is the shared public bundle lookup for app, extension, and SwiftPM hosts. It logs missing bundle/resource faults through `WaferLog.resources` and returns nil without invoking the generated fatal `Bundle.module` accessor. Core callers degrade explicitly: built-in CSS for a missing/unreadable reader stylesheet, literal emoji shortcodes for missing/invalid emoji JSON, code fences for unavailable Mermaid/KaTeX runtime or bootstrap resources (or missing KaTeX CSS), and system serif fonts for missing KaTeX font faces. Read/decode failures also log faults.

Renderer bootstraps are cached from `Resources/async-renderer.js`, `mermaid-bootstrap.js`, and `katex-bootstrap.js`. Per-render palette data travels as escaped JSON in a script data attribute, while script elements retain CSP nonces. Quick Look does not load these scripts or KaTeX styles. KaTeX ships WOFF2 fonts only. `node Tests/JavaScript/core/renderers.cjs` exercises the shipped scripts with a controlled DOM and scheduler.

The WebKit path captures the active palette when `MarkdownReaderDocument` schedules a render, then
passes it into `WebKitHTMLRenderer`. The renderer emits a generated `:root` block of CSS custom
properties before the bundled `reader-theme.css` body. Mermaid receives the same palette through
its generated JavaScript theme variables, and KaTeX output inherits `--text-color`, so Markdown,
sanitized raw HTML, diagrams, math, inspector chrome, syntax highlighting, and image placeholders all
use the same token source. The bundled CSS
body must stay token-only for theme colors; hard-coded colors belong in `ReaderThemePalette`.

The native path uses `ThemeApplying` plus `.readerThemeDidChange` observers. `DocumentWindowController`
sets the window appearance/background, re-applies titlebar suppression, and asks the active document
to update its existing DOM palette and Mermaid figures so scroll position is preserved. `DocumentChromeViewController`,
`DocumentSidebarViewController`, `DocumentStatisticsAccessoryViewController`, and
`WebKitReaderViewController` apply their layer/text colors from `ReaderTheme` and are re-applied
recursively when the theme changes.

`AppearancePreferenceStore` owns the persisted appearance selection. The default selection is
`System`, resolved through an injected `systemIsDark` closure so tests do not read the CI machine's
real appearance. Explicit `Light`, `Dark`, and custom selections ignore system appearance changes.
`AppDelegate.applicationDidFinishLaunching` reloads custom themes and applies the resolved palette
before documents render, preventing a first-paint mismatch.

Custom themes are loaded by `ThemeLibrary` from two sources: bundled themes shipped as SwiftPM
resources in `Sources/WaferApp/Resources/Themes` (resolved from the packaged
`Wafer_WaferApp.bundle` in app, framework, or command-line resource locations), then user
themes from `~/Library/Application Support/Wafer/Themes/*.json`, which override bundled themes
with the same `name`. The library creates the user directory and writes `Example.json` on launch,
decodes each file independently through `ThemeFile`, and keeps valid palettes keyed by `name`.
`Example.json` is a copy-me template and is excluded from the loaded palettes. Invalid files are
skipped with diagnostics rather than aborting app startup. Theme JSON mirrors `ReaderThemePalette`, requires all fields, validates every color as
`#RRGGBB` or `#RRGGBBAA`, and validates `ReaderThemeColor.alpha` in `0...1`. If a persisted custom
selection no longer resolves, the store deterministically falls back to Dark; choosing a missing
custom name from code shows one non-fatal notice per name. Bundled resource filenames stay ASCII so
the signed app bundle's sealed resource paths remain stable across Archive Utility, Finder, and
third-party extraction or copy paths; user-visible theme names may still use Unicode inside JSON.

Missing bundled theme directories or expected JSON files are packaging defects. `ThemeLibrary` logs a fault through `WaferLog.resources` and records a load diagnostic; malformed or unreadable bundled themes follow the same path. Valid bundled and user themes remain available, as do the compiled System, Light, and Dark choices. Selecting an unavailable theme resolves to Dark. Bundle lookup returns nil when the resource bundle is absent, so this path cannot trigger SwiftPM's fatal resource accessor.

Theme selection lives in a dedicated top-level Theme menu.
It is rebuilt by `AppearanceMenuController` when opened so custom themes, Reload Themes, and Reveal
Themes Folder in Finder reflect the current theme directory. Tests inject temporary theme
directories and reveal handlers; no test writes to the real Application Support directory.

## Vault Browsing (v1.2)

Back/forward history is a pure per-document `WindowNavigationHistory` (each tab
bundles its own document, so document-owned history IS per-tab). The single
choke point is `MarkdownReaderDocument.replaceCurrentFile`: every successful
cross-document replace-in-window navigation pushes the departing file unless
the navigation is itself a history traversal. Traversal computes a candidate
history value and commits it only after the target source loads successfully.
Back/Forward are disabled during a pending navigation read. Reload requests arriving during
any source read are coalesced and run against the resulting current file, preserving
an explicit refresh request. Failed or superseded reads leave committed history
unchanged. Scroll restoration reuses the existing `ScrollStateStore`.

Tabs: `DocumentHostWindowController` (a `DocumentWindowController` subclass)
owns ordered `DocumentTab`s (document + reader + history) in one window with a
fully custom, palette-token strip (`DocumentTabStripView`; drag-reorder is
local mouse tracking with a pure projection function). NSDocument allows one
owning document per window controller, so selection transfers ownership to the
active tab's document; inactive tab documents stay alive via their tabs and
`OpenDocumentRegistry` and are closed explicitly when their tab or the window
closes. Window-level chrome writes are gated by `isActiveInHost` so background
renders never clobber the visible tab. Tab tokens are an OPTIONAL palette
group; absent groups derive from sidebar/background tokens so pre-tab custom
themes load unchanged.

Wiki links are detected in the renderer's inline-text pass (composing with
autolinks, emoji, highlights, and footnotes; never inside code) and resolved
against an immutable `WikiLinkIndex` built once per library snapshot; the renderer never touches live library state, exactly
like the palette. The index prefers explicit library-relative paths, including
extensions and extensionless paths with directories, before the existing
filename/title fallback. Bare-name ambiguity still picks the shortest file
path, then the lexicographically first path. Reader and backlinks use the same
index. Resolved links use the `wafer-wiki:` scheme so clicks
navigate in the current tab; exports rewrite them to relative hrefs and Quick
Look renders the unresolved styling. Wiki-bearing documents re-render
flash-free when the index content actually changes (snapshot comparison).

Backlinks: scans collect outgoing references (markdown links + wiki targets
with paragraph context) during the existing parse; `BacklinkIndex` inverts
them in a pure second pass, resolving wiki targets against the scan's own
snapshot. The Outline sidebar appends a "Linked From" section for the current
document when a library is open.

## Security Model

The containing app runs in the App Sandbox. A bug in Wafer's own process (the parser, the sanitizers, the file and asset loaders) can reach only the app's container and the files and folders the user granted. WebKit's web content process is sandboxed separately by Apple. `App/Wafer.entitlements` is the complete set, and `scripts/verify-app.sh` fails on any difference:

| Entitlement | Why |
| --- | --- |
| `com.apple.security.app-sandbox` | Runs the app in the sandbox. |
| `com.apple.security.files.user-selected.read-write` | Read and save files the user opens, read folders the user grants, and save in the folders granted for writing (the library, and folders granted while editing). |
| `com.apple.security.files.bookmarks.app-scope` | Remember granted folders across launches as app-scoped security bookmarks. |
| `com.apple.security.network.client` | Remote images, export prefetch, the Sparkle feed and update downloads. |
| `com.apple.security.print` | File > Print and Export as PDF. |
| `com.apple.security.temporary-exception.mach-lookup.global-name` = `dev.wafer.app-spks`, `dev.wafer.app-spki` | Sparkle's sandboxed installer reports status and accepts the installer connection through these services. |

No other temporary exceptions are used. Sparkle follows its [sandboxing guide](https://sparkle-project.org/documentation/sandboxing/): `SUEnableInstallerLauncherService` is true in `App/Info.plist`, so installs go through the framework's `Installer.xpc`. The Downloader service stays disabled (`SUEnableDownloaderService` is absent) because the guide advises against it when the app already has `network.client`; its unused `Downloader.xpc` remains in the framework and is still signed, with its own entitlements preserved, during packaging. The local update smoke uses a signed loopback feed and proves `Installer.xpc` runs and replaces the sandboxed smoke bundle on quit. See [development checks](docs/DEVELOPMENT.md#app-sandbox) for the private identity, throwaway file key, evidence and remaining standard-UI release check.

The app's only network use besides remote images is Sparkle: it fetches the update feed, and an update archive once the user chooses to install. Archives are accepted only with a valid EdDSA signature from the key in `App/Info.plist`. The Quick Look extension is sandboxed with `com.apple.security.app-sandbox=true` in `App/QuickLook.entitlements` and intentionally has no network-client entitlement. Preview rendering strips remote image URLs before presentation, so Finder previews do not fetch remote images. Release verification fails if the sandbox entitlement is missing or if the appex requests network client access.

The WebKit reader is built around a deny-by-default render shell plus narrow local schemes:

- HTML passthrough uses an allowlist, not a denylist. Only known-safe tags are emitted.
- Attributes are allowlisted per tag. Event handlers, arbitrary styles, classes, IDs, and `data-*` attributes are dropped.
- Both sanitizers consume one internal `HTMLTokenizer`, decoding attribute entities before checking policy and escaping them once on output. Export also filters event handlers, unsafe URL attributes, and script-capable elements in DOM snapshots.
- URL-bearing attributes are parsed through one shared link-scheme policy for Markdown, raw HTML, and exports. Image sources allow local asset paths and `https` remote images only; links allow local paths, `http`, `https`, and `mailto`.
- `data:` image URIs are not rendered in v0.5.
- Every rendered document includes a CSP meta tag. It keeps `default-src 'none'`, `object-src 'none'`, `connect-src 'none'`, `base-uri 'none'`, and `form-action 'none'`. `img-src` allows only `wafer-local:` and `wafer-remote:`, `font-src` allows only `wafer-local:`, and `style-src` allows inline reader CSS plus local resource styles. Documents without scripted renderers use `script-src 'none'`; Mermaid or KaTeX documents use a per-render nonce on the bundled renderer scripts and shared bootstrap.
- Raw HTML tracks open elements across the render, drops unmatched closing tags, and closes leftover elements before the `main` boundary ends. Browser repair across Markdown containers cannot close that boundary because raw HTML cannot emit `main` tags. Sanitized HTML is emitted only inside `#write`; scripts, styles, iframes, objects, embeds, metadata tags, forms, and unsafe layout attributes are removed so raw HTML cannot escape the reader shell.
- Remote images are opt-out and non-blocking. Disabling File > Load Remote Images blocks future remote image fetches; failed remote images fail the scheme request instead of hanging rendering.

`WebKitReaderViewController` registers all six native message handlers in the named reader content world. Scroll mapping runs there too. Page-world code handles DOM patches and bundled Mermaid and KaTeX renderers. An app-owned page script relays the renderer's readiness API through a DOM event; an isolated document-start script attaches the load's UUID before posting to native code. Native code still checks that UUID. This avoids scanning or modifying the rendered HTML. No page-world handler accepts scroll-sync payloads.

Each app-owned `loadHTMLString` has a unique base-URL query identifier and one pending navigation authorization. The policy cancels other main-frame loads, including script, form, and meta-refresh navigations. Same-document fragment changes remain available, and activated links route through the document. Heading IDs are JSON-encoded before JavaScript evaluation, and scroll-restoration fractions travel through `callAsyncJavaScript` arguments. WebKit background styling uses the public `underPageBackgroundColor` API.

## File access

Under the App Sandbox Wafer reads its container, its bundle, and what the user chose. A Markdown file opened from Finder, the Dock, File > Open..., or Open Recent grants that file only, for reading and saving. AppKit restores access to recent documents from its own bookmarks, but recents saved by the unsandboxed 2.1.1 have none, so Open Recent counts a recent as opened only if it opens for reading now (`noteRecentDocumentOpened`); otherwise opening it asks for its folder. Folders are granted explicitly:

- `FolderAccessStore` keeps each granted folder as an app-scoped security bookmark. The `folderAccessGrants` preference holds, per grant, an identity, the path, the bookmark, whether it is read-only, and whether it is the library's. `AppDelegate` restores the grants in `applicationWillFinishLaunching`, because documents opened at launch arrive before `applicationDidFinishLaunching`. Restoring resolves each bookmark without UI or mounting, starts its access, and keeps it for the session: a stale bookmark is made again in its own mode, a moved folder's path follows it, and one that cannot be resolved (a disconnected drive) is kept. `AppDelegate` retries those on `NSWorkspace.didMountNotification` (`resolveUnavailableGrants()`), then reloads documents whose files became readable and rescans an unavailable library. Access stops when the app terminates or the grant is removed.
- Modes. A grant made to show a document's images and links is a read-only bookmark (`securityScopeAllowOnlyReadAccess`). The library's grant is read-write, because library documents are edited in place. A grant asked for while the requesting document is in edit mode is read-write too (`FolderAccessFlow.accessMode(requestedBy:)`): a link followed while editing opens in the editor, so navigation while editing requires write access, while a Cmd-click tab only reads. A grant inside one that allows at least as much adds nothing; a grant replaces the ordinary grants it contains that allow no more, and stops their access; a read-write grant inside a read-only one is kept. Choosing a granted folder again makes its bookmark again. Records stored before modes existed were read-write bookmarks and restore as read-write.
- Saving under a read-only grant. A sandboxed probe (2026-11-14, its own bundle ID, a folder handed over by LaunchServices and bookmarked both ways) showed that a resolved read-only bookmark reads, but `access(W_OK)`, `isWritableFile`, and the save path (`itemReplacementDirectory` plus `replaceItemAt`) all fail with `EPERM`; a read-write bookmark allows all three. Edit mode therefore refuses a file covered only by read-only grants with `fileWriteNoPermission`. `AppDelegate.application(_:willPresentError:)` presents that error, when the sandbox rather than the file's permissions is the reason, as a recoverable `FolderAccessDeniedError` (purpose `.editing`), whose Grant Access… asks for a read-write grant and then starts edit mode. In the session a folder is chosen, the open panel's own access is read-write until Wafer quits; read-only applies from the next launch.
- `covers(_:)` answers whether a URL is readable: `FileContainment` against the granted folders, the files the user opened this session, the container, the temporary folder, and the app bundle. `allowsWriting(_:)` is the same over read-write grants, the user's files, the container, and the temporary folder. `scope` is a `Sendable` snapshot of the readable roots for work off the main thread. It is cached until grants or selections change, and a candidate is resolved once per query (`FileContainment.Candidate`): with 10 grants and 30 opened files a debug query went from 1.05 ms to 0.14 ms (`FolderAccessPerformanceTests`, `WAFER_PERF_TESTS=1`). Session selections are bounded to the 512 most recent; closing a document keeps its selection, because macOS keeps the access until quit and forgetting it would only ask again. Outside the sandbox (tests, `swift run`) every path is covered and nothing is stored.
- The library is a grant of its own (`grantLibraryAccess(to:)`), referred to by `LibraryPreferenceStore.libraryGrantID`. It is stored even inside a broader grant, and no other grant replaces it. At launch the library reopens where its grant resolves, so a moved or renamed library folder is found again and the saved path follows it. A library whose grant record exists is never asked for at launch, even when the record is unresolved (its drive is not connected): it stays selected and is rescanned once the drive mounts. A saved library without a grant that a broader read-write grant covers gets a grant of its own; one covered only by a read-only grant, or by none, is asked for once. A new library or Close Library turns the previous library grant into an ordinary one; removing the library's grant in Folder Access closes the library.
- The store also records, per document, the files it needed but could not read: the linked documents in its sidebar entries (replaced on every render), link targets the user tried to open (dropped at the next render), images the asset handler refused (reconciled on every reader page, below), and its own file after a refused reload (until a read succeeds). The record is released when the last document showing the file closes or navigates away from it (`FolderAccessFlow.documentStoppedShowing`).

`FolderAccessRange` decides which folders a prompt may offer, because document content decides which file needs access. Its one predicate, `mayOffer(_:)`, rules the suggestions, the widening, the panel's starting folder, and the parent-folder hint. A prompt never suggests, widens to, or opens its panel at a folder too broad to offer: `/` or a top-level folder (`/Users`, `/Volumes`, `/Library`, ...), any `/Users/*` or `/Volumes/*` folder, the real home folder (from `getpwuid`, since `NSHomeDirectory()` is the container), a mounted volume root, or a folder above any of them. Nor does it offer a folder that holds settings and secrets rather than documents, however narrow: one with a hidden path component (a name starting with `.`, such as `~/.ssh` or `Notes/.obsidian`), or a `Library` folder or anything in it: the system `/Library`, any `/Users/<name>/Library`, and the real home's (`Keychains`, `Application Support/<app>`, the container, other apps' iCloud containers in `Mobile Documents`). The exceptions are the cloud drives macOS keeps in the Library: folders inside iCloud Drive (`Mobile Documents/com~apple~CloudDocs`) and inside a File Provider domain (`CloudStorage/<provider>`: Dropbox, Google Drive, OneDrive, ...) may be offered; those two roots are whole drives, like a volume root, and are not. Other apps' iCloud folders, such as Obsidian's `iCloud~md~obsidian/Documents`, stay excluded, because the path does not tell a public document folder from an app's synced data; the user chooses them in the panel or opens the vault as the library. Paths are compared standardized, with symlinks resolved, case folded, and `/System/Volumes/Data` and `/private` folded into the paths they appear as, so a firmlink or symlink spelling cannot reach the home folder, a hidden folder, or the Library. The window's suggestion is the document's folder, widened at most two levels to the closest folder that also holds the nearby needed files, stopping below the first folder it may not offer. A farther file is offered its own folder, and a file whose own folder may not be offered, or a document whose own folder may not be, is offered nothing.

`FolderAccessFlow.ensureAccess(to:requestedBy:window:access:onGranted:)` returns true when the file is readable (for `.readWrite`, writable). Otherwise it shows a folder-only `NSOpenPanel` (a sheet when the window is free) at the file's own folder, with the folder's full path in its message, and calls `onGranted` once the grant allows the access. A file outside the range gets an explanation instead, an alert whose default button is OK. Its Choose Folder… opens the panel at the requesting document's folder when that may be offered, and for a Markdown file it points to File > Open…. The user can still go anywhere in a panel and choose a folder deliberately. A chosen folder that holds none of the files asked for is not granted or stored (`FolderAccessFlow.choose`): the chooser is called again with `FolderAccessRequest.retry`, whose alert names the folder and the missing file and offers Choose Again… (back to the same panel) or Cancel, until the user picks a folder that holds the file or cancels. The window's Grant Access… applies the same rule to the files the document needs; a folder that holds some of them is enough. Tests drive this through the injected `chooseFolder`. The parent-folder hint appears only when the suggestion is narrow and its parent may be offered. After any grant, documents whose needed files became readable reload like File > Reload, so images, previews, and links work without reopening. The one panel that opens at a folder the user chose earlier is the library's: re-choosing a saved library opens inside it.

Where each case is handled:

- **Window notice.** `DocumentWindowController` shows `FolderAccessNoticeViewController`, a bottom titlebar accessory (never part of the WebKit page), while the active document has unreadable needed files: "Allow Wafer to read the folder … to show linked files and images", with the folder's full path as its tooltip, Grant Access…, and a close button. When nothing may be offered, it says the document needs files outside the folders Wafer offers. Closing the notice hides it for that document in that window. The bar makes the titlebar view taller, so the centered window title is aligned with the window buttons rather than centered in that view. The window records linked documents from `apply(sidebarEntries:outlineItems:)` and attributes refused images to the tab whose web view requested them.
- **Images.** `WebKitLocalAssetSchemeHandler` checks the scope before scheduling a read. A file outside it fails the request at once with `FolderAccessDeniedError` and posts `.localAssetAccessDenied` with the web view. `LocalAssetLoader.read` checks the same scope again after resolving symlinks, before it opens the file, and checks the path it actually opened (`F_GETPATH`) against both the document roots and the scope, so a parent swapped for a symlink in between cannot serve an ungranted file. No read is attempted outside the scope and no request is left pending. Each new page of a web view the handler has served posts `.localAssetPageWillLoad`; the previous page's refused images keep counting for one second while the new page asks for its own, so the notice does not flicker, and the rest are dropped. Pages patched in place while editing make no new requests, so an image removed while editing stops counting at the next full page load. HTML export reads through the loader without a scope; an unreadable image is omitted as before.
- **Links.** In-window navigation (relative links, wiki links, sidebar, history), Cmd-click tabs, links that open a new window (`MarkdownDocumentOpener.open(url:)`), and links to other files (`LinkTargetOpener`, before opening or revealing them) call `ensureAccess` first and continue after the grant. Another app can open, and Finder can reveal, only files the sandbox lets Wafer read.
- **Linked-document summaries.** The Documents sidebar does not read linked notes outside the scope; their rows say "Needs folder access", and selecting one asks for the grant. `DocumentSummaryCache` no longer caches failed summaries, because a grant can make an unchanged file readable.
- **Document reads.** `MarkdownSourceLoader` turns a read the sandbox refused (POSIX `EPERM`; plain `EACCES` file permissions are left alone), in every load state, into `FolderAccessDeniedError`, and drops a stale session selection for the file. Its alert offers Grant Access…, which always asks, since the read was refused even if Wafer believed it could read the file. The grant's completion reopens the file, so recovery does not depend on whether the panel is modal. A refused automatic reload is silent as before, but records the file so the window shows the notice.
- **Library.** Opening a library from the panel or a drop stores the library's read-write grant, so scanning, the directory monitor, Quick Open, and saving work in later launches. Installs that saved only `libraryFolderPath` keep it selected (shown as unavailable) and are asked once, after launch, to choose the folder again: an alert, then a panel that opens inside the saved folder. When a read-write grant already covers the path, the library reopens silently and gets a grant of its own. A library whose own grant is unresolved, on a drive that is not connected, is not asked for and does not use up the one-time prompt: it stays selected and shown as unavailable until `NSWorkspace.didMountNotification` resolves the grant and `retryIfUnavailable()` rescans it. File > Retry Library offers the panel while the folder is not writable. Close Library forgets the library choice; the folder grant stays, as an ordinary grant.
- **Folder Access window.** Wafer > Folder Access… (`FolderAccessWindowController`, built when first shown) lists `folderGrants`: each folder's path, Read only or Read and write, and whether it is "Your library" or not available. Remove calls `revoke(grantID:)`, which stops the folder's access and deletes its bookmark; documents keep what they show and ask again when they need the folder. Removing the library's grant also closes the library (`LibraryController.folderGrantRemoved(id:)` calls `closeLibrary()` when the identifier is `libraryGrantID`), so no library stays selected with a grant that no longer exists; the window's summary says so. macOS keeps access to a folder chosen in the current session until Wafer quits, but Wafer no longer treats it as granted.

Saving in the sandbox keeps the existing path (`itemReplacementDirectory` plus `replaceItemAt`). This was verified on 2026-11-13 with a sandboxed, ad hoc signed probe app using the same calls and entitlements: a file opened through LaunchServices was replaced on the startup volume (the replacement directory is inside the container) and on a separate APFS volume (`/Volumes/<volume>/.TemporaryItems`), kept its access after another app replaced it atomically, and a file inside a resolved folder bookmark could be replaced as well. In the `scripts/sandbox-smoke.sh` run on 2026-11-14, a folder grant made by one ad hoc signature resolved after the app was re-signed with a different code directory hash.

Container migration: on the first sandboxed launch macOS reads `Contents/Resources/container-migration.plist` and moves `~/Library/Preferences/dev.wafer.app.plist`, `~/Library/Preferences/dev.wafer.scroll-state.plist`, and `~/Library/Application Support/Wafer` (the themes) into `~/Library/Containers/dev.wafer.app/Data`, keeping their relative paths. It runs only when the container is created. `ThemeLibrary` and the preference stores then resolve inside the container without code changes, and Reveal Themes Folder in Finder opens the container's themes folder.

The `access` log category records restored, new, and removed grants and their modes, grants restored after a volume mounted, chosen folders not granted because they hold none of the files asked for, files a document could not read, dropped session selections, and the notice showing or hiding; served local assets are logged at debug level.

## In-App Updates

Wafer updates itself with Sparkle 2.10.1, a binary SwiftPM dependency of `WaferApp` only; the Quick Look extension does not link it. `Package.swift` adds the `@executable_path/../Frameworks` rpath so the bundled executable finds the embedded framework.

`UpdateController` owns one `SPUStandardUpdaterController` and is the target of the two items in the Wafer menu. The feed URL and EdDSA public key come from `App/Info.plist` (`SUFeedURL`, `SUPublicEDKey`), which also turns off automatic downloads and system profiling; the controller sets both off again at launch. A process whose bundle has no `SUFeedURL`, such as the test host, gets no updater, so tests never start Sparkle or reach the network.

The app quits when its last window closes, and Sparkle's windows count. `AppDelegate` therefore asks `UpdateController` first: while an update session is in progress the quit is postponed, and it is honored when the session ends if no window is visible. Installing terminates the app through `applicationShouldTerminate`, so edit mode flushes unsaved text as on any quit. Injected session, visible-window, and termination closures test deferred quits without creating an updater. Cycle completion clears the deferral once, including when a newly visible document window prevents quitting.

Local development bundles omit the feed and public key. `scripts/sandbox-update-smoke.sh` assembles two private smoke versions, signs their loopback appcast and archive using a throwaway file key, and runs an unattended smoke-only updater executable in the old bundle's sandbox. The target archive contains Wafer's actual executable. Its success gate requires the new version on disk, a valid signature and evidence of `Installer.xpc`. It does not exercise the production update menu or Developer ID distribution. Sparkle 2.10.1 rejects `file://` URLs; the smoke copies alone allow loopback HTTP. Release feeds remain HTTPS.

`App/Info.plist` sets `SUFeedURL` and `SUPublicEDKey` to the project's feed and public key. Wafer's releases and feed live in the source repository, which is passed to `scripts/release.py --repository OWNER/REPO`. Anyone distributing their own builds replaces both values and passes the repository that holds their releases and `appcast.xml`. [docs/UPDATES.md](docs/UPDATES.md) covers preparing, reviewing and publishing an update.

## Direct Distribution

Direct distribution outside the Mac App Store is handled by `scripts/package-release.sh`. The release path is:

1. Refuse a dirty source tree (`scripts/check-source.py`), then run `scripts/check.sh`, the same Swift, Python, Node and vendored-asset checksum checks CI runs.
2. Build `build/Wafer.app` with `release --release-identity` with build paths remapped, keep matching dSYMs, and strip the shipping executables before signing.
3. Sign Sparkle's helpers and framework inside out with a `Developer ID Application` identity, hardened runtime, and secure timestamp, never with `--deep`. Then sign `Contents/PlugIns/WaferQuickLook.appex` the same way with `App/QuickLook.entitlements`.
4. Verify the appex layout, bundled WaferCore resources, signature, sandbox entitlement, and absence of preview network entitlement with `scripts/verify-appex.sh`.
5. Sign the containing app with the same Developer ID identity, hardened runtime, and secure timestamp, and with `App/Wafer.entitlements`.
6. Verify the signed app with `codesign --verify --deep --strict`, re-run the appex verifier, and run `scripts/verify-app.sh --distribution`, which also requires the Developer ID authority and the hardened runtime.
7. Create a ZIP archive for Apple notarization.
8. Submit the ZIP with `xcrun notarytool`.
9. Staple the notarization ticket to the app bundle.
10. Create the final distributable ZIP in `dist/` without AppleDouble resource metadata, so third-party ZIP extractors cannot materialize `._*` files inside the signed app bundle and invalidate the nested signatures.
11. Verify the signed app with `codesign`, `stapler`, and `spctl`.

`scripts/release.py` wraps this script to prepare an in-app update: it packages into `dist/updates/<version>-<build>`, generates the signed appcast, and publishes only when run again with `--publish`. `WAFER_DIST_DIR` redirects the packaging output; without it the script clears `dist` except `dist/updates`.

Use `WAFER_SKIP_NOTARIZATION=1 scripts/package-release.sh` for local release packaging without submitting to Apple. Finder Quick Look provider selection still needs a manual smoke test against the signed app installed in `/Applications` because modern Quick Look extension election is not reliably proven by build output alone. Repeat the same smoke after notarization and stapling when preparing a public release.

Core rendering goldens are readable HTML resources under `Tests/Fixtures/WaferCore/Goldens`. Regenerate them explicitly with `WAFER_UPDATE_GOLDENS=1 swift test --filter 'RenderCompatibilityCorpusTests|WebKitHTMLRendererTests.testReaderGoldenOutputMatchesCheckedInHTML'`, then review the HTML diff. Normal tests load fixtures through `Bundle.module`.

## Performance verification

The default Core suite enforces generous parse (0.3 s) and render (0.75 s) budgets over 20 passes through the four compatibility fixtures, using the median of three warm samples. Core benchmark runners and reports live in `docs/benchmarks/`, outside bundled fixtures. Run `python3 scripts/benchmark-performance.py` for optimized synthetic core and sidebar measurements. Fixtures, binaries, resource links, and isolated benchmark preferences are cleaned up automatically. The script builds release products but does not assemble, sign, register, or install the app. Run `node Tests/JavaScript/app/reader-scroll.cjs` to verify scheduling and heading-cache behavior against the bundled JavaScript. Run `node Tests/JavaScript/app/live-preview.cjs` for block patching, scroll mapping endpoints, monotonicity, inverse mapping, and layout-cache invalidation. Measured results and limitations are recorded in `docs/performance-review-fixes.md`.

Quick Look reads only a bounded 2 MiB source prefix, preserving complete UTF-8/UTF-16 characters at truncation. Parsing, rendering, and attachment inlining run on a serial background queue with cancellation between phases. Attachment reads enforce the remaining 10 MiB allowance at read time. Only AppKit HTML import and text-view updates remain on the main thread.

## Logging

Failures that are handled without user interaction go to unified logging through `WaferLog` (subsystem `dev.wafer.app`; categories `editing`, `library`, `rendering`, `export`, `resources`), and folder grants under the App Sandbox through the `access` category of the same subsystem. File paths are logged as private values. Errors the user must act on are still presented in the UI.

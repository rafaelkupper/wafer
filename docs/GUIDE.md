# Wafer user guide

This guide describes Wafer's behavior in detail. For an overview and screenshots, see the [README](../README.md). For the design, see [ARCHITECTURE.md](../ARCHITECTURE.md).

## Behavior

- Finder-open markdown documents via `.md`, `.markdown`, `.mdown`, and `.mkd`
- Multi-window AppKit document UI that reads by default, with an optional edit mode
- Edit mode (Edit > Edit Markdown, `Cmd-E`, or the pencil button in the titlebar): the window widens to the left for a syntax-colored Markdown source editor, and the reader becomes a live preview that updates in place as you type; the two panes scroll together (see [Edit Mode](#edit-mode))
- In-app updates through Sparkle: Wafer > Check for Updates..., with optional scheduled checks (Wafer > Automatically Check for Updates). Nothing is downloaded until you choose to install, and no system profile is sent
- Light, Dark, System, and custom JSON appearance themes through the Theme menu
- Themed WebKit reader styling with local CSS resources
- Themed titlebar chrome with a trailing document-stats pill
- Native macOS find for the current document via `Cmd-F`, `Cmd-G`, and `Shift-Cmd-G`
- Folder library for opening a directory of markdown files through File > Open Folder...
- Library sidebar mode with a collapsible folder tree, current-file highlighting, and live updates when files change
- Quick Open for fuzzy filename/path matching through `Cmd-Shift-O`
- Full-text library search with snippets and heading deep links through `Cmd-Shift-F`
- Titlebar stats pill with app-wide preference for words, minutes, lines, or characters
- Titlebar copy buttons: one copies the current document's Markdown text, the other copies the file itself (like Finder's Copy) for pasting into Finder, Mail, or chat apps
- Left sidebar with `Library`, `Documents`, and `Outline` views toggled from the titlebar
- Sidebar document navigation that replaces the current file in the same window
- Sidebar outline navigation with active-section tracking while scrolling
- Off-main-thread parsing
- Live reload when the open file changes on disk, enabled by default through File > Automatically Reload
- Manual reload through File > Reload or Cmd-R refreshes the reader and its assets even when the Markdown is unchanged or automatic reload is disabled
- Same-document anchors that scroll in place and cross-document anchors that open at the target section
- GitHub-authored heading links keep working through invisible anchor aliases while Wafer's outline IDs stay stable
- Bare `http://`, `https://`, `www.`, and email addresses autolink during rendering without double-linking code or existing links
- YAML front matter is stripped from the Markdown body, shown as collapsed metadata, excluded from statistics, and used as a title fallback when there is no H1
- GitHub-style footnotes (`[^label]` plus `[^label]: definition`) render as numbered notes with back-links; definitions inside fenced code are ignored, unreferenced definitions are dropped, and missing definitions stay literal
- Gemoji-derived shortcodes such as `:rocket:` render as Unicode emoji in reader, Quick Look preview, and export; unknown shortcodes stay literal
- `==highlight==` pairs within a single text node render as themed `<mark>` text; unmatched markers and triple-equals text remain literal; sidebar/search text keeps raw shortcode and highlight source text
- `math` fenced code blocks render offline through bundled KaTeX in the reader and exported DOM; invalid TeX stays visible through KaTeX's red error text; inline `$...$` math is intentionally not parsed
- Semantic callouts for curated block directives like `note`, `tip`, `important`, `warning`, and `caution`
- GitHub alert blockquotes (`> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]`, and `> [!CAUTION]`) render as the same themed callout kinds
- Rendered symbol links and class-preserving inline attributes
- Offline Mermaid rendering for `mermaid` and `mmd` fenced blocks using bundled Mermaid 11.14.0, with dark-reader styling, an explicit diagram inspector, and invalid diagrams showing an inline error and source fallback
- Offline KaTeX rendering for `math` fenced blocks using bundled KaTeX 0.17.0, with local CSS/font resources loaded only when math is present
- Syntax-highlighted fenced code blocks for common languages including Swift, shell, JSON, YAML, Markdown, Go, Ruby, Python, Elixir, JavaScript, TypeScript, PHP, C, C++, Rust, Zig, Haskell, Java, HTML/XML, CSS/SCSS, TOML, Diff, Dockerfile, SQL, Kotlin, C#, Objective-C, Lua, Makefile, INI/conf/properties, GraphQL, HCL/Terraform, and protobuf
- External links open in the default browser or mail app. Only `http`, `https`, and `mailto` links open; links with other schemes (for example `javascript:` or app URL schemes) render as plain text and do nothing.
- Links to known passive files (images, PDF, plain text, RTF, macro-free Office documents, audio, and movies) open directly. Other files, folders, and packages ask first and offer Show in Finder, Open, or Cancel. This includes HTML, apps, scripts, executables, disk images, projects, shortcuts, configuration profiles, notebooks, and unknown file types. Local Markdown files keep opening in Wafer.
- Files must be UTF-8, or UTF-16 with a byte-order mark; other encodings show an error instead of garbled text. Files over 32 MB are refused rather than shown in part.
- Local markdown links reuse open windows by file identity and cascade new windows when needed
- Local images load through a custom local asset scheme in WebKit
- Remote images load only from `https` URLs through a custom remote-image scheme in WebKit; disable them with File > Load Remote Images when privacy matters, then reload with Cmd-R
- Scroll position is remembered per file fingerprint and preserved across live reloads, with bottom-of-document reloads staying pinned to the bottom

## Edit Mode

Edit mode puts the Markdown source next to the rendered document. It is off by default and is toggled per window tab with `Cmd-E`, Edit > Edit Markdown, or the pencil button in the titlebar.

- Opening edit mode widens the window to the left by the reader's width, so the reader keeps its size and its place on screen while the editor slides out beside it. Closing takes that width back. When the screen has no room to double the window, it grows as far as it can (moving right only if the left edge runs out) and the two panes share the result equally; in full screen they split the screen. With Reduce Motion on, the change is immediate. Drag the line between the panes to resize them, or double-click it to make them equal.
- The left pane is a plain-text editor with Markdown coloring that follows the current theme: headings, emphasis, links, wiki links, lists and tasks, quotes, tables, front matter, and fenced code (code inside fences uses the reader's syntax colors).
- The right pane is the normal reader. It requests updates every 100 ms while you type. A render already in progress finishes before the newest pending text is rendered. Only changed blocks are replaced, so images, rendered Mermaid diagrams, and math stay in place. The first diagram or math block on a page triggers one full refresh.
- The reader is not reloaded when edit mode opens or closes, so it does not flash or lose its place.
- The two panes scroll together, whichever one you scroll: the same source line stays at the top of both. They reach the top and the bottom together; the adjustment that needs is spread over about a screen of lines at each end, so neither pane jumps. Opening edit mode puts the editor at the place you were reading, and outline headings and anchor links move both panes.
- Edits save automatically about a second after you stop typing, and also when you switch documents, close the tab or window, switch to another app, leave edit mode, or quit. File > Save (`Cmd-S`) saves immediately. File > Revert Edits restores the text from when the file was opened in the editor; it is an ordinary edit, so Undo brings your changes back.
- Saving keeps the file's encoding (UTF-8 or UTF-16), byte-order mark, line endings, and permissions. If you never change anything, the file is never rewritten.
- If the file changes on disk while you have no unsaved edits, the editor takes the new version. If both changed, Wafer asks whether to keep your edits, use the disk version, or save your version as a copy. It never overwrites an external change without asking. A disk version that grows beyond the 32 MB opening limit also triggers this conflict check.
- Undo and redo are per editor and reset when another file is loaded into it.
- Read-only files cannot be opened in edit mode.

Limits: the panes are aligned by their top line, so a tall diagram or image can leave the line you are typing on below the bottom of the preview. With several tabs, the window takes the width of the selected tab at once when you switch between an editing tab and a reading one. Files with mixed line endings are saved with their most common ending once edited.

## Folder Library

Open a folder with File > Open Folder... or by dropping a folder on the app. Wafer indexes markdown files with extensions `.md`, `.markdown`, `.mdown`, and `.mkd`, skips hidden files plus `.git`, `.build`, `build`, `dist`, and `node_modules`, and caps the visible library at 2,000 markdown files. If the cap is reached, the Library sidebar shows a quiet truncation footer. Files that cannot be read, or that exceed the indexing budget (2 MiB per file, 128 MiB for the whole library), are left out of the index and counted in a footer such as "3 files skipped (unreadable or too large)". One unreadable file never empties the library; a file that becomes unreadable keeps its last indexed entry.

When a folder is opened without an existing reader window, Wafer opens the first markdown file from the completed background scan as the visible entry point for the library.

The Library sidebar mode shows a collapsible folder tree. Selecting a file replaces the current document in the same window, and the current file stays highlighted as you browse. The selected folder is persisted and restored on next launch.

If the folder or an indexed file becomes unreadable, Wafer keeps the last complete library snapshot and shows "Library unavailable. Results may be stale." in Library mode. The saved folder stays selected across launches. After reconnecting a share or restoring access, choose File > Retry Library to rescan and restart monitoring. Close Library explicitly forgets the folder. A successful scan still removes files that were actually deleted.

Quick Open (`Cmd-Shift-O`) fuzzy-matches filenames and relative paths, showing up to 50 ranked results. Return opens the selection in the current window. `Cmd-Return` uses the normal document opener, which focuses an existing window for that file or opens one if needed.

Library Search (`Cmd-Shift-F`) searches titles, relative paths, headings, and document body text. Results show the title, snippet, and relative path. Heading matches carry their anchor into the existing open-and-scroll flow, so selecting a result can land on the matched section after the document finishes rendering.

## Vault Browsing

Wafer v1.2 turns reading into browsing:

- **Back/Forward history** per tab. Every replace-in-window navigation (sidebar,
  library, search results, wiki links) records history; traverse with `Cmd-[` /
  `Cmd-]`, the titlebar chevrons, or mouse buttons 4/5. Scroll positions restore
  through the existing per-file store. History changes only after a successful
  read; Back and Forward stay disabled while a navigation read is pending.
- **Tabs.** A fully theme-native tab strip appears from the second tab onward.
  Plain clicks keep replacing in the current tab (the reader's quiet default);
  `Cmd`-click any sidebar/library/search row — or `Cmd-Return` in Quick Open —
  to open a tab instead. Drag tabs to reorder (Esc cancels), right-click for
  Close Tab / Close Other Tabs. Tear-off to a separate window is planned for a
  later release. New windows and tabs show a loading surface while reading,
  decoding, and hashing the source in the background. Opening the same pending
  file reuses its document; closing it discards the pending result.
- **Wiki links.** `[[Note]]`, `[[Note|alias]]`, `[[Note#Heading]]`, and
  `[[#Heading]]` resolve against the open library by file name or document
  title (case- and diacritic-insensitive; ambiguity picks the shortest path).
  Library-relative paths such as `[[Guides/Note]]`, `[[Guides/Note.md#Setup]]`,
  and `[[Note.md]]` select an explicit file before the filename/title fallback.
  Resolved links navigate in the current tab and push history; unresolved links
  render as a muted dashed span. `![[image.png]]` embeds resolve relative to
  the current document like ordinary images. Note transclusion (`![[note]]`)
  and escape syntax are not supported yet. Exports rewrite wiki links to
  relative paths; Quick Look always shows the unresolved styling.
- **Backlinks.** With a library open, the Outline sidebar ends with a
  "Linked From" section listing every library file that links to the current
  document, with the linking sentence as context. Activating one navigates
  (and `Cmd`-click opens it in a tab).

## Printing and Exporting

Wafer exports the already-rendered reader view, so Print, PDF, and HTML output keep the active
theme. Dark and custom themes are exported as dark/custom output rather than being forced to light.

- File > Print... (`Cmd-P`) opens the system print panel for the current document and uses the
  reader print stylesheet for paginated output.
- File > Export as PDF... writes a paginated PDF through the same WebKit print pipeline as Print,
  without showing the print panel.
- File > Export as HTML... writes a standalone `.html` file from the live WebKit DOM. Rendered
  Mermaid diagrams are preserved as SVG, rendered KaTeX math is preserved as HTML, scripts and
  Wafer app-only chrome are stripped, and local images are inlined as `data:` URIs. KaTeX fonts are
  not inlined, so exported math can fall back to system italic fonts when opened outside Wafer.

Remote image export follows File > Load Remote Images. When remote images are disabled, HTML export
does not fetch remote URLs and removes those images from the standalone file. When enabled, export
fetches `https` images with the same privacy posture as the reader; failed remote images are dropped
without failing the whole export. HTML export has a 20 MB total inlined-image budget and reports an
error if the document would exceed it.

## Quick Look

Wafer ships a Quick Look preview extension for Finder space-bar previews of markdown files. The preview uses the same core parser, syntax highlighter, front matter handling, footnote rendering, emoji/highlight rendering, GitHub alert rendering, table rendering, raw-HTML sanitizer, and light/dark reader palettes as the app, then imports the static preview HTML into a native scrollable Quick Look text view.

Quick Look previews are intentionally static:

- Mermaid and math fences render as highlighted source code because Finder previews do not emit or execute bundled JavaScript.
- Local images are omitted. The sandboxed extension is not allowed to read files next to the previewed document.
- Remote images render as placeholders and are never fetched from Finder previews.
- Markdown source larger than 2 MB is truncated at a newline and ends with a truncation note.
- The preview follows the current system light/dark appearance. App-selected custom themes are deferred to the main app.

## Appearance Themes

Use the Theme menu to choose:

- `System`: follows the current macOS light/dark appearance and updates open windows live
- `Light`: uses Wafer's built-in light palette, ignoring macOS appearance changes
- `Dark`: uses the original dark palette from earlier releases, ignoring macOS appearance changes
- bundled themes that ship with the app: GitHub Light, GitHub Dark, Dracula, Solarized Light,
  Solarized Dark, Nord, Monokai, One Dark, Gruvbox Dark, Catppuccin Mocha, Catppuccin Latte,
  Tokyo Night, Rosé Pine, and Synthwave '84
- custom themes loaded from JSON files in `~/Library/Application Support/Wafer/Themes`; a custom
  theme with the same `name` as a bundled theme overrides it

Bundled themes live in `Sources/WaferApp/Resources/Themes` and are regenerated from compact color
specs with `python3 scripts/gen_themes.py`.

Wafer creates the themes folder on launch and writes `Example.json` if it does not already exist.
That file is a template only — it never appears in the Theme menu. To make your own theme, copy it
to a new file, change its `name`, and edit the colors. It is the safest starting point because
custom themes must provide a complete palette; missing keys, invalid hex colors, or alpha values
outside `0...1` make the file invalid. Invalid files are skipped when themes reload, and valid
files remain available.

Custom themes use one JSON file per palette. The top-level JSON mirrors `ReaderThemePalette`:

| Key shape | Value |
| --- | --- |
| `name` | Display name shown in the Theme menu. Must be non-empty. |
| `tab` | OPTIONAL tab-strip token group (v1.2). Omit it and Wafer derives tab colors from your sidebar/background tokens; when present, all of its keys are required and validated. |
| `appearanceIsDark` | Boolean used for the native macOS window appearance. |
| `...Hex` color keys | `#RRGGBB` or `#RRGGBBAA` strings. |
| Chrome and overlay color keys like `kbdShadow` or `findBarBackground` | Objects with `hex` (`#RRGGBB` or `#RRGGBBAA`) and `alpha` (`0...1`). |
| `mermaid` | Complete Mermaid palette object. All color fields are hex strings; `theme` and `fontFamily` are non-empty strings. |

After editing or adding theme files, choose Theme > Reload Themes. Use Reveal Themes
Folder in Finder from the same menu to open the folder. If a selected custom theme is later removed
or becomes invalid, Wafer falls back to Dark for that session instead of crashing.

## HTML Compatibility

Wafer renders a sanitized raw-HTML subset for common Markdown compatibility. Supported tags are:
`details`, `summary`, `br`, `sub`, `sup`, `kbd`, `mark`, `abbr`, `b`, `strong`, `i`, `em`, `s`,
`del`, `ins`, `code`, `pre`, `hr`, `img`, `a`, `div`, `p`, `span`, `table`, `thead`, `tbody`,
`tr`, `th`, `td`, `ul`, `ol`, `li`, `h1`, `h2`, `h3`, `h4`, `h5`, `h6`, `blockquote`,
`figure`, `figcaption`, `caption`, `tfoot`, `colgroup`, `col`, `picture`, `source`, `dl`, `dt`,
`dd`, `small`, `u`, `q`, `cite`, `time`, and `wbr`.

Attributes are allowlisted per tag. Wafer preserves safe link/image URLs, `alt`, numeric image
dimensions, `title` on links/abbreviations, table spans, limited alignment values, `ol start`,
`col span`, `time datetime`, and policy-resolved `source srcset` image candidates. It does not
support scripts, iframes, video/audio, forms, arbitrary CSS, event handlers, `class`/`id`/`data-*`
passthrough, `data:` images, or plain `http:` images. Remote images are `https` only and always
pass through the same privacy preference as Markdown images.

## Performance

Library refreshes reuse unchanged notes, and both search entry points run in the background. The sidebar creates only the rows needed on screen. Linked-note titles and previews load as their Documents rows become visible; summaries use the first 256 KiB of each note and keep row order stable while loading.

Theme changes preserve the reading surface and scroll position. Inactive tabs adopt the current theme when selected. Run `python3 scripts/benchmark-performance.py` for reproducible optimized measurements; see [performance results](performance-review-fixes.md) for the review's before-and-after comparison.

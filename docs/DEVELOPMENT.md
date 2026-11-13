# Developing Wafer

Notes for building, testing, and releasing Wafer from source. For the design, see [ARCHITECTURE.md](../ARCHITECTURE.md).

## Source build identity

The package, app, and Quick Look extension use Wafer names and the `dev.wafer.app` bundle identifier. This identity has separate preferences and macOS registration from earlier distributions. The app reads custom themes from `~/Library/Application Support/Wafer/Themes`; it does not migrate older support folders.

The app manifest carries the project's update feed and public key, so a local build checks the same feed as the released app. To distribute your own builds, replace both as described in [the update guide](UPDATES.md). Packaging variables use the `WAFER_` prefix. The existing notarization Keychain profile may still be named `VibeMD`.

## Build

Use Xcode 26.3 or a Swift 6.2 or newer toolchain. Although Wafer declares Swift tools 6.0, the pinned swift-markdown dependency requires Swift tools 6.2.

Build a local unsigned app bundle:

```sh
scripts/build-app.sh release
open build/Wafer.app
```

For local installation, copy `build/Wafer.app` into `~/Applications` or `/Applications`.
Because this open-source path is unsigned, macOS may require the usual manual approval steps.

Local builds register with neither LaunchServices nor pluginkit by default. To register the build-directory app and Quick Look extension for local testing, run `WAFER_REGISTER_APP=1 scripts/build-app.sh release`. Registration can affect Finder previews on this Mac.

The build fails if either resource bundle or a required reader asset is missing. The app retains Mermaid and KaTeX. The Quick Look extension keeps reader CSS, emoji data, and its license; its native text preview runs no scripts.

Run the logic tests with `swift test` and the release-configuration tests with `python3 -m unittest discover -s Tests/ReleaseTools -v`. The release-tool tests use disposable app products and stub external signing, notarization, Git, and GitHub commands. They publish nothing.

[CI](../.github/workflows/ci.yml) runs the Swift and Python tests, builds the app, and verifies the Quick Look extension on macOS 15 with Xcode 26.3. Its Swift toolchain satisfies both the package's Swift 6.0 minimum and swift-markdown's Swift 6.2 requirement, and the app retains its macOS 14 deployment target. The runner's available toolchains are listed in the [GitHub runner image manifest](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md).

## Development Files

Keep `Sources`, `Tests`, `App`, `Package.swift`, `Package.resolved`, and `scripts` for development and releases. [ARCHITECTURE.md](../ARCHITECTURE.md) describes the current design; `RenderingShowcase.md`, `LinkedNote.md`, and the test fixtures cover reader behavior.

Icon artwork lives in `App/Resources`: `Wafer-source.png` is the original master, `Wafer.iconset` contains the editable sizes, and `Wafer.icns` is the shipping icon. Keep the iconset because its smallest sizes do not round-trip exactly through `iconutil`.

`swift package clean` removes compiled output while retaining downloaded dependencies. The next build recompiles the app. Compiler caches and old release backups can be discarded. Keep the latest signed `build/Wafer.app`, final ZIP and checksum in `dist`, and their release receipt, source hashes, packaging output, and notarization response. Keep `dist/updates`, which holds the reviewed artifacts of each published update; [UPDATES.md](UPDATES.md) describes that flow. Superseded tracked plans remain available in Git history.

## Release Confidence Checks

Before treating a local build as release-ready on one Mac, run:

```sh
swift test
scripts/build-app.sh release
scripts/verify-appex.sh build/Wafer.app
test -d build/Wafer.app
test -f build/Wafer.app/Contents/Resources/Wafer_WaferCore.bundle/Contents/Resources/reader-theme.css
test -f build/Wafer.app/Contents/Resources/Wafer_WaferCore.bundle/Contents/Resources/mermaid.min.js
test -f build/Wafer.app/Contents/Resources/Wafer_WaferCore.bundle/Contents/Resources/mermaid-LICENSE.txt
test -f build/Wafer.app/Contents/Resources/Wafer_WaferCore.bundle/Contents/Resources/katex.min.js
test -f build/Wafer.app/Contents/Resources/Wafer_WaferCore.bundle/Contents/Resources/katex.min.css
test -f build/Wafer.app/Contents/Resources/Wafer_WaferCore.bundle/Contents/Resources/katex-LICENSE.txt
test -f build/Wafer.app/Contents/Resources/Wafer_WaferCore.bundle/Contents/Resources/KaTeX_Main-Regular.woff2
```

These resource paths match Swift 6.4.2. Earlier SwiftPM toolchains use a flat resource bundle; the build and verification scripts accept that layout.

Then do a short single-machine smoke pass:

- open `RenderingShowcase.md`
- confirm `Cmd-F` opens the native find bar and `Cmd-G` / `Shift-Cmd-G` move between matches in the current document
- confirm the titlebar blends into the reader background and the stats pill appears after load
- switch the stats pill between words, minutes, lines, and characters and confirm the choice persists
- click the titlebar copy-text button, confirm it briefly shows a checkmark, and paste to confirm the full Markdown source was copied
- click the titlebar copy-file button and paste into a Finder window to confirm the `.md` file itself is copied
- open a scratch copy of `RenderingShowcase.md`, scroll to the middle, press `Cmd-E`, and confirm the window grows to the left in one smooth motion while the reader stays exactly where it was (same place on screen, same width, same scroll position, no reload flash) and the editor opens at the section you were reading with Markdown coloring
- type in a paragraph and confirm the preview updates within a moment without flashing or jumping, and that Mermaid diagrams and math elsewhere stay rendered
- scroll the editor and confirm the preview follows; scroll the preview and confirm the editor follows; scroll either to the very top and bottom and confirm both arrive together without a jump; click an outline heading and confirm both panes move
- wait a second, then confirm the file on disk contains the edit; edit the file in another editor while Wafer has no unsaved edits and confirm the editor picks it up
- press `Cmd-E` again and confirm the editor slides away, the window returns to its earlier frame, and the reader has not moved or reloaded
- in a window too wide to double on the screen, or in full screen, press `Cmd-E` and confirm the two panes share the available width
- open and close the sidebar and confirm the window frame stays fixed while the reader reflows smoothly
- switch between `Documents` and `Outline` and confirm the sidebar stays visually stable
- in `Documents`, open a linked markdown file and confirm it loads in the current window
- in `Outline`, click a heading and confirm it scrolls to the right section and tracks the active section while reading
- use File > Open Folder... on this repository and confirm the `Library` sidebar mode lists folders and markdown files
- use File > Quick Open... or `Cmd-Shift-O`, type a fuzzy filename query, and confirm Return opens the selected file in the current window
- use Edit > Search Library... or `Cmd-Shift-F`, search body text or a heading, and confirm results open in the current window at the matched heading when available
- click a same-document anchor and confirm it scrolls in place instead of opening a new window
- click a cross-document anchor and confirm the target file opens at the requested section
- confirm callouts, symbol links, inline attributes, and inline markdown inside table cells render correctly
- confirm GitHub alert blockquotes render as themed callouts and hide the `[!NOTE]`-style marker
- confirm bare URLs and bare emails are clickable in reader, preview, and exported HTML
- confirm front matter in a separate note renders as a collapsed metadata block and participates in title fallback
- confirm footnotes render as numbered back-linked notes, stay literal in inline code, and remain searchable by their definition text
- confirm known emoji shortcodes like `:rocket:` render as Unicode emoji, unknown shortcodes stay literal, and `==highlight==` renders as themed mark text
- confirm the expanded sanitized HTML subset renders lists, headings, figures, definitions, and `picture`/`source` fallbacks
- confirm the GitHub-style `#whats-new` showcase link lands on the `What's New?` heading
- confirm the richer fenced-code highlighting renders for showcase languages like `html`, `css`, `toml`, `diff`, `dockerfile`, `sql`, `kotlin`, and `makefile`
- confirm Mermaid fences render offline across the showcase diagram types with readable dark-mode contrast
- confirm `math` fences render offline as KaTeX in at least Light, Dark, and one bundled theme; confirm invalid TeX shows red source text instead of a blank block
- export the showcase as HTML and confirm rendered math remains visible even when KaTeX web fonts are unavailable outside Wafer
- confirm the local preview image renders
- confirm remote `https` images render, then toggle File > Load Remote Images off and use Cmd-R to verify remote images stop loading
- confirm File > Load Remote Images on plus Cmd-R restores remote image loading
- confirm `<details><summary>Click</summary>hidden</details>` renders as a native disclosure block
- confirm `<div align="center"><img src="https://..."></div>` renders with the image centered and loaded through the remote-image proxy
- open an adversarial scratch document containing `<img src=x onerror=alert(1)>`, `<script>alert(1)</script>`, `<a href="javascript:alert(1)">x</a>`, `<iframe src="https://evil">`, and `<img src="data:image/svg+xml,<svg onload=alert(1)>">`; confirm no alert runs and the page remains intact
- open the local markdown link and verify it reuses an existing window for the same file, otherwise cascades a new window
- use Finder `Open With` / default-app launch on a markdown file and confirm it opens without crashing
- open the external link and verify it hands off to the default browser
- scroll, close the file, reopen it, and verify the reading position restores
- append to the open markdown file and confirm the reader updates without a loading flash, preserving scroll position
- scroll to the bottom, append again, and confirm the reader stays at the bottom
- save the open file from another editor and confirm live reload keeps working after repeated atomic saves
- toggle File > Automatically Reload off, append to the file, confirm nothing changes, then use Cmd-R to reload manually
- switch the Theme menu between System, Light, and Dark and confirm all open windows update without relaunching
- while the theme is set to System, flip the macOS appearance and confirm the app follows live; while set to Light or Dark, confirm it ignores system changes
- reveal the themes folder, add a valid custom theme JSON, choose Reload Themes, select the custom theme, and confirm the reader, sidebar, titlebar, find bar, diagrams, and statistics pill update together
- add a malformed custom theme JSON, choose Reload Themes, and confirm the app stays up, skips the bad file, and still lists valid custom themes
- on the signed app installed in `/Applications`, select a markdown file in Finder and press Space; confirm Quick Look shows Wafer's themed preview rather than Apple's built-in Markdown preview. Repeat this check on the notarized and stapled app when preparing a public release.
- on a signed build with a newer build in the feed, choose Wafer > Check for Updates..., install, and confirm the relaunched app reports the new version (see [UPDATES.md](UPDATES.md))
- Quick Look the v1.0 kitchen-sink corpus fixture or an equivalent local note and confirm alerts, metadata, HTML lists, math fences as source blocks, and the picture fallback render without scripts.

# Developing Wafer

Notes for building, testing, and releasing Wafer from source. For the design, see [ARCHITECTURE.md](../ARCHITECTURE.md).

## Source build identity

Local and CI bundles use `dev.wafer.app.dev`, with Quick Look under `dev.wafer.app.dev.quicklook`. Their preferences and themes live in `~/Library/Containers/dev.wafer.app.dev/Data`. They omit the release migration manifest and update feed, so opening a development build leaves release preferences in place.

`package-release.sh` explicitly passes `--release-identity` to assemble `dev.wafer.app` and `dev.wafer.app.quicklook`. That bundle retains the project's feed, public key and migration manifest. Its first sandboxed launch moves the unsandboxed release preferences, scroll positions and themes into `~/Library/Containers/dev.wafer.app/Data`. Never launch that identity for development or smoke tests. Packaging variables use the `WAFER_` prefix. The existing notarization Keychain profile may still be named `VibeMD`.

## Build

Use Xcode 26.3 or a Swift 6.2.3 or newer toolchain, plus Python 3 and Node.js 22 or newer. Both Wafer and the pinned swift-markdown dependency require Swift tools 6.2. The tests use `weak let`, available in Apple's Swift 6.2.3 and newer toolchains. `scripts/check.sh` checks Node before starting tests and reports a missing or older installation.

Build a local app bundle, signed ad hoc with the App Sandbox entitlements:

```sh
scripts/build-app.sh release
scripts/verify-app.sh build/Wafer.app
```

Launching `build/Wafer.app` uses the development container. To test migration and release-style updates, use the disposable smoke copies in [App Sandbox](#app-sandbox).

For local installation, copy `build/Wafer.app` into `~/Applications` or `/Applications`.
An ad hoc signature has no Developer ID, so a copy downloaded from elsewhere still needs the usual manual approval steps.

Local builds register with neither LaunchServices nor pluginkit by default. To register the build-directory app and Quick Look extension for local testing, run `WAFER_REGISTER_APP=1 scripts/build-app.sh release`. Registration can affect Finder previews on this Mac.

The build copies only `Wafer_WaferCore.bundle` and `Wafer_WaferApp.bundle` into the app, plus a scriptless `Wafer_WaferCore.bundle` inside the Quick Look extension. It fails if either bundle or a required reader asset is missing. `verify-appex.sh` rejects any extra `.bundle`, including stale test bundles. The app retains Mermaid and KaTeX. The Quick Look extension keeps reader CSS, emoji data, and its license; its native text preview runs no scripts.

Run the same checks as CI with `scripts/check.sh`. It verifies the vendored asset checksums, runs Swift tests, runs Python release-tool tests, then runs every `Tests/JavaScript/*/*.cjs` test. Swift compiler warnings are errors for all Wafer targets, including tests; dependencies keep their own warning policies.

Run the logic tests separately with `swift test` and the release-tool tests with `python3 -m unittest discover -s Tests/ReleaseTools -v`. The release-tool tests use disposable app products and stub external signing, notarization, Git, and GitHub commands. They publish nothing.

Run optimized Swift tests with `scripts/check.sh --release`. This runs `WAFER_RELEASE_TESTS=1 swift test -c release` for `WaferCoreTests` and `WaferQuickLookTests`, followed by the same Python and JavaScript checks. The environment variable excludes `WaferAppTests` from the package's test targets because those tests use DEBUG-only app seams. SwiftPM compiles every selected test target before applying `--filter`, so a filter alone cannot exclude them. Core and Quick Look tests run against optimized production code without defining DEBUG.

Run the JavaScript tests with `for test in Tests/JavaScript/*/*.cjs; do node "$test"; done`. They execute the bundled reader and renderer scripts against a controlled DOM.

Test switches:

- `scripts/check.sh --perf` or `WAFER_PERF_TESTS=1 scripts/check.sh` also runs the wall-clock performance assertions (for example `EditSavePerformanceTests`), which are skipped by default because they depend on machine load.
- `scripts/check.sh --release --perf` enables the optional performance assertions in the optimized Core and Quick Look suites. App performance tests remain part of the debug suite.
- `WAFER_UPDATE_GOLDENS=1 swift test --filter RenderCompatibilityCorpusTests` rewrites the golden HTML files under `Tests/Fixtures/WaferCore/Goldens`. Review the diff before committing.

Runtime failures that are handled without user interaction are written to unified logging. Watch them with `log stream --predicate 'subsystem == "dev.wafer.app"'`.

[CI](../.github/workflows/ci.yml) runs separate debug and release test jobs on macOS 15. The debug job also assembles the release app and verifies its Quick Look extension. `scripts/select-xcode.sh` selects the newest installed Xcode 26 with Swift 6.2.3 or newer from `/Applications` or the current `xcode-select` directory, and fails clearly if none is usable. Checkout and cache actions are pinned to full commit SHAs. The `.build` cache key includes the runner platform, configuration, Xcode and Swift versions, and `Package.resolved`. Push builds run only for `main`; pull requests run once per configuration. Performance assertions remain opt-in because hosted runners have variable load. The app retains its macOS 14 deployment target.

`scripts/build-app.sh` builds all package products once, then locates executables, resource bundles, and Sparkle through `swift build --show-bin-path` for the selected configuration, including toolchain-specific product directories. Quick Look request coordination lives in `WaferQuickLookSupport`; its tests run without importing the extension executable or its `_NSExtensionMain` linker flag. The extension still links QuickLookUI, excludes WebKit, and uses the app sandbox.

## App Sandbox

The app is sandboxed with exactly the entitlements in `App/Wafer.entitlements`: `app-sandbox`, `files.user-selected.read-write`, `files.bookmarks.app-scope`, `network.client`, `print`, and the mach-lookup exceptions `dev.wafer.app-spks` and `dev.wafer.app-spki` for Sparkle's installer. `App/Info.plist` sets `SUEnableInstallerLauncherService`; the Downloader service stays off because the app has `network.client` ([Sparkle sandboxing guide](https://sparkle-project.org/documentation/sandboxing/)). [ARCHITECTURE.md](../ARCHITECTURE.md#security-model) explains each entitlement and the [file access](../ARCHITECTURE.md#file-access) model.

Signing:

- `scripts/build-app.sh` signs the Quick Look extension and then the app ad hoc, each with its entitlements. Ad hoc signatures have no team identity, so local builds leave out the hardened runtime, whose library validation needs one.
- `scripts/package-release.sh` signs Sparkle's helpers, the extension, and the app inside out with Developer ID, the hardened runtime, and a secure timestamp; the app gets `App/Wafer.entitlements`.
- `scripts/verify-app.sh [--distribution|--release-identity] [app]` defaults to the development identity. It fails unless the signed entitlements are exactly `App/Wafer.entitlements` with the selected identity's mach names, the Sparkle mach-lookup names match the bundle identifier, `SUEnableInstallerLauncherService` is set and the Downloader service is not, `Installer.xpc` is present, and the migration manifest matches `App/` in release mode or is absent in development mode. Development verification also rejects the release feed and key. `verify-appex.sh` accepts the same identity flags and checks both the containing app and nested extension IDs. `--distribution` also requires a Developer ID Application signature with the hardened runtime. CI runs it after assembling the app, and packaging runs it with `--distribution`. `check.sh` runs its release-tool tests.

Unit tests run unsandboxed, so they cover the logic only (with a fake bookmark store and an injected folder panel). The sandbox itself is covered by a smoke test of the built app:

```sh
scripts/build-app.sh release
export WAFER_SMOKE_BUNDLE_ID=dev.wafer.app.sandbox-smoke-$(date +%Y%m%d%H%M%S)
export WAFER_SMOKE_DIR=/tmp/wafer-sandbox-smoke-$(date +%Y%m%d%H%M%S)
scripts/sandbox-smoke.sh run       # prepare, open fixture folder, relaunch, assert
scripts/sandbox-smoke.sh clean     # remove owned fixtures; keep evidence
```

Use a fresh ID and work directory for each run. `prepare` refuses existing fixture paths and containers. The smoke copy has no Quick Look extension or release update feed. Its manifest migrates only private seeded preferences, scroll state and themes. The real `dev.wafer.app` preferences and scroll suite are never seeded or launched.

`check` has four failure exits: **20** for container creation, **21** for migrated fixture preferences, scroll state or themes, **22** for a missing bookmark or failed relaunch access, and **23** for sandbox violations or unavailable unified logs. There is no denial allowlist. It reads `com.apple.sandbox.reporting` and Wafer's `access` category for the original and relaunched processes. A separate sandboxed probe under the smoke ID resolves the persisted bookmark and reads the sibling image without a new user-selection event; its bytes must match the fixture. This proves OS access alongside Wafer's restoration log, without asserting that WebKit visibly painted the image.

Evidence stays in `build/sandbox-smoke-evidence/<bundle-id>` after `clean`, including unified JSON, the read-back image and probe diagnostics. Cleanup requires the work directory's ownership marker. If macOS refuses container deletion, the script prints the remaining path and saves `cleanup.log`; delete that private container in Finder if desired.

For manual checks, use `prepare`, `open [FILE...]`, `relaunch`, `check`, then `clean`. Opening the fixture Documents folder grants it without a panel. Opening just `Notes/Plan.md` first tests the notice. `check --migration-only` checks migration and sandbox logs before any grants. Full `check` requires a recorded relaunch.

CI runs the no-click `run` on the macOS debug job, prints its unified log to the job output and cleans the copy on exit. It needs a GUI login session that LaunchServices can use; SSH daemons without one cannot run this gate. The hosted-runner configuration has not been exercised locally. CI fails if launch or sandbox checks fail, rather than silently skipping them. Migration, relaunch access and the local update smoke remain required on a logged-in Mac before release, even if CI is green.

Test the sandboxed Sparkle installation without publishing a feed:

```sh
scripts/sandbox-update-smoke.sh
```

The script assembles smoke builds `900001` and `900002` with the same private ID and matching Sparkle mach-lookup exceptions. It generates a throwaway Ed25519 key using OpenSSL, passes the raw seed through `sign_update --ed-key-file`, and signs both archive and appcast. It never calls `generate_keys` or reads or writes signing keys in the Keychain. The HTTP server binds only loopback and stops on exit. The private key, archives and apps are deleted after the run.

Sparkle 2.10.1 [rejects `file://` downloads](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Downloader/SPUDownloader.m#L59-L75). The script uses `http://localhost` with `NSAllowsLocalNetworking` confined to the smoke copies. Sparkle's [App Transport Security guide](https://sparkle-project.org/documentation/app-transport-security/) requires HTTPS or an appropriate exception. The release feed stays HTTPS.

For unattended installation, the old copy runs `scripts/sandbox-update-driver.m` in its sandbox, using the embedded Sparkle and smoke entitlements. It supplies the install choices, waits for the archive to validate, defers installation, then quits. The target archive contains Wafer's actual executable. This follows the [installer XPC configuration](https://sparkle-project.org/documentation/sandboxing/) and the [install-on-quit API](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUserDriver.html). It exercises Sparkle installation, not Wafer's menu or production `UpdateController`, which disables automatic downloads. The normal update prompts still need a manual release check.

Success requires `Installer.xpc` process evidence, the installer-ready callback, the on-disk build changing from `900001` to `900002`, and a valid resulting signature. The script retains `driver.log`, `http.log`, `processes.log`, `installer.log`, the signed appcast, public key and installed Info.plist under the same evidence root. No clicks were needed on the controller Mac on 2026-11-14. This ad hoc run does not qualify Developer ID, hardened runtime, Gatekeeper or notarization.

Watch the logs with:

```sh
log stream --level debug --predicate 'subsystem == "dev.wafer.app" OR sender == "Sandbox" OR subsystem == "com.apple.sandbox.reporting"'
```

On macOS 27, `sandboxd` reports app sandbox denials under `com.apple.sandbox.reporting`; `sender == "Sandbox"` shows the kernel's reports. Reads the sandbox refuses outside the granted folders are often not reported at all, so the `access` category records the files Wafer refused and the grants it restored or added. Earlier smoke runs saw WebKit's `mach-lookup com.apple.Safari.SafeBrowsing.Service` denied. The reader now disables that unnecessary lookup; the current gate permits no denials.

Steps that need clicks:

- Grant Access… in the notice: the panel opens at the document's folder; Grant Access with nothing selected grants that folder, and the image, previews, and links appear without reopening.
- A relative link to a note in another folder asks for its folder, then opens it.
- The first-launch library prompt: Choose Folder…, then Choose in the panel.
- Edit and save, Save a Copy..., Export as HTML and PDF, and Print.
- Switch the theme, and Reveal Themes Folder in Finder opens the container's themes folder.
- Scroll, quit with Cmd-Q, relaunch, and confirm the position; File > Open Recent reopens a file.
- Wafer > Check for Updates... with the standard UI against a reviewed test or published feed. The scripted local feed covers the sandboxed installer separately.

## Development Files

Keep `Sources`, `Tests`, `App`, `Package.swift`, `Package.resolved`, and `scripts` for development and releases. [ARCHITECTURE.md](../ARCHITECTURE.md) describes the current design; `RenderingShowcase.md`, `LinkedNote.md`, and the test fixtures cover reader behavior.

Icon artwork lives in `App/Resources`: `Wafer-source.png` is the original master, `Wafer.iconset` contains the editable sizes, and `Wafer.icns` is the shipping icon. Keep the iconset because its smallest sizes do not round-trip exactly through `iconutil`.

`swift package clean` removes compiled output while retaining downloaded dependencies. The next build recompiles the app. Compiler caches and old release backups can be discarded. Keep the latest signed `build/Wafer.app`, its matching `build/Wafer.dSYM` and `build/WaferQuickLook.dSYM`, final ZIP and checksum in `dist`, and their release receipt, source hashes, packaging output, and notarization response. Keep `dist/updates`, which holds the reviewed artifacts of each published update; [UPDATES.md](UPDATES.md) describes that flow. Superseded tracked plans remain available in Git history.

## Release packaging

Commit or stash tracked changes before running `scripts/package-release.sh` or preparing an update with `scripts/release.py`. Packaging rejects staged and unstaged changes anywhere in the repository, plus untracked files under `Sources`, `Resources`, and `App`, including ignored files. It checks again after packaging; update preparation also checks before recording its receipt. There is no dirty-tree override. Ordinary local `build-app.sh` builds still accept edits.

Release builds generate `build/Wafer.dSYM` and `build/WaferQuickLook.dSYM`, then strip local and debug symbols from both shipping executables before signing. Swift debug and file paths and C debug paths map the checkout to `/wafer`. The dSYM tool maps object paths back to the checkout while gathering symbols. Keep the dSYMs with the exact binaries they describe; UUIDs must match. Packaging copies both symbol bundles beside the final ZIP in `dist`, or in the directory selected by `WAFER_DIST_DIR`. They are not inside the downloadable app ZIP.

`scripts/package-release.sh` runs `scripts/check.sh` before the release build. `WAFER_SKIP_TESTS=1` bypasses these checks only for deliberate local packaging. `WAFER_SKIP_NOTARIZATION=1` skips submission and stapling. These switches do not bypass the clean-tree requirement.

Notarization accepts only `WAFER_NOTARY_PROFILE`, passed as `--keychain-profile`. Store credentials interactively so passwords never appear in command arguments:

```sh
xcrun notarytool store-credentials VibeMD
WAFER_NOTARY_PROFILE=VibeMD scripts/package-release.sh
```

The older Apple ID/password and API-key environment-variable fallbacks are no longer supported. For reviewed updates, follow [the update guide](UPDATES.md). Publication validates the receipt, archive, feed, existing release and tag before creating or uploading a release. A tag without a release must still resolve to the reviewed commit. Feed transport failures report the URL and underlying error.

## Vendored assets

[vendored-assets.json](vendored-assets.json) records the upstream version, source URL and SHA-256 of every shipped Mermaid and KaTeX file, including licenses and WOFF2 fonts. The pinned npm archives were used to verify provenance. KaTeX CSS removes only WOFF and TTF URLs; its manifest entry records the upstream hash and modification. No runtime assets changed in this release-tooling update.

Run `python3 scripts/verify-vendored-assets.py` to check the inventory and checksums offline. `scripts/check.sh` also runs it. When updating a vendor, compare against the pinned upstream archive, record any transformations, update the manifest, and run the checks again.

## SwiftPM flags

`WaferCore` has no unsafe flags. The existing unsafe flags belong to the executable targets: WaferApp's Sparkle rpath and WaferQuickLook's application-extension and `_NSExtensionMain` flags. SwiftPM allows them when building this root package. The restriction applies to products containing unsafe flags when consumed as dependencies by another package, so no change is needed for Wafer's app build or the clean WaferCore library product. Warning enforcement uses Swift 6.2's safe `treatAllWarnings(as: .error)` setting.

## Release confidence checks

Before treating a local build as release-ready on one Mac, run:

```sh
scripts/check.sh
scripts/check.sh --release
scripts/build-app.sh release
scripts/verify-appex.sh build/Wafer.app
scripts/verify-app.sh build/Wafer.app
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

Required release gates: run `scripts/sandbox-smoke.sh run` with a fresh smoke ID and `scripts/sandbox-update-smoke.sh` on a logged-in Mac, and retain their evidence. Prove the migration assertion once by removing the migration manifest from a fresh smoke copy before launch, re-signing it, and confirming `check --migration-only` exits 21. An unmodified fresh copy must pass. Never launch `dev.wafer.app` for this check.

Then do a short single-machine smoke pass. Run the sandbox items with `scripts/sandbox-smoke.sh` (see [App Sandbox](#app-sandbox)), and the rest with the copy it prepares or with the installed app:

- open a fixture document whose sibling image needs a grant, confirm the notice appears, grant its folder, and confirm the image appears without reopening; confirm a grant for a parent folder covers documents in other subfolders
- confirm the first launch of a fresh smoke container migrated the fixture preferences and theme, and that grants, the library, and preferences survive a relaunch
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

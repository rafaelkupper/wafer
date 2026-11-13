# In-app updates, with Sparkle

Historical record. Names and local paths have been normalized for publication; repository URLs are examples.

## Goal

Wafer checks for, downloads and installs its own updates, using an established setup: Sparkle, a feed on GitHub Pages, release archives on GitHub, and a prepare-then-publish release script.

## Context

- Requested by the user on 2026-11-12: in-app updates.
- Reference architecture:
  - Sparkle 2.10.1, pinned.
  - Feed at `https://example.github.io/markdown-releases/appcast.xml`; the public repository `example/markdown-releases` holds the feed and the GitHub releases.
  - EdDSA private key in the login Keychain under Sparkle's default account; public key in the app manifest.
  - Automatic downloads and system profiling off.
  - `release.py` prepares a notarized build and appcast for review, and publishes only with `--publish`.
- Baseline: main at `88d9c92` (Wafer 2.0.0, build 19, already distributed without an updater). Unrelated local changes are preserved.
- Differences in Wafer:
  - The app is a SwiftPM executable assembled into a bundle by `scripts/build-app.sh`, not an Xcode target. Embedding the framework, the rpath, and signing Sparkle's helpers are done by hand.
  - It is a regular document app with no settings window, so the controls are menu items.
  - It quits when its last window closes.
  - It is built for Apple silicon only.

## Constraints

- No push, repository creation, notarization or publication without the user's authorization. The user authorized all four for 2.1.0 on 2026-11-12.
- The 2.0.0 artifacts in `dist` stay intact.
- Tests never start Sparkle or reach the network.
- `AGENTS.md` is not edited.

## Decisions

- Sparkle 2.10.1, as a binary SwiftPM dependency of `WaferApp`.
- Signing key from the Keychain's default Sparkle account.
- Feed and releases: `example/wafer-releases`, by analogy.
- Sparkle's release tools come from `.build/artifacts/sparkle/Sparkle/bin`, so `release.py` needs no `--sparkle-tools` argument.
- `scripts/release.py` wraps the existing `scripts/package-release.sh` instead of duplicating it. The packaging script gained `WAFER_DIST_DIR` and now keeps `dist/updates` when it clears `dist`.
- The framework is embedded whole. Nothing inside it is removed.
- Sparkle's standard update window is used as is; no gentle-reminder handling.
- The quit after the last window closes is postponed while an update session is in progress.
- The first release with the updater is 2.1.0 (build 20), chosen by the user on 2026-11-12 together with creating `example/wafer-releases`. Verification below was done before the bump, on 2.0.0 (19).

## Done when

- [x] The app menu has Check for Updates... and Automatically Check for Updates.
- [x] The built bundle contains the framework and the feed, key and privacy settings.
- [x] `swift test` passes.
- [x] A Developer ID signing run passes with each Sparkle helper on the team, timestamped, with hardened runtime.
- [x] An update installs from a feed between two builds.
- [x] A tampered archive is refused.
- [x] Documentation describes the behavior and the release steps.
- [x] `example/wafer-releases` exists with a feed and GitHub Pages.
- [x] A notarized release with the updater is published through `scripts/release.py`: 2.1.0 (20).
- [ ] An update between two installed notarized builds is observed. Possible once a build above 20 is published.

## Verification (2026-11-12)

- `swift test`: 579 tests, 0 failures (core 240, app 339), in a direct run and again inside the packaging script. The first direct run of the session reported a failure in the app test target that I did not capture and that the two later runs did not reproduce.
- `WAFER_SKIP_NOTARIZATION=1 WAFER_DIST_DIR=<scratch> scripts/package-release.sh`: exit 0. Strict deep verification passed on the bundle and on the extracted ZIP. `Installer.xpc`, `Downloader.xpc`, `Autoupdate` and `Updater.app` each carry team `TEAMID`, a timestamp, hardened runtime, and no entitlements. `dist` was untouched. ZIP size 10,192,343 bytes, against 9,147,108 for 2.0.0.
- Local update test, with throwaway copies of the release build (bundle ID `dev.wafer.app.updatetest`, ad hoc signatures, a throwaway EdDSA key, a feed served on `127.0.0.1`, no Quick Look extension and no document types):
  - The real app, with automatic checks enabled, fetched the feed on its own two seconds after launch.
  - The user clicked through Sparkle's prompt, and the copy went from 2.0.0 (19) to 2.0.1 (20) with a valid signature.
  - A headless driver linked against the framework embedded in a fresh copy ran the same update: found 2.0.1 (20), downloaded 7,282,565 bytes, installed, and left a valid 2.0.1 (20) bundle.
  - With one byte of the archive flipped, Sparkle stopped with error 4005, "The update is improperly signed and could not be validated", and the bundle stayed at 2.0.0 (19).
  - `generate_appcast` wrote `sparkle:minimumSystemVersion` 14.0 and `sparkle:hardwareRequirements` arm64. `scripts/verify-update.swift` verified the archive length and signature.
- Before the feed repository existed, `scripts/release.py` stopped at the feed check: "The live feed answered 404".
- Not verified: notarization of a build that contains Sparkle; an update between Developer ID builds from the real feed; installing with unsaved edits in an open editor; the postponed quit when only Sparkle's windows are open. Desktop access was unavailable, so no direct UI verification was performed.
- Cleanup: the scratch directory, the local server, and the test bundle's preferences and caches were removed.

## Released (2026-11-12)

Wafer 2.1.0 (build 20) was committed as `6156ddc`, notarized (submission `717638b0-981a-4ab0-ab74-a55d4ac1f2c0`), and published as release `v2.1.0` in `example/wafer-releases` with feed commit `72866d1`. The public ZIP and live feed match the reviewed hashes. Details: `docs/logs/2026-11-12-wafer-2.1.0-release.md`.

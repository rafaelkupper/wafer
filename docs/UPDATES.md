# Prepare an in-app update

Wafer embeds Sparkle 2.10.1. `App/Info.plist` carries the project's update feed (`SUFeedURL`) and its public EdDSA key (`SUPublicEDKey`), so an app built from this repository checks the same feed as the released app. Builds without a feed keep the update menu items disabled.

The private key that matches `SUPublicEDKey` stays in the publisher's login Keychain under Sparkle's `ed25519` account. Never export it into the repository. If you distribute your own builds, replace `SUFeedURL` and `SUPublicEDKey` with your own HTTPS appcast URL and public key first, so your users receive your updates and not this project's.

Releases are published from the source repository itself. Each version is a GitHub release holding the ZIP, and the update feed is `appcast.xml` at the root of the default branch. The feed URL has the form `https://raw.githubusercontent.com/OWNER/REPO/main/appcast.xml`, which serves that file over HTTPS with no further setup; GitHub may cache it for a few minutes after a push. The repository must be public for the feed and downloads to be reachable. Pass the repository as `--repository OWNER/REPO` to each release command. Configure Git's commit name and email for the release publisher before publishing.

Sparkle's tools are not installed separately. SwiftPM unpacks them next to the framework it links, at `.build/artifacts/sparkle/Sparkle/bin`, so they always match the embedded version.

## What the app does

- Wafer > Check for Updates... checks the feed and offers the update.
- Wafer > Automatically Check for Updates turns scheduled checks on or off. Until that choice is made, Sparkle asks once, on the second launch.
- An update is downloaded only after the user chooses to install it. Automatic downloads and system profiling are off.
- Installing quits Wafer through the normal path, so unsaved edits are saved first. If a save conflict prompt is cancelled, the quit is cancelled and the update installs on the next quit.
- Wafer normally quits when its last window closes. During an update session that quit waits until the session ends, because Sparkle closes its prompt before it opens the download progress.
- A process without the feed key in its bundle (tests and `swift run`, which do not run from the app bundle) creates no updater and disables both menu items.
- The app is built for Apple silicon only, so the feed marks each update `arm64`.

## Prepare for review

1. Set the marketing version and a strictly increasing integer build number in `App/Info.plist` and `App/QuickLook-Info.plist`.
2. Run `scripts/release.py --repository OWNER/REPO`.
3. Review the generated directory under `dist/updates/<version>-<build>`. Inspect `appcast.xml`, `review.json`, `notarytool-submit.json`, and the final ZIP.

Preparation runs `scripts/package-release.sh` into that directory: tests, a release build, Developer ID signing, notarization through the `VibeMD` profile, stapling, and the final ZIP. It then verifies the ZIP as extracted by both `ditto` and `unzip`, including each Sparkle helper's team, timestamp, hardened runtime and entitlements. It generates the appcast and checks the archive length and signature against the public key. It refuses an existing output directory or a build number already in the live feed. It stops before publication.

## Publish the reviewed artifacts

Run this only with explicit authorization to publish the version and target repository.

Push the commit the release was built from to the default branch first. The release tag `v<version>` is created at the tip of that branch, and GitHub attaches the source archives for that tag to the release.

The release title, notes, and feed commit message are all `Wafer <version>`, and the feed commit uses the publisher's Git identity.

```sh
scripts/release.py --repository OWNER/REPO --publish dist/updates/<version>-<build>
```

Publishing verifies the manifest and reviewed artifact hashes again, uploads the ZIP to a GitHub release, and pushes the updated `appcast.xml` to the default branch from a temporary clone. Pull afterwards so your checkout includes the feed commit. If publishing stops with "Release repo and live feed disagree" shortly after an earlier push, the served feed is still cached; wait a few minutes and run it again. If the upload succeeds but the feed push fails, retain the review directory and inspect the release and remote repository before recovery. Do not create a second release blindly.

## Verify an installed update

Install an authorized signed, notarized build containing the public key. Publish a higher authorized build through the reviewed flow. Choose Check for Updates..., install, and confirm the installed version, signature, and running app. Repeat with an editor open and unsaved text, and with automatic checks enabled.

## Local signing checks

`scripts/package-release.sh` signs Sparkle's helpers one by one, inside out, as [Sparkle prescribes](https://sparkle-project.org/documentation/sandboxing/): `Installer.xpc`, `Downloader.xpc` (keeping its entitlements), `Autoupdate`, `Updater.app`, then the framework, the Quick Look extension, and the app. Do not add `--deep` when signing; it stamps one set of entitlements on every helper. `--deep` remains appropriate for verification.

`WAFER_SKIP_NOTARIZATION=1 WAFER_DIST_DIR=<scratch directory> scripts/package-release.sh` signs and verifies without submitting to Apple and without touching `dist`.

The packaging script clears `dist` before each run but keeps `dist/updates`, which holds the reviewed artifacts of published releases.

Sources are Sparkle's [programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/), [publishing guide](https://sparkle-project.org/documentation/publishing/), and [code signing notes](https://sparkle-project.org/documentation/sandboxing/).

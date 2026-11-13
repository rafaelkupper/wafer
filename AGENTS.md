# Agent Notes

## Working Rules

- Do not run git commands that affect remotes unless explicitly asked.
- Do not use destructive commands.
- Update documentation when behavior, architecture, packaging, or release steps change.

## Build And Test

Use the command relevant to the task from the repository root:

```sh
swift test
scripts/build-app.sh release
```

`swift test` is the normal logic regression check. The release build is for
changes that affect app assembly, resources, packaging, or distribution; it is
not required for every edit.

The local unsigned app bundle is written to `build/Wafer.app`.

## Direct Distribution

Use the release packaging script for outside-App-Store distribution:

```sh
WAFER_NOTARY_PROFILE=VibeMD scripts/package-release.sh
```

The script auto-detects a single `Developer ID Application` signing identity. If more than one identity exists, set `WAFER_SIGN_IDENTITY` to the exact identity name.

Create the notary profile once with:

```sh
xcrun notarytool store-credentials VibeMD --apple-id <apple-id> --team-id <team-id>
```

The final ZIP is written to `dist/Wafer-<version>.zip`.

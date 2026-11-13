# Open-source cleanup

## Goal

Remove personal information, developer-machine dependencies, and obsolete product naming from the publishable project without adding features.

## Context

The app already displays Wafer, but package names, protocols, tests, and release scripts still use an older identity. Release configuration and historical records contain personal details.

## Constraints

- Preserve the existing notarization profile name.
- Keep third-party attribution intact.
- Preserve unrelated local work.
- Do not change Git history, contact remotes, publish, or deploy.
- Use the requested independent fresh-context reviewer after verification, repeating after fixes until no changes remain.

## Done-when

- Publishable filenames and contents use Wafer, except for the notarization profile value.
- Code and scripts contain no personal account, feed, signing identity, or developer-machine path.
- Documentation uses neutral examples and distinguishes normalized historical records.
- Tests and release app assembly pass, including Quick Look resource verification.
- The requested independent reviewer reports no further changes.

## Decisions

- Release feed and public key are unset by default. The existing no-feed behavior disables update actions. Distributors supply these values and an explicit release repository.
- Removed the obsolete support-folder migration. Existing Wafer theme paths remain unchanged.
- Standard OS paths and synthetic test paths are portable platform references, not developer-machine dependencies.

## Verification

- `swift test`: passed, 577 tests, zero failures (240 core and 337 app).
- `python3 -m unittest discover -s Tests/ReleaseTools -v`: passed, three tests with fake network and packaging boundaries.
- `scripts/build-app.sh release`: passed.
- `scripts/verify-appex.sh build/Wafer.app`: passed, including resources, signature, and sandbox entitlement.
- Source inventory: 275 publishable files scanned, no personal identifiers or developer-machine paths. Remaining obsolete-name occurrences refer only to the preserved notarization profile.
- No obsolete names or personal paths found by `strings` in either built executable.
- Third-party resource and theme bytes remain unchanged. Renderer goldens match the original hashes when the naming substitutions alone are reversed; updated goldens verify current output.
- Preview artwork contained monitor-specific ICC metadata. Converted it to standard sRGB and removed EXIF metadata.
- Initial test failures exposed outdated snapshot hashes, the renamed fixture's character count, and an export test that observed file creation before completion. Updated expectations and made that test wait for completion. Full rerun passed.
- First independent review found one defect: Python tests created untracked bytecode caches. Added an ignore rule and reran the documented command to verify the caches stay ignored.
- Also generalized the historical hardware description and removed unrelated local-workflow details from records.
- Retained the notarization profile as explicitly requested. The project copyright uses a collective name under the request to remove personal references; third-party notices remain intact.
- Follow-up independent fresh-context review: no further changes needed. The reviewer rechecked all 275 publishable files and reran the three release-configuration tests. Swift tests and release assembly were not rerun because runtime code was unchanged after the successful checks above.

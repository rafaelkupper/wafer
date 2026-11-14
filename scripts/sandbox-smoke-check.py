#!/usr/bin/env python3
"""Assert smoke evidence, with stable exit codes for each release-gate phase."""
import json
import plistlib
import re
import sys
from pathlib import Path


def check(work, container, evidence, identifier, migration_only=False):
    def require(condition, phase, message):
        if not condition:
            print(f'FAIL phase {phase}: {message}', file=sys.stderr)
            raise SystemExit(phase)

    data = container / 'Data'
    require(data.is_dir(), 20, f'container not created: {data}')
    print('PASS phase 20: container created')

    def plist(path):
        try:
            return plistlib.loads(path.read_bytes())
        except (OSError, ValueError):
            return {}

    preferences = plist(data / f'Library/Preferences/{identifier}.plist')
    scroll = plist(data / 'Library/Preferences/dev.wafer.scroll-state.plist')
    require((work / 'scroll-seed.json').is_file() and (work / 'theme-seed.json').is_file()
            and (work / 'seed-paths.json').is_file(), 21, 'fixture evidence missing')
    require(preferences.get('appearanceSelection') == 'custom:Smoke Fixture', 21, 'theme preference not migrated')
    require(preferences.get('documentStatisticKind') == 'lines', 21, 'statistic preference not migrated')
    require(scroll.get('scroll-state-v2:smoke-migration') == (work / 'scroll-seed.json').read_bytes(),
            21, 'seeded scroll state not migrated')
    theme = data / 'Library/Application Support/Wafer/Themes/Smoke Fixture.json'
    require(theme.is_file() and theme.read_bytes() == (work / 'theme-seed.json').read_bytes(),
            21, 'custom theme not migrated')
    seeds = json.loads((work / 'seed-paths.json').read_text())
    require(all(not Path(p).exists() for p in seeds), 21, 'unsandboxed fixture files were not moved')
    print('PASS phase 21: seeded preferences, scroll state and theme migrated')

    try:
        logs = json.loads((evidence / 'unified.json').read_text())
    except (OSError, ValueError):
        require(False, 23, 'unified log evidence missing or malformed')
    require(isinstance(logs, list) and all(isinstance(e, dict) for e in logs), 23, 'invalid unified log format')
    require(any(e.get('subsystem') == 'dev.wafer.app' and e.get('category') == 'access' for e in logs),
            23, 'no Wafer access events captured; log coverage not established')

    if not migration_only:
        grants = preferences.get('folderAccessGrants', [])
        require(any(Path(g.get('path', '')).resolve() == (work / 'Documents').resolve()
                    and isinstance(g.get('bookmark'), bytes) and g['bookmark'] for g in grants),
                22, 'fixture folder grant not persisted with a bookmark')
        require((work / 'relaunch-pid').is_file(), 22, 'no relaunch recorded; run relaunch first')
        pid = int((work / 'relaunch-pid').read_text())
        restored = [e for e in logs if e.get('processID') == pid and e.get('category') == 'access']
        require(any(re.search(r'Restored access to [1-9]\d* of [1-9]\d* granted folders', e.get('eventMessage', ''))
                    for e in restored), 22, 'Wafer did not restore the folder grant after relaunch')
        require(not any(re.search('could not read|outside the granted folders|Could not (?:restore|access)',
                                  e.get('eventMessage', '')) for e in restored),
                22, 'Wafer refused fixture access after relaunch')
        print('PASS phase 22: bookmark persisted, restored, fixture document reopened without refused access')

    violations = [e for e in logs if e.get('subsystem') == 'com.apple.sandbox.reporting'
                  or e.get('senderImagePath', '').endswith('/Sandbox')
                  or re.search(r'\bdeny\(', e.get('eventMessage', ''))]
    require(not violations, 23, f'{len(violations)} unexpected sandbox violations; see {evidence / "unified.json"}')
    print('PASS phase 23: no sandbox violations (no allowlist)')


if __name__ == '__main__':
    work, container, evidence = map(Path, sys.argv[1:4])
    check(work, container, evidence, sys.argv[4], '--migration-only' in sys.argv[5:])

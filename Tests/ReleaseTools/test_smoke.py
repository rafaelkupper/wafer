import json
import plistlib
import shutil
import subprocess
import unittest

from fixtures import Fixture


@unittest.skipUnless(shutil.which('zsh'), 'zsh required')
class SandboxSmokeScriptTests(unittest.TestCase):
    """The smoke script must never touch the real app's data or other folders."""

    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.close)
        self.home = self.fixture.root / 'home'
        (self.home / 'Library/Containers').mkdir(parents=True)

    def run_script(self, *args, **env):
        environment = dict(self.fixture.env, HOME=str(self.home), **env)
        return subprocess.run([str(self.fixture.root / 'scripts/sandbox-smoke.sh'), *args],
                              env=environment, capture_output=True, text=True)

    def test_refuses_the_app_and_extension_identifiers(self):
        for identifier in ('dev.wafer.app', 'dev.wafer.app.quicklook', 'dev.example.reader'):
            for command in ('prepare', 'clean'):
                with self.subTest(identifier=identifier, command=command):
                    result = self.run_script(command, WAFER_SMOKE_BUNDLE_ID=identifier)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("must be a separate identifier containing 'smoke'", result.stderr)

    def test_clean_preserves_all_data_without_its_ownership_marker(self):
        work = self.fixture.root / 'not-made-by-smoke'
        work.mkdir()
        (work / 'keep.txt').write_text('keep')
        container = self.home / 'Library/Containers/dev.wafer.app.sandbox-smoke/Data'
        container.mkdir(parents=True)
        (container / 'made-by-smoke').write_text('remove')
        real = self.home / 'Library/Containers/dev.wafer.app/Data'
        real.mkdir(parents=True)
        (real / 'preferences').write_text('keep')

        result = self.run_script('clean', WAFER_SMOKE_DIR=str(work))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((work / 'keep.txt').read_text(), 'keep')
        self.assertIn('which this script did not create', result.stderr)
        self.assertEqual((container / 'made-by-smoke').read_text(), 'remove')
        self.assertEqual((real / 'preferences').read_text(), 'keep')

    def test_prepare_refuses_a_nonempty_directory_it_did_not_create(self):
        work = self.fixture.root / 'documents'
        work.mkdir()
        (work / 'notes.md').write_text('keep')
        app = self.fixture.root / 'Fixture.app'
        app.mkdir()

        result = self.run_script('prepare', WAFER_SMOKE_DIR=str(work), WAFER_SMOKE_APP=str(app))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn('use a fresh work directory and smoke ID', result.stderr)
        self.assertEqual(sorted(p.name for p in work.iterdir()), ['notes.md'])


class SandboxSmokeAssertionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.close)
        self.root = self.fixture.root
        self.work = self.root / 'work'
        self.evidence = self.root / 'evidence'
        self.container = self.root / 'container'
        self.identifier = 'dev.wafer.app.fixture-smoke'
        self.work.mkdir()
        self.evidence.mkdir()
        self.data = self.container / 'Data'
        self.prefs = self.data / f'Library/Preferences/{self.identifier}.plist'
        self.prefs.parent.mkdir(parents=True)
        self.preferences = {'appearanceSelection': 'custom:Smoke Fixture', 'documentStatisticKind': 'lines',
                            'folderAccessGrants': [{'path': str(self.work / 'Documents'), 'bookmark': b'fixture'}]}
        self.prefs.write_bytes(plistlib.dumps(self.preferences))
        (self.work / 'scroll-seed.json').write_bytes(b'fixture-scroll')
        (self.prefs.parent / 'dev.wafer.scroll-state.plist').write_bytes(plistlib.dumps(
            {'scroll-state-v2:smoke-migration': b'fixture-scroll'}))
        self.theme = self.data / 'Library/Application Support/Wafer/Themes/Smoke Fixture.json'
        self.theme.parent.mkdir(parents=True)
        self.theme.write_bytes(b'fixture-theme')
        (self.work / 'theme-seed.json').write_bytes(b'fixture-theme')
        (self.work / 'seed-paths.json').write_text(json.dumps([str(self.work / 'removed-seed')]))
        (self.work / 'relaunch-pid').write_text('123')
        self.logs = [{'processID': 123, 'subsystem': 'dev.wafer.app', 'category': 'access',
                      'eventMessage': 'Restored access to 1 of 1 granted folders'}]
        self.write_logs()

    def write_logs(self):
        (self.evidence / 'unified.json').write_text(json.dumps(self.logs))

    def check(self, expected, *arguments):
        result = subprocess.run(['python3', '-I', str(self.root / 'scripts/sandbox-smoke-check.py'),
                                 str(self.work), str(self.container), str(self.evidence), self.identifier, *arguments],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_valid_evidence_passes_then_missing_seeded_theme_fails_then_passes(self):
        self.check(0)
        self.theme.unlink()
        self.assertIn('custom theme not migrated', self.check(21).stderr)
        self.theme.write_bytes(b'fixture-theme')
        self.check(0)

    def test_container_missing_has_its_own_exit(self):
        shutil.rmtree(self.data)
        self.check(20)

    def test_each_migrated_preference_and_scroll_is_required(self):
        for key in ('appearanceSelection', 'documentStatisticKind'):
            with self.subTest(key=key):
                self.prefs.write_bytes(plistlib.dumps({k: v for k, v in self.preferences.items() if k != key}))
                self.check(21)
        self.prefs.write_bytes(plistlib.dumps(self.preferences))
        (self.prefs.parent / 'dev.wafer.scroll-state.plist').unlink()
        self.check(21)

    def test_bookmark_and_relaunch_restoration_are_required(self):
        self.prefs.write_bytes(plistlib.dumps(dict(self.preferences, folderAccessGrants=[])))
        self.check(22)
        self.prefs.write_bytes(plistlib.dumps(self.preferences))
        self.logs[0]['eventMessage'] = 'Restored access to 0 of 0 granted folders'
        self.write_logs()
        self.check(22)
        self.check(0, '--migration-only')

    def test_sandbox_reports_and_refused_access_fail_separate_phases(self):
        self.logs.append({'processID': 123, 'category': 'access', 'eventMessage': 'could not read image outside the granted folders'})
        self.write_logs()
        self.check(22)
        self.logs.pop()
        self.logs.append({'subsystem': 'com.apple.sandbox.reporting', 'eventMessage': 'Sandbox: Wafer(123) deny(1) file-read-data'})
        self.write_logs()
        self.check(23)


if __name__ == '__main__':
    unittest.main()

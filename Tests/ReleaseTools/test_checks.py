import json
import subprocess
import unittest

from fixtures import Fixture, ROOT


class CheckScriptTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.close)

    def run_script(self, name, *args, **env):
        return subprocess.run([str(self.fixture.root / 'scripts' / name), *args],
                              env=dict(self.fixture.env, **env), cwd='/', capture_output=True, text=True)

    def test_check_runs_swift_python_and_node_from_the_repository_root(self):
        result = self.run_script('check.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Ran 0 tests', result.stderr)  # Disposable Python suite, not this suite recursively.
        self.assertIn(['swift', 'test'], self.fixture.calls())
        self.assertIn(['node', 'Tests/JavaScript/app/fixture.cjs'], self.fixture.calls())

    def test_performance_flag_sets_the_existing_switch(self):
        for args, environment in [((), dict(WAFER_PERF_TESTS='1')), (('--perf',), dict(WAFER_PERF_TESTS='0'))]:
            with self.subTest(args=args):
                result = self.run_script('check.sh', *args, **environment)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((self.fixture.root / 'perf-test-mode.txt').read_text(), '1')

    def test_swift_failure_stops_subsequent_checks(self):
        result = self.run_script('check.sh', FAIL_COMMAND='swift test')
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        self.assertFalse(any(c[0] == 'node' for c in self.fixture.calls()))

    def test_vendored_manifest_matches_the_real_resources(self):
        result = subprocess.run(['python3', str(ROOT / 'scripts/verify-vendored-assets.py')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_checksum_missing_file_and_unrecorded_asset_stop_checks(self):
        root = self.fixture.root
        asset = root / 'Sources/WaferCore/Resources/katex/katex.min.js'
        for change in ('modified', 'missing', 'unrecorded'):
            with self.subTest(change=change):
                asset.write_text('fixture')
                extra = asset.with_name('extra.js')
                if change == 'modified':
                    asset.write_text('changed')
                elif change == 'missing':
                    asset.unlink()
                else:
                    extra.write_text('unrecorded')
                result = self.run_script('check.sh')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Vendored asset', result.stderr)
                self.assertFalse(any(c[0] == 'swift' for c in self.fixture.calls()))
                if extra.exists():
                    extra.unlink()

    def test_manifest_requires_provenance(self):
        manifest = self.fixture.root / 'docs/vendored-assets.json'
        data = json.loads(manifest.read_text())
        data['assets'][0]['version'] = ''
        manifest.write_text(json.dumps(data))
        result = self.run_script('check.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing vendored asset provenance', result.stderr)

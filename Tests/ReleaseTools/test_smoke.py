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

    def test_clean_deletes_only_a_work_directory_it_created(self):
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
        self.assertFalse(container.exists())
        self.assertEqual((real / 'preferences').read_text(), 'keep')

    def test_prepare_refuses_a_nonempty_directory_it_did_not_create(self):
        work = self.fixture.root / 'documents'
        work.mkdir()
        (work / 'notes.md').write_text('keep')
        app = self.fixture.root / 'Fixture.app'
        app.mkdir()

        result = self.run_script('prepare', WAFER_SMOKE_DIR=str(work), WAFER_SMOKE_APP=str(app))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn('must be new, empty, or made by this script', result.stderr)
        self.assertEqual(sorted(p.name for p in work.iterdir()), ['notes.md'])


if __name__ == '__main__':
    unittest.main()

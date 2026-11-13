import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

from fixtures import ROOT

spec = importlib.util.spec_from_file_location('check_source', ROOT / 'scripts/check-source.py')
source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source)


class SourceIdentityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='wafer-source-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.git('init', '-q')
        (self.root / 'Sources').mkdir()
        (self.root / 'Sources/Example.swift').write_text('original')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.org', 'commit', '-qm', 'Fixture')

    def git(self, *args):
        subprocess.run(['git', '-C', str(self.root), *args], check=True, capture_output=True)

    def test_clean_tree_allows_untracked_review_notes(self):
        (self.root / 'notes.txt').write_text('review notes')
        source.check(self.root)

    def test_unstaged_and_staged_tracked_changes_are_rejected(self):
        (self.root / 'Sources/Example.swift').write_text('changed')
        with self.assertRaisesRegex(SystemExit, 'clean source tree'):
            source.check(self.root)
        self.git('add', '.')
        with self.assertRaisesRegex(SystemExit, 'clean source tree'):
            source.check(self.root)

    def test_untracked_build_inputs_are_rejected(self):
        for directory in ('Sources', 'Resources', 'App'):
            with self.subTest(directory=directory):
                (self.root / directory).mkdir(exist_ok=True)
                path = self.root / directory / 'New file.txt'
                path.write_text('new input')
                with self.assertRaisesRegex(SystemExit, 'New file.txt'):
                    source.check(self.root)
                path.unlink()

    def test_rename_is_reported_with_its_destination(self):
        self.git('mv', 'Sources/Example.swift', 'Sources/Renamed.swift')
        with self.assertRaisesRegex(SystemExit, 'Sources/Renamed.swift'):
            source.check(self.root)

    def test_ignored_untracked_build_inputs_are_rejected(self):
        (self.root / '.gitignore').write_text('Sources/Local.swift\n')
        self.git('add', '.gitignore')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.org', 'commit', '-qm', 'Ignore local input')
        (self.root / 'Sources/Local.swift').write_text('uncommitted build input')
        with self.assertRaisesRegex(SystemExit, 'Sources/Local.swift'):
            source.check(self.root)

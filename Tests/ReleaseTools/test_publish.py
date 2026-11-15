import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

from fixtures import BASE_FEED, COMMIT, IDENTITY, NEW_FEED, Fixture
from test_release import release


ORIGINAL_RUN = release.run


@unittest.skipUnless(shutil.which('zsh') and Path('/usr/libexec/PlistBuddy').exists(), 'macOS packaging tools required')
class PublishTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.close)
        self.root = self.fixture.root
        self.review = self.root / 'dist/updates/1.0.0-2'
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, self.fixture.env).start()
        patch.object(release, 'ROOT', self.root).start()
        # Network reads are fixtures; every signing, packaging, git, and gh command runs a PATH stub.
        patch.object(release, 'run', side_effect=lambda *args, **kwargs: ORIGINAL_RUN(
            *args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kwargs)).start()
        self.fetch = patch.object(release, 'live_feed', return_value=BASE_FEED).start()
        self.invoke()
        (self.root / 'calls.jsonl').write_text('')

    def invoke(self, publish=False, repository='example/releases'):
        args = ['release.py', '--repository', repository, '--sparkle-tools', str(self.root / 'bin')]
        if publish:
            args += ['--publish', str(self.review)]
        with patch('sys.argv', args):
            release.main()

    def state(self):
        return json.loads((self.root / 'remote.json').read_text())

    def save_state(self, state):
        (self.root / 'remote.json').write_text(json.dumps(state))

    def test_receipt_binds_prepared_artifacts_to_source_and_distributor(self):
        receipt = json.loads((self.review / 'review.json').read_text())
        for key, value in dict(sourceCommit=COMMIT, repository='example/releases',
                               feedURL='https://updates.example.org/appcast.xml',
                               signingIdentity=IDENTITY, publicKey='fixture-key',
                               baseFeedSHA256=hashlib.sha256(BASE_FEED).hexdigest()).items():
            self.assertEqual(receipt[key], value)
        for name, digest in receipt['sha256'].items():
            self.assertEqual(release.sha256(self.review / name), digest)

    def test_publish_refuses_each_identity_mismatch_before_remote_mutation(self):
        receipt_file = self.review / 'review.json'
        original = json.loads(receipt_file.read_text())
        for key in ('sourceCommit', 'repository', 'feedURL', 'publicKey', 'version', 'build'):
            with self.subTest(key=key):
                changed = dict(original, **{key: 'mismatch'})
                receipt_file.write_text(json.dumps(changed))
                with self.assertRaisesRegex(SystemExit, key):
                    self.invoke(publish=True)
                self.assertFalse(any(c[0] == 'gh' for c in self.fixture.calls()))
        receipt_file.write_text(json.dumps(original))
        with patch.dict(os.environ, SOURCE_COMMIT='b' * 40):
            with self.assertRaisesRegex(SystemExit, 'sourceCommit'):
                self.invoke(publish=True)
        with self.assertRaisesRegex(SystemExit, 'repository'):
            self.invoke(publish=True, repository='elsewhere/releases')
        info_file = self.root / 'App/Info.plist'
        original_info = plistlib.loads(info_file.read_bytes())
        for key in ('SUPublicEDKey', 'SUFeedURL'):
            info_file.write_bytes(plistlib.dumps(dict(original_info, **{key: 'changed'})))
            with self.assertRaisesRegex(SystemExit, 'publicKey|feedURL'):
                self.invoke(publish=True)
        info_file.write_bytes(plistlib.dumps(original_info))
        with patch.dict(os.environ, SIGNING_IDENTITY='Developer ID Application: Other (FIXTURE)'):
            with self.assertRaisesRegex(SystemExit, 'signing identity'):
                self.invoke(publish=True)
        self.assertIsNone(self.state()['release'])
        self.assertFalse(any(c[0] == 'gh' for c in self.fixture.calls()))

    def test_publish_refuses_changed_artifacts(self):
        (self.review / 'Wafer-1.0.0.zip').write_bytes(b'changed')
        with self.assertRaisesRegex(SystemExit, 'Review artifact changed'):
            self.invoke(publish=True)
        self.assertFalse(any(c[0] == 'gh' for c in self.fixture.calls()))

    def test_publish_targets_reviewed_commit_and_can_repeat_after_success(self):
        self.invoke(publish=True)
        calls = self.fixture.calls()
        create = next(c for c in calls if c[:3] == ['gh', 'release', 'create'])
        self.assertEqual(create[create.index('--target') + 1], COMMIT)
        self.assertEqual(create[create.index('--repo') + 1], 'example/releases')
        self.assertEqual(self.state()['feed'], NEW_FEED.decode())
        # Both a stale CDN feed and the updated feed permit retry.
        self.invoke(publish=True)
        self.fetch.return_value = NEW_FEED
        self.invoke(publish=True)
        calls = self.fixture.calls()
        self.assertEqual(sum(c[:3] == ['gh', 'release', 'create'] for c in calls), 1)
        self.assertEqual(sum(c[0] == 'git' and c[-1] == 'push' for c in calls), 1)

    def test_rerun_recovers_release_created_without_asset_then_failed_upload(self):
        with patch.dict(os.environ, FAIL_COMMAND='gh release create'):
            with self.assertRaises(subprocess.CalledProcessError):
                self.invoke(publish=True)
        self.assertIsNotNone(self.state()['release'])
        self.assertEqual(self.state()['feed'], BASE_FEED.decode())
        with patch.dict(os.environ, FAIL_COMMAND='gh release upload'):
            with self.assertRaises(subprocess.CalledProcessError):
                self.invoke(publish=True)
        # The upload took effect before its error, so the next run verifies and skips it.
        self.invoke(publish=True)
        calls = self.fixture.calls()
        self.assertEqual(sum(c[:3] == ['gh', 'release', 'create'] for c in calls), 1)
        self.assertEqual(sum(c[:3] == ['gh', 'release', 'upload'] for c in calls), 1)
        self.assertEqual(self.state()['feed'], NEW_FEED.decode())

    def test_rerun_after_failed_feed_push_reuses_matching_release(self):
        with patch.dict(os.environ, FAIL_COMMAND='git push'):
            with self.assertRaises(subprocess.CalledProcessError):
                self.invoke(publish=True)
        self.assertIsNotNone(self.state()['release'])
        self.assertEqual(self.state()['feed'], BASE_FEED.decode())
        self.invoke(publish=True)
        calls = self.fixture.calls()
        self.assertEqual(sum(c[:3] == ['gh', 'release', 'create'] for c in calls), 1)
        self.assertEqual(self.state()['feed'], NEW_FEED.decode())

    def test_rerun_after_push_took_effect_before_error_skips_feed_commit(self):
        with patch.dict(os.environ, FAIL_COMMAND='git push', PUSH_APPLIED='1'):
            with self.assertRaises(subprocess.CalledProcessError):
                self.invoke(publish=True)
        self.assertEqual(self.state()['feed'], NEW_FEED.decode())
        self.fetch.return_value = NEW_FEED
        self.invoke(publish=True)
        calls = self.fixture.calls()
        self.assertEqual(sum(c[0] == 'git' and 'commit' in c for c in calls), 1)

    def test_rerun_refuses_conflicting_remote_tag_asset_or_feed(self):
        self.invoke(publish=True)
        original = self.state()
        for mismatch in ('commit', 'asset', 'feed'):
            with self.subTest(mismatch=mismatch):
                state = json.loads(json.dumps(original))
                if mismatch == 'commit':
                    state['release']['commit'] = 'b' * 40
                elif mismatch == 'asset':
                    state['release']['assets']['Wafer-1.0.0.zip'] = b'other'.hex()
                else:
                    state['feed'] = '<rss>newer</rss>'
                self.save_state(state)
                with self.assertRaisesRegex(SystemExit, 'does not match|feed changed'):
                    self.invoke(publish=True)
                self.assertEqual(self.state(), state)

    def test_existing_tag_without_release_is_validated_before_creation(self):
        state = self.state()
        state['tag'] = 'b' * 40
        self.save_state(state)
        with self.assertRaisesRegex(SystemExit, 'Release tag does not match source commit'):
            self.invoke(publish=True)
        self.assertEqual(self.state(), state)
        self.assertFalse(any(c[:3] in (['gh', 'release', 'create'], ['gh', 'release', 'upload'])
                             or (c[0] == 'git' and c[-1] == 'push') for c in self.fixture.calls()))
        state['tag'] = COMMIT
        self.save_state(state)
        self.invoke(publish=True)
        self.assertEqual(self.state()['release']['commit'], COMMIT)

    def test_missing_tag_reported_as_unknown_commit_is_absent(self):
        # GitHub answers a missing tag on the commits endpoint with 422, not 404.
        with patch.dict(os.environ, MISSING_TAG_ERROR='gh: No commit found for SHA: v1.0.0 (HTTP 422)'):
            self.invoke(publish=True)
        self.assertEqual(self.state()['release']['commit'], COMMIT)
        self.assertEqual(self.state()['feed'], NEW_FEED.decode())

    def test_tag_lookup_failure_stops_before_mutation(self):
        original = self.state()
        with patch.dict(os.environ, FAIL_COMMAND='gh api repos/example/releases/commits/v1.0.0'):
            with self.assertRaisesRegex(SystemExit, 'Cannot inspect release tag'):
                self.invoke(publish=True)
        self.assertEqual(self.state(), original)

    def test_dirty_preparation_refuses_packaging(self):
        with patch.dict(os.environ, SOURCE_STATUS=' M Sources/Example.swift'):
            # Use a new destination; cleanliness is checked before packaging.
            with self.assertRaises(subprocess.CalledProcessError):
                release.prepare(self.root / 'new-review', '1.0.0', 2, 'fixture-key',
                                'https://example.org/feed', BASE_FEED, self.root / 'bin', 'example/releases')
        self.assertFalse((self.root / 'new-review').exists())

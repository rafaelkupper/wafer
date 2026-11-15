import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

from fixtures import CORE_FILES, IDENTITY, ROOT, Fixture

SANDBOX_ENTITLEMENTS = {
    'com.apple.security.app-sandbox': True,
    'com.apple.security.files.user-selected.read-write': True,
    'com.apple.security.files.bookmarks.app-scope': True,
    'com.apple.security.network.client': True,
    'com.apple.security.print': True,
    # Sparkle's sandboxed installer: https://sparkle-project.org/documentation/sandboxing/
    'com.apple.security.temporary-exception.mach-lookup.global-name': ['dev.wafer.app-spks', 'dev.wafer.app-spki'],
}


class SandboxConfigurationTests(unittest.TestCase):
    def test_app_entitlements_are_the_reviewed_sandbox_set(self):
        self.assertEqual(plistlib.loads((ROOT / 'App/Wafer.entitlements').read_bytes()), SANDBOX_ENTITLEMENTS)

    def test_sparkle_uses_the_installer_service_and_not_the_downloader(self):
        info = plistlib.loads((ROOT / 'App/Info.plist').read_bytes())
        self.assertIs(info['SUEnableInstallerLauncherService'], True)
        self.assertNotIn('SUEnableDownloaderService', info)

    def test_first_sandboxed_launch_moves_preferences_scroll_state_and_themes(self):
        manifest = plistlib.loads((ROOT / 'App/container-migration.plist').read_bytes())
        self.assertEqual(manifest, {'Move': [
            '${Library}/Preferences/dev.wafer.app.plist',
            '${Library}/Preferences/dev.wafer.scroll-state.plist',
            '${ApplicationSupport}/Wafer',
        ]})


@unittest.skipUnless(shutil.which('zsh') and Path('/usr/libexec/PlistBuddy').exists(), 'macOS packaging tools required')
class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.close)
        self.root = self.fixture.root

    def run_script(self, name, *args, **env):
        return subprocess.run([str(self.root / 'scripts' / name), *map(str, args)],
                              env=dict(self.fixture.env, **env), capture_output=True, text=True)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_the_callers_release_settings_do_not_reach_the_fixture(self):
        with tempfile.TemporaryDirectory() as outside:
            marker = Path(outside) / 'release-in-progress'
            marker.write_text('real release output')
            with patch.dict(os.environ, WAFER_DIST_DIR=outside, WAFER_SKIP_NOTARIZATION='1'):
                fixture = Fixture()
            self.addCleanup(fixture.close)
            self.assertNotIn('WAFER_DIST_DIR', fixture.env)
            self.assertNotIn('WAFER_SKIP_NOTARIZATION', fixture.env)
            result = subprocess.run([str(fixture.root / 'scripts/package-release.sh')],
                                    env=fixture.env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual([path.name for path in Path(outside).iterdir()], ['release-in-progress'])

    def test_build_checks_both_layouts_and_strips_only_appex_runtimes(self):
        for nested in (True, False):
            with self.subTest(nested=nested):
                if not nested:
                    for bundle in self.fixture.products.glob('Wafer_*.bundle'):
                        shutil.rmtree(bundle)
                    self.fixture.make_resources(nested=False)
                self.assert_success(self.run_script('build-app.sh', 'release'))
                calls = [c for c in self.fixture.calls() if c[:2] == ['swift', 'build']]
                self.assertEqual(sum('--show-bin-path' in c for c in calls), 1 if nested else 2)
                self.assertEqual(sum('--show-bin-path' not in c for c in calls), 1 if nested else 2)
                app = self.root / 'build/Wafer.app'
                info = plistlib.loads((app / 'Contents/PlugIns/WaferQuickLook.appex/Contents/Info.plist').read_bytes())
                self.assertNotIn('QLIsDataBasedPreview', info)
                core = 'Wafer_WaferCore.bundle/' + ('Contents/Resources/' if nested else '')
                for resource in CORE_FILES:
                    self.assertTrue((app / 'Contents/Resources' / core / resource).is_file())
                    in_appex = app / 'Contents/PlugIns/WaferQuickLook.appex/Contents/Resources' / core / resource
                    self.assertEqual(in_appex.is_file(), resource.startswith(('reader-', 'gemoji-')))
                self.assert_success(self.run_script('verify-appex.sh', app))
        self.assertFalse(any(c[0] in ('lsregister', 'pluginkit') for c in self.fixture.calls()))

    def test_release_identity_is_explicit_and_both_verifiers_enforce_the_mode(self):
        self.assert_success(self.run_script('build-app.sh', 'release', '--release-identity'))
        app = self.root / 'build/Wafer.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'dev.wafer.app')
        self.assertIn('SUFeedURL', info)
        self.assertEqual((app / 'Contents/Resources/container-migration.plist').read_bytes(),
                         (self.root / 'App/container-migration.plist').read_bytes())
        for verifier in ('verify-app.sh', 'verify-appex.sh'):
            self.assert_success(self.run_script(verifier, '--release-identity'))
            self.assertNotEqual(self.run_script(verifier).returncode, 0)
        self.assert_success(self.run_script('build-app.sh', 'release'))
        for verifier in ('verify-app.sh', 'verify-appex.sh'):
            self.assert_success(self.run_script(verifier))
            self.assertNotEqual(self.run_script(verifier, '--release-identity').returncode, 0)

    def test_build_refuses_missing_bundles_or_key_resources_before_signing(self):
        for missing in ('Wafer_WaferCore.bundle', 'Wafer_WaferApp.bundle',
                        'Wafer_WaferCore.bundle/Contents/Resources/katex.min.js',
                        'Wafer_WaferApp.bundle/Contents/Resources/Themes/GitHub Light.json'):
            with self.subTest(missing=missing):
                path = self.fixture.products / missing
                if path.is_dir():
                    shutil.rmtree(path)
                else:
                    path.unlink()
                result = self.run_script('build-app.sh', 'release')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('missing required resource', result.stderr)
                self.assertFalse(any(c[0] == 'codesign' for c in self.fixture.calls()))
                self.fixture.make_resources(nested=True)

    def test_registration_is_opt_in_and_uses_built_paths(self):
        self.assert_success(self.run_script('build-app.sh', 'release', WAFER_REGISTER_APP='1'))
        calls = self.fixture.calls()
        sign = next(i for i, c in enumerate(calls) if c[0] == 'codesign')
        register = next(i for i, c in enumerate(calls) if c[0] == 'lsregister')
        plugin = next(i for i, c in enumerate(calls) if c[0] == 'pluginkit')
        self.assertLess(sign, register)
        self.assertLess(register, plugin)
        self.assertEqual(calls[register][1:], ['-f', str(self.root / 'build/Wafer.app')])
        self.assertEqual(calls[plugin][1:], ['-a', str(self.root / 'build/Wafer.app/Contents/PlugIns/WaferQuickLook.appex')])

    def test_build_ignores_stale_bundles_and_verifier_rejects_any_extra(self):
        for name in ('Wafer_WaferCoreTests.bundle', 'Wafer_Stale.bundle'):
            (self.fixture.products / name).mkdir()
        self.assert_success(self.run_script('build-app.sh', 'release'))
        app = self.root / 'build/Wafer.app'
        expected = {
            'Contents/Resources/Wafer_WaferCore.bundle',
            'Contents/Resources/Wafer_WaferApp.bundle',
            'Contents/PlugIns/WaferQuickLook.appex/Contents/Resources/Wafer_WaferCore.bundle',
        }
        self.assertEqual({str(p.relative_to(app)) for p in app.rglob('*.bundle')}, expected)
        self.assert_success(self.run_script('verify-appex.sh'))
        for extra in ('Contents/Resources/Wafer_WaferCoreTests.bundle',
                      'Contents/PlugIns/WaferQuickLook.appex/Contents/Resources/Stale.bundle'):
            path = app / extra
            path.mkdir()
            result = self.run_script('verify-appex.sh')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('unexpected resource bundle: ' + extra, result.stderr)
            path.rmdir()

    def test_verifiers_use_unique_temporary_entitlement_files(self):
        self.assert_success(self.run_script('build-app.sh', 'release'))
        temporary = self.root / 'temporary'
        temporary.mkdir()
        old_template = temporary / 'wafer-appex-entitlements.XXXXXX.plist'
        old_template.write_text('preserve another invocation')
        for _ in range(2):
            self.assert_success(self.run_script('verify-appex.sh', TMPDIR=str(temporary)))
            self.assert_success(self.run_script('verify-app.sh', TMPDIR=str(temporary)))
        self.assertEqual(old_template.read_text(), 'preserve another invocation')
        self.assertEqual(list(temporary.iterdir()), [old_template])

    def test_build_signs_the_app_last_and_ad_hoc_with_the_sandbox_entitlements(self):
        self.assert_success(self.run_script('build-app.sh', 'release'))
        app = self.root / 'build/Wafer.app'
        signing = [c for c in self.fixture.calls() if c[0] == 'codesign' and '--sign' in c]
        self.assertEqual([c[-1] for c in signing], [str(app / 'Contents/PlugIns/WaferQuickLook.appex'), str(app)])
        app_signing = signing[-1]
        self.assertEqual(app_signing[app_signing.index('--sign') + 1], '-')
        self.assertEqual(app_signing[app_signing.index('--entitlements') + 1], str(self.root / 'build/Development.entitlements'))
        self.assertNotIn('--options', app_signing)
        manifest = app / 'Contents/Resources/container-migration.plist'
        self.assertFalse(manifest.exists())
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'dev.wafer.app.dev')
        self.assertNotIn('SUFeedURL', info)
        self.assertNotIn('SUPublicEDKey', info)
        result = self.run_script('verify-app.sh', app)
        self.assert_success(result)
        self.assertIn('Verified app signature and sandbox entitlements', result.stdout)

    def test_app_verifier_requires_the_exact_entitlement_set(self):
        self.assert_success(self.run_script('build-app.sh', 'release', '--release-identity'))
        missing = dict(SANDBOX_ENTITLEMENTS)
        del missing['com.apple.security.print']
        lookups = 'com.apple.security.temporary-exception.mach-lookup.global-name'
        for entitlements, message in [
            ({}, 'missing entitlement com.apple.security.app-sandbox'),
            (missing, 'missing entitlement com.apple.security.print'),
            (dict(SANDBOX_ENTITLEMENTS, **{'com.apple.security.files.downloads.read-write': True}),
             'unexpected entitlement com.apple.security.files.downloads.read-write'),
            (dict(SANDBOX_ENTITLEMENTS, **{'com.apple.security.network.client': False}),
             'entitlement com.apple.security.network.client is False'),
            (dict(SANDBOX_ENTITLEMENTS, **{lookups: ['dev.wafer.app-spks']}), 'entitlement ' + lookups + ' is'),
        ]:
            with self.subTest(message=message):
                result = self.run_script('verify-app.sh', '--release-identity', APP_ENTITLEMENTS=json.dumps(entitlements))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
        self.assert_success(self.run_script('verify-app.sh', '--release-identity'))

    def test_app_verifier_checks_sparkle_keys_installer_and_migration_manifest(self):
        self.assert_success(self.run_script('build-app.sh', 'release', '--release-identity'))
        app = self.root / 'build/Wafer.app'
        info_path = app / 'Contents/Info.plist'
        original = info_path.read_bytes()
        info = plistlib.loads(original)
        for change, message in [
            ({'SUEnableInstallerLauncherService': False}, 'must set SUEnableInstallerLauncherService'),
            ({'SUEnableDownloaderService': True}, 'must not set SUEnableDownloaderService'),
            ({'CFBundleIdentifier': 'dev.example.other'}, "do not match the bundle identifier 'dev.example.other'"),
        ]:
            with self.subTest(change=change):
                info_path.write_bytes(plistlib.dumps(dict(info, **change)))
                result = self.run_script('verify-app.sh', '--release-identity')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
        info_path.write_bytes(original)
        manifest = app / 'Contents/Resources/container-migration.plist'
        original_manifest = manifest.read_bytes()
        manifest.write_bytes(plistlib.dumps({'Move': []}))
        result = self.run_script('verify-app.sh', '--release-identity')
        self.assertIn('no Move entries', result.stderr)
        self.assertIn('differs from App/container-migration.plist', result.stderr)
        manifest.unlink()
        self.assertIn('container migration manifest not found', self.run_script('verify-app.sh', '--release-identity').stderr)
        manifest.write_bytes(original_manifest)
        installer = app / 'Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc'
        shutil.rmtree(installer)
        self.assertIn("Sparkle's Installer.xpc is missing", self.run_script('verify-app.sh', '--release-identity').stderr)
        installer.mkdir()
        self.assert_success(self.run_script('verify-app.sh', '--release-identity'))

    def test_release_signs_the_app_with_its_entitlements_and_the_hardened_runtime(self):
        self.assert_success(self.run_script('package-release.sh'))
        calls = self.fixture.calls()
        app = str(self.root / 'build/Wafer.app')
        signing = [c for c in calls if c[0] == 'codesign' and '--timestamp' in c and c[-1] == app]
        self.assertEqual(len(signing), 1)
        self.assertEqual(signing[0][signing[0].index('--options') + 1], 'runtime')
        self.assertEqual(signing[0][signing[0].index('--entitlements') + 1], str(self.root / 'App/Wafer.entitlements'))
        self.assertEqual(signing[0][signing[0].index('--sign') + 1], IDENTITY)
        signed_at = calls.index(signing[0])
        distribution_checks = [i for i, c in enumerate(calls) if c[0] == 'codesign' and '-dv' in c and c[-1] == app]
        self.assertTrue(distribution_checks and all(i > signed_at for i in distribution_checks))

    def test_release_refuses_an_app_without_developer_id_or_hardened_runtime(self):
        for environment, message in [
            (dict(CODESIGN_FLAGS='none'), 'not signed with the hardened runtime'),
            (dict(SIGNING_IDENTITY='Apple Development: Fixture Publisher (FIXTURE)'), 'not signed with a Developer ID Application identity'),
        ]:
            with self.subTest(environment=environment):
                result = self.run_script('package-release.sh', **environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse((self.root / 'dist/Wafer-1.0.0.zip').exists())

    def test_release_generates_symbols_then_strips_shipping_copies_before_signing(self):
        self.assert_success(self.run_script('package-release.sh'))
        calls = self.fixture.calls()
        for product in ('Wafer', 'WaferQuickLook'):
            relative = f'{product}.dSYM/Contents/Resources/DWARF/{product}'
            self.assertTrue((self.root / 'build' / relative).is_file())
            self.assertTrue((self.root / 'dist' / relative).is_file())
            symbols = next(i for i, c in enumerate(calls) if c[:2] == ['xcrun', 'dsymutil']
                           and c[2] == str(self.fixture.products / product))
            stripping = next(i for i, c in enumerate(calls) if c[0] == 'strip')
            self.assertLess(symbols, stripping)
        stripping = next(i for i, c in enumerate(calls) if c[0] == 'strip')
        self.assertEqual(calls[stripping][1:3], ['-S', '-x'])
        self.assertTrue(all('/build/Wafer.app/' in path for path in calls[stripping][3:]))
        self.assertTrue(all(i > stripping for i, c in enumerate(calls) if c[0] == 'codesign'))
        for build in (c for c in calls if c[:2] == ['swift', 'build']):
            self.assertIn('-debug-prefix-map', build)
            self.assertIn('-file-prefix-map', build)
            self.assertIn(str(self.root) + '=/wafer', build)

    def test_password_credentials_are_rejected_without_leaking_to_argv(self):
        secret = 'fixture-password-never-in-argv'
        result = self.run_script('package-release.sh', WAFER_NOTARY_PROFILE='',
                                 WAFER_APPLE_ID='fixture@example.org', WAFER_APP_PASSWORD=secret,
                                 WAFER_TEAM_ID='FIXTURE')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Set WAFER_NOTARY_PROFILE', result.stderr)
        self.assertNotIn(secret, result.stdout + result.stderr + repr(self.fixture.calls()))
        self.assertFalse(any(c[0] == 'xcrun' for c in self.fixture.calls()))

    def test_dirty_packaging_stops_before_build_or_signing(self):
        result = self.run_script('package-release.sh', SOURCE_STATUS=' M Sources/Example.swift')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('clean source tree', result.stderr)
        self.assertFalse(any(c[0] in ('swift', 'codesign', 'xcrun') for c in self.fixture.calls()))

    def test_verify_rejects_missing_resources_unused_runtime_and_network_entitlement(self):
        self.assert_success(self.run_script('build-app.sh', 'release'))
        resources = self.root / 'build/Wafer.app/Contents/PlugIns/WaferQuickLook.appex/Contents/Resources/Wafer_WaferCore.bundle/Contents/Resources'
        for missing in ('reader-theme.css', 'gemoji-shortcodes.json', 'gemoji-LICENSE.txt'):
            path = resources / missing
            path.unlink()
            self.assertNotEqual(self.run_script('verify-appex.sh').returncode, 0)
            path.write_text('fixture')
        (resources / 'mermaid.min.js').write_text('unused')
        result = self.run_script('verify-appex.sh')
        self.assertIn('unused Mermaid or KaTeX', result.stderr)
        (resources / 'mermaid.min.js').unlink()
        result = self.run_script('verify-appex.sh', NETWORK_ENTITLEMENT='1')
        self.assertIn('must not request com.apple.security.network.client', result.stderr)
        result = self.run_script('verify-appex.sh', LINK_WEBKIT='1')
        self.assertIn('must not link WebKit', result.stderr)
        info = self.root / 'build/Wafer.app/Contents/PlugIns/WaferQuickLook.appex/Contents/Info.plist'
        original = info.read_bytes()
        plist = plistlib.loads(original)
        plist['NSExtension'].setdefault('NSExtensionAttributes', {})['QLIsDataBasedPreview'] = True
        info.write_bytes(plistlib.dumps(plist))
        result = self.run_script('verify-appex.sh')
        self.assertIn('must be view-based', result.stderr)
        info.write_bytes(original)
        self.assert_success(self.run_script('verify-appex.sh'))

    def test_package_refuses_nonempty_external_dist_including_symlink_and_hidden_file(self):
        external = self.root / 'external'
        external.mkdir()
        marker = external / '.keep'
        marker.write_text('preserve')
        link = self.root / 'dist/escape'
        link.parent.mkdir()
        link.symlink_to(external, target_is_directory=True)
        for dist in (external, link):
            with self.subTest(dist=dist):
                result = self.run_script('package-release.sh', WAFER_DIST_DIR=str(dist))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('must be new or empty', result.stderr)
                self.assertEqual(marker.read_text(), 'preserve')
                self.assertEqual(self.fixture.calls(), [])

    def test_package_removes_only_known_artifacts_and_signs_inside_out(self):
        dist = self.root / 'dist'
        dist.mkdir()
        for name in ('notes.txt', 'appcast.xml', 'review.json', 'notarytool-other.json'):
            (dist / name).write_text('preserve')
        (dist / 'updates').mkdir()
        (dist / 'updates/receipt').write_text('preserve')
        (dist / 'Wafer-directory.zip').mkdir()
        (dist / 'Wafer-link.zip').symlink_to(dist / 'notes.txt')
        for name in ('Wafer-old.zip', 'notarytool-submit.json', 'notarytool-log.json'):
            (dist / name).write_text('old')
        self.assert_success(self.run_script('package-release.sh'))
        for name in ('notes.txt', 'appcast.xml', 'review.json', 'notarytool-other.json', 'updates/receipt'):
            self.assertEqual((dist / name).read_text(), 'preserve')
        self.assertTrue((dist / 'Wafer-directory.zip').is_dir())
        self.assertFalse((dist / 'Wafer-old.zip').exists())
        self.assertFalse((dist / 'Wafer-link.zip').is_symlink())
        self.assertFalse((dist / 'notarytool-log.json').exists())
        calls = self.fixture.calls()
        signed = [c[-1] for c in calls if c[0] == 'codesign' and '--timestamp' in c]
        base = self.root / 'build/Wafer.app'
        sparkle = base / 'Contents/Frameworks/Sparkle.framework'
        self.assertEqual(signed, [str(sparkle / 'Versions/B' / p) for p in (
            'XPCServices/Installer.xpc', 'XPCServices/Downloader.xpc', 'Autoupdate', 'Updater.app')]
            + [str(sparkle), str(base / 'Contents/PlugIns/WaferQuickLook.appex'), str(base)])
        archives = [c for c in calls if c[0] == 'ditto']
        self.assertEqual([c[1:-2] for c in archives], [['-c', '-k', '--norsrc', '--noextattr', '--noacl', '--keepParent']] * 2)
        self.assertEqual([c[-1] for c in archives], [str(dist / 'Wafer-1.0.0-notarization.zip'), str(dist / 'Wafer-1.0.0.zip')])
        submit = next(i for i, c in enumerate(calls) if c[:3] == ['xcrun', 'notarytool', 'submit'])
        staple = next(i for i, c in enumerate(calls) if c[:3] == ['xcrun', 'stapler', 'staple'])
        final_zip = next(i for i, c in enumerate(calls) if c == archives[1])
        self.assertLess(submit, staple)
        self.assertLess(staple, final_zip)
        extraction = next(c[-1] for c in calls if c[0] == 'codesign' and '/Wafer.app' in c[-1] and 'wafer-release-test-' not in c[-1])
        self.assertFalse(Path(extraction).parent.exists())

    def test_new_or_empty_external_dist_is_allowed(self):
        for exists in (False, True):
            with self.subTest(exists=exists):
                dist = self.root / ('empty' if exists else 'new')
                if exists:
                    dist.mkdir()
                self.assert_success(self.run_script('package-release.sh', WAFER_DIST_DIR=str(dist)))
                self.assertTrue((dist / 'Wafer-1.0.0.zip').is_file())

    def test_failed_build_signing_or_notarization_stops_before_final_archive(self):
        for command in ('swift build -c', 'codesign --force --timestamp', 'xcrun notarytool submit'):
            with self.subTest(command=command):
                dist = self.root / 'dist'
                if dist.exists():
                    shutil.rmtree(dist)
                result = self.run_script('package-release.sh', FAIL_COMMAND=command)
                self.assertEqual(result.returncode, 23 if not command.startswith('xcrun') else 1, result.stdout + result.stderr)
                self.assertFalse((dist / 'Wafer-1.0.0.zip').exists())
                if command.startswith('xcrun'):
                    self.assertTrue((dist / 'notarytool-log.json').is_file())
        result = self.run_script('package-release.sh', NOTARY_STATUS='Invalid')
        self.assertIn("status 'Invalid'", result.stderr)
        self.assertFalse((self.root / 'dist/Wafer-1.0.0.zip').exists())

    def test_failed_extracted_signature_cleans_up_and_reports_failure(self):
        result = self.run_script('package-release.sh', FAIL_EXTRACTED_SIGNATURE='1')
        self.assertEqual(result.returncode, 1)
        self.assertIn('extracted app fails signature verification', result.stderr)
        extraction = self.fixture.calls()[-1][-1]
        self.assertTrue(extraction.endswith('/Wafer.app'))
        self.assertFalse(Path(extraction).parent.exists())

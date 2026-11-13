import importlib.util
import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/release.py"
spec = importlib.util.spec_from_file_location("wafer_release", SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseConfigurationTests(unittest.TestCase):
    def test_unconfigured_checkout_stops_before_network_or_packaging(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "App").mkdir()
            version = {"CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1"}
            (root / "App/Info.plist").write_bytes(plistlib.dumps(version))
            (root / "App/QuickLook-Info.plist").write_bytes(plistlib.dumps(version))
            with patch("sys.argv", [str(SCRIPT), "--repository", "example/releases"]), \
                    patch.object(release, "ROOT", root), \
                    patch.object(release, "live_feed") as fetch, \
                    patch.object(release, "run") as run:
                with self.assertRaisesRegex(SystemExit, "Configure SUFeedURL and SUPublicEDKey"):
                    release.main()
                fetch.assert_not_called()
                run.assert_not_called()

    def test_configured_manifest_supplies_distributors_update_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "App").mkdir()
            version = {"CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1"}
            info = dict(version, SUFeedURL="https://updates.example.org/appcast.xml", SUPublicEDKey="distributor-key")
            (root / "App/Info.plist").write_bytes(plistlib.dumps(info))
            (root / "App/QuickLook-Info.plist").write_bytes(plistlib.dumps(version))
            with patch.object(release, "ROOT", root):
                self.assertEqual(release.manifest(), ("1.0.0", 1, "distributor-key", info["SUFeedURL"]))

    def test_preparation_uses_selected_repository_and_feed(self):
        feed = "https://updates.example.org/appcast.xml"
        with patch("sys.argv", [str(SCRIPT), "--repository", "example/releases"]), \
                patch.object(release, "manifest", return_value=("1.0.0", 1, "key", feed)), \
                patch.object(release, "live_feed", return_value=b"<rss><channel/></rss>") as fetch, \
                patch.object(release, "prepare") as prepare, \
                patch.object(release, "publish") as publish:
            release.main()
            fetch.assert_called_once_with(feed)
            self.assertEqual(prepare.call_args.args[-1], "example/releases")
            publish.assert_not_called()


if __name__ == "__main__":
    unittest.main()

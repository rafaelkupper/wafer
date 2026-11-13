#!/usr/bin/env python3
"""Prepare a notarized Wafer update for review, or publish a reviewed one.

See docs/UPDATES.md. Preparation publishes nothing.
"""
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = "Wafer"
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
# SwiftPM unpacks Sparkle's tools next to the framework it links, so they
# always match the embedded version.
SPARKLE_TOOLS = ROOT / ".build/artifacts/sparkle/Sparkle/bin"
SPARKLE_HELPERS = (
    "XPCServices/Installer.xpc",
    "XPCServices/Downloader.xpc",
    "Autoupdate",
    "Updater.app",
)
FORBIDDEN_HELPER_ENTITLEMENTS = (
    "com.apple.security.app-sandbox",
    "com.apple.security.get-task-allow",
)


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def output_of(*args):
    return subprocess.check_output([str(a) for a in args], stderr=subprocess.STDOUT).decode()


def manifest():
    info = plistlib.loads((ROOT / "App/Info.plist").read_bytes())
    quicklook = plistlib.loads((ROOT / "App/QuickLook-Info.plist").read_bytes())
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        if info[key] != quicklook[key]:
            raise SystemExit(f"App and Quick Look manifests disagree on {key}")
    if not info.get("SUFeedURL") or not info.get("SUPublicEDKey"):
        raise SystemExit("Configure SUFeedURL and SUPublicEDKey in App/Info.plist before preparing updates")
    return info["CFBundleShortVersionString"], int(info["CFBundleVersion"]), info["SUPublicEDKey"], info["SUFeedURL"]


def live_feed(feed):
    try:
        with urllib.request.urlopen(feed, timeout=30) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        raise SystemExit(f"The live feed answered {error.code}: {feed}")
    except urllib.error.URLError as error:
        raise SystemExit(f"Cannot fetch the live feed {feed}: {error.reason}")


def feed_build(data):
    root = ET.fromstring(data)
    values = [int(node.text) for node in root.iter(NS + "version")]
    values += [int(node.attrib[NS + "version"]) for node in root.iter("enclosure") if NS + "version" in node.attrib]
    return max(values, default=0)


def signing_details(path):
    return output_of("codesign", "-dv", "--verbose=4", path)


def team_of(details):
    for line in details.splitlines():
        if line.startswith("TeamIdentifier="):
            return line.split("=", 1)[1]
    return None


def identity_of(details):
    for line in details.splitlines():
        if line.startswith("Authority=Developer ID Application:"):
            return line.split("=", 1)[1]
    raise SystemExit("Missing Developer ID Application signing identity")


def source_commit():
    return output_of("git", "-C", ROOT, "rev-parse", "HEAD").strip()


def verify(app, expected_identity=None):
    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", app)
    details = signing_details(app)
    team = team_of(details)
    if "Authority=Developer ID Application" not in details or not team or team == "not set":
        raise SystemExit("App is not signed with a Developer ID Application identity")
    if expected_identity is not None and identity_of(details) != expected_identity:
        raise SystemExit("Archive signing identity does not match review receipt")
    sparkle = app / "Contents/Frameworks/Sparkle.framework"
    nested = [sparkle / "Versions/B" / helper for helper in SPARKLE_HELPERS]
    nested += [sparkle, app / "Contents/PlugIns/WaferQuickLook.appex", app]
    for code in nested:
        run("codesign", "--verify", "--strict", "--verbose=2", code)
        details = signing_details(code)
        if team_of(details) != team or "Timestamp=" not in details or "runtime" not in details:
            raise SystemExit(f"Missing Developer ID team, timestamp, or hardened runtime: {code}")
    for helper in nested[: len(SPARKLE_HELPERS)]:
        raw = subprocess.check_output(["codesign", "-d", "--entitlements", ":-", str(helper)], stderr=subprocess.DEVNULL)
        entitlements = plistlib.loads(raw) if raw else {}
        if any(entitlements.get(key) for key in FORBIDDEN_HELPER_ENTITLEMENTS):
            raise SystemExit(f"Unexpected sandbox or debug entitlement on Sparkle helper: {helper}")
    run(ROOT / "scripts/verify-appex.sh", app)
    run("xcrun", "stapler", "validate", app)
    run("spctl", "--assess", "--type", "execute", "--verbose=4", app)


def verify_archive(archive, expected_identity=None):
    with zipfile.ZipFile(archive) as contents:
        stray = [name for name in contents.namelist() if name.startswith("__MACOSX/") or Path(name).name.startswith("._")]
    if stray:
        raise SystemExit(f"Archive holds {len(stray)} AppleDouble entries, such as {stray[0]}")
    # Sparkle and Archive Utility extract like ditto; a browser download may be opened with unzip.
    for extract in (["ditto", "-x", "-k", archive], ["unzip", "-q", archive, "-d"]):
        with tempfile.TemporaryDirectory(prefix="wafer-extract-") as tmp:
            run(*extract, tmp)
            verify(Path(tmp) / f"{APP}.app", expected_identity)


def verify_update(archive, appcast, public_key):
    run("swift", ROOT / "scripts/verify-update.swift", archive, appcast, public_key)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def publish(review, version, build, public_key, feed, current_feed, repository):
    receipt = json.loads((review / "review.json").read_text())
    archive = review / receipt["zip"]
    expected = dict(version=version, build=build, publicKey=public_key,
                    sourceCommit=source_commit(), repository=repository, feedURL=feed)
    for key, value in expected.items():
        if receipt.get(key) != value:
            raise SystemExit(f"Review receipt does not match {key}")
    if not receipt.get("signingIdentity") or not receipt.get("baseFeedSHA256"):
        raise SystemExit("Review receipt is missing signing identity or base feed hash; prepare again")
    for name, expected in receipt["sha256"].items():
        if sha256(review / name) != expected:
            raise SystemExit(f"Review artifact changed: {name}")
    verify_archive(archive, receipt["signingIdentity"])
    verify_update(archive, review / "appcast.xml", public_key)
    desired_feed = (review / "appcast.xml").read_bytes()
    if current_feed != desired_feed and hashlib.sha256(current_feed).hexdigest() != receipt["baseFeedSHA256"]:
        raise SystemExit("Live feed changed since preparation")
    with tempfile.TemporaryDirectory(prefix="wafer-publish-") as tmp:
        checkout = Path(tmp) / "releases"
        run("gh", "repo", "clone", repository, checkout)
        remote_feed = (checkout / "appcast.xml").read_bytes()
        if remote_feed != desired_feed and hashlib.sha256(remote_feed).hexdigest() != receipt["baseFeedSHA256"]:
            raise SystemExit("Release repo feed changed since preparation")
        tag = f"v{version}"
        existing = subprocess.run(["gh", "release", "view", tag, "--repo", repository,
                                   "--json", "isDraft,assets"], capture_output=True, text=True)
        if existing.returncode:
            if "release not found" not in existing.stderr.lower():
                raise SystemExit(f"Cannot inspect existing release: {existing.stderr.strip()}")
        else:
            state = json.loads(existing.stdout)
            if state["isDraft"]:
                raise SystemExit("Existing release is a draft")
        tag_commit = subprocess.run(["gh", "api", f"repos/{repository}/commits/{tag}", "--jq", ".sha"],
                                    capture_output=True, text=True)
        if tag_commit.returncode:
            if not existing.returncode or "HTTP 404" not in tag_commit.stderr:
                raise SystemExit(f"Cannot inspect release tag: {tag_commit.stderr.strip()}")
        elif tag_commit.stdout.strip() != receipt["sourceCommit"]:
            raise SystemExit("Release tag does not match source commit")
        if not existing.returncode:
            if any(asset["name"] == archive.name for asset in state["assets"]):
                downloaded = Path(tmp) / archive.name
                run("gh", "release", "download", tag, "--repo", repository,
                    "--pattern", archive.name, "--output", downloaded)
                if sha256(downloaded) != receipt["sha256"][archive.name]:
                    raise SystemExit("Existing release archive does not match reviewed artifact")
        # All artifact, feed, release, and existing-tag checks precede mutation.
        if existing.returncode:
            run("gh", "release", "create", tag, archive, "--repo", repository,
                "--target", receipt["sourceCommit"], "--title", f"{APP} {version}", "--notes", f"{APP} {version}")
        else:
            if not any(asset["name"] == archive.name for asset in state["assets"]):
                run("gh", "release", "upload", tag, archive, "--repo", repository)
        if remote_feed != desired_feed:
            shutil.copy2(review / "appcast.xml", checkout / "appcast.xml")
            run("git", "-C", checkout, "add", "appcast.xml")
            run("git", "-C", checkout, "commit", "-m", f"{APP} {version}")
            run("git", "-C", checkout, "push")


def prepare(output, version, build, public_key, feed, current_feed, tools, repository):
    run("python3", ROOT / "scripts/check-source.py")
    if output.exists():
        raise SystemExit(f"Output directory already exists: {output}")
    commit = source_commit()
    environment = dict(os.environ, WAFER_DIST_DIR=str(output))
    environment.setdefault("WAFER_NOTARY_PROFILE", "VibeMD")
    environment.pop("WAFER_SKIP_NOTARIZATION", None)
    run(ROOT / "scripts/package-release.sh", env=environment)
    identity = identity_of(signing_details(ROOT / "build/Wafer.app"))
    final = output / f"{APP}-{version}.zip"
    # generate_appcast reads every archive in the directory.
    (output / f"{APP}-{version}-notarization.zip").unlink()
    verify_archive(final)
    (output / "appcast.xml").write_bytes(current_feed)
    run(tools / "generate_appcast", "--maximum-deltas", "0", "--download-url-prefix", f"https://github.com/{repository}/releases/download/v{version}/", output)
    verify_update(final, output / "appcast.xml", public_key)
    run("python3", ROOT / "scripts/check-source.py")
    if source_commit() != commit:
        raise SystemExit("Source commit changed during preparation; prepare again")
    receipt = dict(version=version, build=build, zip=final.name, publicKey=public_key,
                   sourceCommit=commit, repository=repository, feedURL=feed, signingIdentity=identity,
                   baseFeedSHA256=hashlib.sha256(current_feed).hexdigest(),
                   sha256={p.name: sha256(p) for p in (final, output / "appcast.xml")})
    (output / "review.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Prepared for review at {output}. Nothing published.")


def main():
    parser = argparse.ArgumentParser(description="Prepare a notarized Sparkle release for review, or publish a previously reviewed directory.")
    parser.add_argument("--repository", required=True, help="GitHub release repository in OWNER/REPO form")
    parser.add_argument("--publish", type=Path, metavar="REVIEW_DIRECTORY")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/updates")
    parser.add_argument("--sparkle-tools", type=Path, default=SPARKLE_TOOLS, help="Sparkle bin directory; defaults to the copy SwiftPM unpacked")
    args = parser.parse_args()
    version, build, public_key, feed = manifest()
    current_feed = live_feed(feed)
    if args.publish:
        publish(args.publish.resolve(), version, build, public_key, feed, current_feed, args.repository)
    else:
        if build <= feed_build(current_feed):
            raise SystemExit("Manifest build must be greater than every published feed build")
        prepare(args.output.resolve() / f"{version}-{build}", version, build, public_key, feed, current_feed, args.sparkle_tools.resolve(), args.repository)


if __name__ == "__main__":
    main()

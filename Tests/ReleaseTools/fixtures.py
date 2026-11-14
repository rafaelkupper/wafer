"""Disposable app products and external-command stubs for release script tests."""
import hashlib
import json
import os
import plistlib
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CORE_FILES = (
    'reader-theme.css', 'gemoji-shortcodes.json', 'gemoji-LICENSE.txt',
    'mermaid.min.js', 'mermaid-LICENSE.txt', 'katex.min.js', 'katex.min.css',
    'katex-LICENSE.txt', 'KaTeX_Main-Regular.woff2',
)
IDENTITY = 'Developer ID Application: Fixture Publisher (FIXTURE)'
COMMIT = 'a' * 40
BASE_FEED = b'<rss><channel/></rss>'
NEW_FEED = b'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>2</sparkle:version></item></channel></rss>'

STUB = r'''
import json, os, plistlib, shutil, sys, zipfile
from pathlib import Path
command = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ['FIXTURE_ROOT'])
with (root / 'calls.jsonl').open('a') as log:
    log.write(json.dumps([command, *args]) + '\n')
state_file = root / 'remote.json'
state = json.loads(state_file.read_text())
fail = os.environ.get('FAIL_COMMAND') == command + ' ' + ' '.join(args[:2])
def save():
    state_file.write_text(json.dumps(state))
if command == 'codesign':
    if os.environ.get('FAIL_EXTRACTED_SIGNATURE') and '--verify' in args and not args[-1].startswith(str(root)):
        sys.exit(23)
    # Remember the entitlements each signature was made with, so display
    # reports what the scripts actually signed.
    signatures_file = root / 'signed-entitlements.json'
    signatures = json.loads(signatures_file.read_text()) if signatures_file.exists() else {}
    if '--sign' in args and not fail:
        if '--entitlements' in args:
            signatures[args[-1]] = plistlib.loads(Path(args[args.index('--entitlements') + 1]).read_bytes())
        else:
            signatures.pop(args[-1], None)
        signatures_file.write_text(json.dumps(signatures))
    if '-d' in args and '--entitlements' in args:
        entitlements = {'com.apple.security.app-sandbox': True} if args[-1].endswith('.appex') else signatures.get(args[-1], {})
        if os.environ.get('NETWORK_ENTITLEMENT') and args[-1].endswith('.appex'):
            entitlements['com.apple.security.network.client'] = True
        if 'APP_ENTITLEMENTS' in os.environ and args[-1].endswith('.app'):
            entitlements = json.loads(os.environ['APP_ENTITLEMENTS'])
        sys.stdout.buffer.write(plistlib.dumps(entitlements))
    elif '-dv' in args:
        print('Authority=' + os.environ.get('SIGNING_IDENTITY', 'Developer ID Application: Fixture Publisher (FIXTURE)'))
        print('TeamIdentifier=FIXTURE\nTimestamp=fixture\nflags=' + os.environ.get('CODESIGN_FLAGS', 'runtime'))
elif command == 'node' and args[:1] == ['-e']:
    version = os.environ.get('NODE_VERSION', '22.0.0')
    if int(version.split('.')[0]) < 22:
        sys.exit('error: Node.js 22 or newer is required; found ' + version)
elif command == 'swift' and '--show-bin-path' in args:
    print(os.environ['FIXTURE_PRODUCTS_DIR'])
elif command == 'swift' and args[:1] == ['test']:
    (root / 'perf-test-mode.txt').write_text(os.environ.get('WAFER_PERF_TESTS', '0'))
    (root / 'release-test-mode.txt').write_text(os.environ.get('WAFER_RELEASE_TESTS', '0'))
elif command == 'ditto':
    if '-c' in args:
        app, archive = map(Path, args[-2:])
        with zipfile.ZipFile(archive, 'w') as z:
            for p in app.rglob('*'):
                if p.is_file():
                    z.write(p, str(Path(app.name) / p.relative_to(app)))
    else:
        with zipfile.ZipFile(args[-2]) as z:
            z.extractall(args[-1])
            for info in z.infolist():
                (Path(args[-1]) / info.filename).chmod(info.external_attr >> 16)
elif command == 'xcrun':
    if args == ['swift', '--version']:
        print('Apple Swift version ' + os.environ.get('XCODE_SWIFT_VERSION', '6.2.4'))
    elif args[0] == 'dsymutil':
        symbols = Path(args[args.index('-o') + 1]) / 'Contents/Resources/DWARF'
        symbols.mkdir(parents=True, exist_ok=True)
        (symbols / Path(args[1]).name).write_text('fixture symbols')
    elif args[:2] == ['notarytool', 'submit']:
        print(json.dumps({'id': 'fixture-submission', 'status': os.environ.get('NOTARY_STATUS', 'Accepted')}))
    elif args[:2] == ['notarytool', 'log']:
        Path(args[-1]).write_text('{}')
elif command == 'otool':
    print(args[-1] + ':')
    print('\t/System/Library/Frameworks/QuickLookUI.framework/Versions/A/QuickLookUI (compatibility version 1.0.0)')
    if os.environ.get('LINK_WEBKIT'):
        print('\t/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit (compatibility version 1.0.0)')
elif command == 'xcode-select':
    print(root / 'Selected Xcode.app/Contents/Developer')
elif command == 'xcodebuild':
    if os.environ.get('DEVELOPER_DIR') == str(root / 'Selected Xcode.app/Contents/Developer'):
        print('Xcode ' + os.environ.get('XCODE_VERSION', '26.3'))
    else:
        sys.exit(1)
elif command == 'generate_appcast':
    (Path(args[-1]) / 'appcast.xml').write_text(os.environ['NEW_FEED'])
elif command == 'git':
    operation = args[2]
    fail = os.environ.get('FAIL_COMMAND') == 'git ' + operation
    if operation == 'rev-parse':
        print(os.environ.get('SOURCE_COMMIT', 'a' * 40))
    elif operation == 'status':
        print(os.environ.get('SOURCE_STATUS', ''), end='')
    elif operation == 'push':
        if os.environ.get('PUSH_APPLIED') or not fail:
            state['feed'] = (Path(args[1]) / 'appcast.xml').read_text()
            save()
elif command == 'gh':
    if args[:2] == ['repo', 'clone']:
        checkout = Path(args[-1])
        checkout.mkdir()
        (checkout / 'appcast.xml').write_text(state['feed'])
    elif args[:2] == ['release', 'view']:
        if state.get('release') is None:
            print('release not found', file=sys.stderr)
            sys.exit(1)
        print(json.dumps({'isDraft': False, 'assets': [{'name': n} for n in state['release']['assets']]}))
    elif args[:2] == ['release', 'create']:
        if state.get('release') is not None:
            sys.exit('duplicate release')
        state['release'] = {'commit': args[args.index('--target') + 1], 'assets': {}}
        if not fail:
            state['release']['assets'][Path(args[3]).name] = Path(args[3]).read_bytes().hex()
        save()
    elif args[:2] == ['release', 'upload']:
        state['release']['assets'][Path(args[3]).name] = Path(args[3]).read_bytes().hex()
        save()
    elif args[:2] == ['release', 'download']:
        name = args[args.index('--pattern') + 1]
        Path(args[args.index('--output') + 1]).write_bytes(bytes.fromhex(state['release']['assets'][name]))
    elif args[0] == 'api':
        if fail:
            sys.exit('fixture API failure')
        commit = state.get('tag') or (state['release']['commit'] if state.get('release') else None)
        if not commit:
            print('gh: Not Found (HTTP 404)', file=sys.stderr)
            sys.exit(1)
        print(commit)
    else:
        sys.exit('unexpected gh invocation: ' + repr(args))
if fail:
    sys.exit(23)
'''


class Fixture:
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='wafer-release-test-')
        self.root = Path(self.temporary.name).resolve()
        (self.root / 'scripts').mkdir()
        for name in ('build-app.sh', 'verify-appex.sh', 'verify-app.sh', 'sandbox-smoke.sh', 'package-release.sh', 'release.py', 'verify-update.swift',
                     'check.sh', 'check-source.py', 'verify-vendored-assets.py', 'select-xcode.sh'):
            shutil.copy2(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        shutil.copytree(ROOT / 'App', self.root / 'App')
        version = {'CFBundleShortVersionString': '1.0.0', 'CFBundleVersion': '2'}
        for name in ('Info.plist', 'QuickLook-Info.plist'):
            path = self.root / 'App' / name
            info = plistlib.loads(path.read_bytes())
            info.update(version)
            if name == 'Info.plist':
                info.update(SUFeedURL='https://updates.example.org/appcast.xml', SUPublicEDKey='fixture-key')
            path.write_bytes(plistlib.dumps(info))
        self.products = self.root / '.build/fixture-triple/release'
        self.products.mkdir(parents=True)
        for name in ('Wafer', 'WaferQuickLook'):
            path = self.products / name
            path.write_text('#!/bin/sh\nexit 0\n')
            path.chmod(0o755)
        (self.products / 'Sparkle.framework/Versions/B').mkdir(parents=True)
        (self.products / 'Sparkle.framework/Versions/B/Sparkle').write_text('fixture')
        (self.products / 'Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents').mkdir(parents=True)
        self.resources = self.make_resources(nested=True)
        (self.root / 'Tests/ReleaseTools').mkdir(parents=True)
        (self.root / 'Tests/JavaScript/app').mkdir(parents=True)
        (self.root / 'Tests/JavaScript/app/fixture.cjs').write_text('// fixture')
        (self.root / 'docs').mkdir()
        assets = []
        for name in ('mermaid.min.js', 'mermaid-LICENSE.txt', 'katex/katex.min.js'):
            path = Path('Sources/WaferCore/Resources') / name
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            (self.root / path).write_text('fixture')
            assets.append(dict(path=str(path), version='fixture', url='https://example.org/' + name,
                               sha256=hashlib.sha256(b'fixture').hexdigest()))
        (self.root / 'docs/vendored-assets.json').write_text(json.dumps(dict(assets=assets)))
        bindir = self.root / 'bin'
        bindir.mkdir()
        for name in ('swift', 'codesign', 'ditto', 'xcrun', 'security', 'spctl', 'pluginkit', 'lsregister', 'gh', 'git', 'generate_appcast', 'otool', 'strip', 'node', 'xcode-select', 'xcodebuild'):
            path = bindir / name
            path.write_text('#!' + sys.executable + '\n' + STUB)
            path.chmod(0o755)
        (self.root / 'remote.json').write_text(json.dumps({'feed': BASE_FEED.decode(), 'release': None}))
        self.env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ['PATH'],
                        FIXTURE_ROOT=str(self.root), NEW_FEED=NEW_FEED.decode(),
                        FIXTURE_PRODUCTS_DIR=str(self.products),
                        WAFER_SIGN_IDENTITY=IDENTITY, WAFER_NOTARY_PROFILE='fixture',
                        WAFER_LSREGISTER=str(bindir / 'lsregister'), WAFER_REGISTER_APP='0')

    def make_resources(self, nested):
        for name in ('WaferCore', 'WaferApp'):
            bundle = self.products / f'Wafer_{name}.bundle'
            directory = bundle / 'Contents/Resources' if nested else bundle
            directory.mkdir(parents=True, exist_ok=True)
            if nested:
                (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': name}))
            if name == 'WaferCore':
                core = directory
                for resource in CORE_FILES:
                    (directory / resource).write_text('fixture')
            else:
                (directory / 'Themes').mkdir(exist_ok=True)
                (directory / 'Themes/GitHub Light.json').write_text('{}')
        return core

    def calls(self):
        path = self.root / 'calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def close(self):
        self.temporary.cleanup()

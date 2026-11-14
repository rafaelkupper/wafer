#!/usr/bin/env python3
"""Build an optimized standalone fixture runner; run the printed binary in fresh processes."""
import pathlib
import platform
import subprocess
import sys
root = pathlib.Path(__file__).resolve().parents[2]
subprocess.run(['swift', 'build', '-c', 'release', '--target', 'WaferCore'], cwd=root, check=True)
build = pathlib.Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=root, text=True).strip())
objects = []
for name in ['WaferCore', 'Markdown', 'CAtomic', 'cmark-gfm', 'cmark-gfm-extensions']:
    if (build / (name + '.o')).exists():
        objects.append(str(build / (name + '.o')))
    else:
        objects.extend(str(p) for p in (build / (name + '.build')).rglob('*.o'))
flags = ['swiftc', '-O', '-whole-module-optimization', '-swift-version', '6', '-target', f'{platform.machine()}-apple-macosx14.0', '-I', str(build / 'Modules' if (build / 'Modules').exists() else build)]
for path in ['swift-cmark/src/include', 'swift-cmark/extensions/include', 'swift-markdown/Sources/CAtomic/include']:
    flags += ['-I', str(root / '.build/checkouts' / path)]
output = pathlib.Path(sys.argv[1]).resolve()
source = pathlib.Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else pathlib.Path(__file__).with_suffix('.swift')
subprocess.run(flags + [str(source)] + objects + ['-o', str(output)], check=True)
print(output)

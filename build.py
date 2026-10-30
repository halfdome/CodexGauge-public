#!/usr/bin/env python3
"""Build CodexGauge locally using Swift and the installed ChatGPT logo."""
from pathlib import Path
import argparse
import plistlib
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--test', action='store_true')
args = parser.parse_args()
build = root / 'build'
build.mkdir(exist_ok=True)
parts = ['FuelGauge.swift', 'UsagePlanLabels.swift',
         'Announcements.swift', 'AnnouncementTests.swift', 'UsageBar.swift']
source = build / 'main.swift'
source.write_text('\n'.join((root / name).read_text() for name in parts))

def compile_to(target, optimized):
    subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', str(build / 'swift-cache')]
                   + (['-O'] if optimized else []) + [str(source), '-o', str(target)], check=True)

if args.test:
    target = build / 'CodexGaugeTests'
    compile_to(target, False)
    for test in ['--test-display', '--test-announcements']:
        subprocess.run([str(target), test], check=True)
else:
    with tempfile.TemporaryDirectory(prefix='codexgauge-') as temp:
        app = Path(temp) / 'CodexGauge.app'
        contents = app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Resources').mkdir()
        compile_to(contents / 'MacOS/CodexUsage', True)
        info = dict(CFBundleName='CodexGauge', CFBundleDisplayName='CodexGauge',
                    CFBundleExecutable='CodexUsage', CFBundleIdentifier='local.codex.usagebar',
                    CFBundlePackageType='APPL', CFBundleShortVersionString='2.2', CFBundleVersion='4',
                    LSMinimumSystemVersion='13.0', LSUIElement=True, NSHighResolutionCapable=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        resources = Path('/Applications/ChatGPT.app/Contents/Resources')
        for suffix in ['', '@2x']:
            logo = resources / f'chatgptTemplate{suffix}.png'
            if logo.exists():
                (contents / 'Resources' / f'ChatGPTLogo{suffix}.png').write_bytes(logo.read_bytes())
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
        target = build / app.name
        if target.exists():
            shutil.rmtree(target)
        def copy_bytes(src, dst):
            Path(dst).write_bytes(Path(src).read_bytes())
            Path(dst).chmod(Path(src).stat().st_mode & 0o777)
            return dst
        shutil.copytree(app, target, copy_function=copy_bytes)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(target)], check=True)
        print(target)

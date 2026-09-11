#!/usr/bin/env python3
"""Build standalone Azahar Qt/Vulkan reference without embedded keys or web services."""
import argparse
import configparser
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import sys
import urllib.request

from build_core import COMMIT, ROOT, SOURCE, ensure_build_tools, run

BUILD = ROOT / '.local/reference-build'
MODULES = ['externals/glslang', 'externals/vma', 'externals/vulkan-headers',
           'externals/sirit/sirit', 'externals/spirv-tools', 'externals/spirv-headers',
           'externals/sdl2/SDL', 'externals/cubeb']


def install_reference(test_input=False):
    app = Path.home() / 'Applications/Azahar Reference.app'
    identifier = 'local.mh4u.azaharreference'
    if app.exists():
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != identifier:
            raise RuntimeError(f'Refusing to overwrite unrelated app: {app}')
    app.parent.mkdir(exist_ok=True)
    run('ditto', BUILD / 'bin/Release/azahar.app', app)
    run(BUILD / 'externals/qt/6.10.3/macos/bin/macdeployqt', app,
        '-always-overwrite', '-verbose=1', '-no-strip')
    plist = app / 'Contents/Info.plist'
    info = plistlib.loads(plist.read_bytes())
    info.update(CFBundleIdentifier=identifier, CFBundleName='Azahar Reference',
                CFBundleDisplayName='Azahar Reference',
                CFBundleShortVersionString='2126.1', CFBundleVersion='2126.1')
    if test_input:
        info['LSEnvironment'] = {'MH4U_REFERENCE_TEST_INPUT': '1'}
    plist.write_bytes(plistlib.dumps(info))
    run('codesign', '--force', '--deep', '--sign', '-', app)
    run('codesign', '--verify', '--deep', '--strict', app)
    run('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
        '-f', app)
    print(app)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--install', action='store_true', help='Deploy and register the offline app in ~/Applications')
    parser.add_argument('--test-input', action='store_true', help='Enable 75ms keyboard and touch taps in the installed test app')
    args = parser.parse_args()
    run(sys.executable, ROOT / 'tools/build_core.py', '--prepare-only')
    modules = configparser.ConfigParser()
    modules.read(SOURCE / '.gitmodules')
    urls = {modules[s]['path']: modules[s]['url'] for s in modules.sections()}
    metadata = ROOT / f'.local/reference/upstream-tree-{COMMIT}.json'
    metadata.parent.mkdir(parents=True, exist_ok=True)
    if not metadata.exists():
        with urllib.request.urlopen(
                f'https://api.github.com/repos/azahar-emu/azahar/git/trees/{COMMIT}?recursive=1') as response:
            metadata.write_bytes(response.read())
    tree = json.loads(metadata.read_text())
    revisions = {entry['path']: entry['sha'] for entry in tree['tree'] if entry['type'] == 'commit'}
    provenance = {'source_commit': COMMIT, 'qt': '6.10.3', 'moltenvk': '1.4.1', 'submodules': []}
    for module in MODULES:
        path = SOURCE / module
        path.mkdir(parents=True, exist_ok=True)
        if (path / '.git').exists() or not any(path.iterdir()):
            run('git', 'init', path)
            run('git', 'config', 'remote.origin.url', urls[module], cwd=path)
            run('git', 'fetch', '--depth=1', 'origin', revisions[module], cwd=path)
            run('git', 'checkout', '--detach', 'FETCH_HEAD', cwd=path)
            shutil.rmtree(path / '.git')
        provenance['submodules'].append({'path': module, 'url': urls[module], 'commit': revisions[module]})
    (ROOT / '.local/reference/provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    ensure_build_tools()
    openssl = run('brew', '--prefix', 'openssl@3', capture_output=True, text=True).stdout.strip()
    run('cmake', '-S', SOURCE, '-B', BUILD, '-G', 'Ninja',
        '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_ARCHITECTURES=arm64',
        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5', '-DENABLE_LIBRETRO=OFF',
        '-DENABLE_QT=ON', '-DENABLE_VULKAN=ON', '-DENABLE_OPENGL=OFF',
        '-DENABLE_BUILTIN_KEYBLOB=OFF', '-DENABLE_WEB_SERVICE=OFF',
        '-DENABLE_QT_UPDATE_CHECKER=OFF', '-DENABLE_SCRIPTING=OFF',
        '-DENABLE_ROOM=OFF', '-DENABLE_ROOM_STANDALONE=OFF',
        '-DENABLE_OPENAL=OFF', '-DENABLE_LIBUSB=OFF', '-DENABLE_GDBSTUB=OFF',
        '-DUSE_SANITIZERS=OFF',
        '-DENABLE_TESTS=OFF', '-DENABLE_LTO=OFF', '-DCITRA_WARNINGS_AS_ERRORS=OFF',
        '-DUSE_SYSTEM_OPENSSL=ON', f'-DOPENSSL_ROOT_DIR={openssl}')
    with (BUILD / 'externals/MoltenVK.tar').open('rb') as archive:
        digest = hashlib.file_digest(archive, 'sha256').hexdigest()
    if digest != '2c498bf8c98b88ba1e84c1f153403d4c1a8490c122d9e2a3df238b25d4e10557':
        raise RuntimeError('MoltenVK archive differs from official release SHA-256')
    run('cmake', '--build', BUILD, '--target', 'citra_meta', '-j', '8')
    reference = ROOT / '.local/reference'
    app = reference / 'Azahar.app'
    if not app.exists():
        app.symlink_to('../reference-build/bin/Release/azahar.app', target_is_directory=True)
    print(app)
    if args.install:
        install_reference(args.test_input)


if __name__ == '__main__':
    main()

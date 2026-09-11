#!/usr/bin/env python3
"""Prepare, build, run and verify the local MH4U Apple Silicon runtime."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

from prepare_image import ROOT, TITLE_ID, file_hash, prepare, require

CORE = ROOT / '.local/core-vulkan-build/bin/Release/azahar_libretro.dylib'
MOLTENVK = ROOT / '.local/vulkan/libMoltenVK.dylib'
HOST = ROOT / 'build/mh4u-runtime'
GAME = ROOT / '.local/game'
SUPPORT = Path.home() / 'Library/Application Support/MH4U Runtime'
CODE_HASH = '63940d7ef1fecc119f9fb820f5f6a2cf2f2a5549e4a70f00319fbd6c9c1ad8dc'
SANDBOX = ['sandbox-exec', '-p', '(version 1)(allow default)(deny network*)']


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], cwd=ROOT, check=True, **kwargs)


def ensure_tools():
    missing = [name for name in ('cmake', 'ninja') if not shutil.which(name)]
    if missing:
        require(shutil.which('brew'), 'Homebrew is unavailable; automatic utility installation cannot proceed')
        run('brew', 'install', *missing)
    require(shutil.which('sandbox-exec'), 'The local network-denied runtime launcher requires sandbox-exec')


def local_artifact(record):
    path = (GAME / record['path']).resolve()
    require(path.is_relative_to(GAME.resolve()), 'Manifest artifact escapes local game directory')
    require(path.is_file(), f'Missing local game artifact: {path}')
    require(path.stat().st_size == record['size'], f'Artifact size mismatch: {path.name}')
    require(file_hash(path) == record['sha256'], f'Artifact hash mismatch: {path.name}')
    return path


def prepared_game():
    path = GAME / 'manifest.json'
    if not path.exists():
        images = sorted(ROOT.glob('*.3ds'))
        require(len(images) == 1, 'Expected exactly one user-supplied workspace .3ds image')
        prepare(images[0])
    manifest = json.loads(path.read_text())
    require(manifest['schema_version'] == 1, 'Unsupported preparation manifest')
    require(manifest['title_id'] == TITLE_ID and manifest['product_code'] == 'CTR-P-BFGP', 'Incorrect title profile')
    require(manifest['partition']['index'] == 0 and manifest['partition']['no_crypto'], 'Only decrypted main game partition is supported')
    require(manifest['code']['sha256'] == CODE_HASH, 'This runtime profile targets the supplied EUR code revision')
    local_artifact(manifest['code'])
    return local_artifact(manifest['cxi'])


def build(rebuild_core=True):
    ensure_tools()
    if rebuild_core or not CORE.exists() or not MOLTENVK.exists():
        run(sys.executable, ROOT / 'tools/build_vulkan_core.py')
    run('cmake', '-S', ROOT, '-B', ROOT / 'build', '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_ARCHITECTURES=arm64')
    run('cmake', '--build', ROOT / 'build', '-j', '8')


def host_command(game, *extra):
    return [*SANDBOX, str(HOST), '--core', str(CORE), '--game', str(game),
            '--state-dir', str(SUPPORT / '.local/state'), *map(str, extra)]


def install():
    """Install only the validated runtime inputs outside macOS's protected Desktop.

    A normal native app can then open its own data without asking for access to
    the whole Desktop. The original image and development artifacts stay put.
    """
    game = prepared_game()
    build(rebuild_core=False)
    support = SUPPORT
    support.mkdir(parents=True, exist_ok=True)
    destination = Path.home() / 'Applications/MH4U Runtime.app'
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        with (destination / 'Contents/Info.plist').open('rb') as stream:
            require(plistlib.load(stream).get('CFBundleIdentifier') == 'local.mh4u.runtime',
                    'Refusing to replace a different application')
    staged = Path(tempfile.mkdtemp(prefix='install-', dir=support))
    try:
        relative_game = Path('.local/game/main.cxi')
        installed_game = support / relative_game
        if not installed_game.exists() or file_hash(installed_game) != file_hash(game):
            copy = staged / 'main.cxi'
            # APFS clones share disk blocks; fall back to an ordinary local copy.
            clone = subprocess.run(['/bin/cp', '-c', str(game), str(copy)], capture_output=True)
            if clone.returncode:
                shutil.copyfile(game, copy)
            require(file_hash(copy) == file_hash(game), 'Installed image hash mismatch')
            installed_game.parent.mkdir(parents=True, exist_ok=True)
            os.replace(copy, installed_game)
        installed_libraries = {}
        for source in (CORE, MOLTENVK):
            installed = support / source.relative_to(ROOT)
            installed.parent.mkdir(parents=True, exist_ok=True)
            copy = staged / source.name
            shutil.copy2(source, copy)
            require(file_hash(copy) == file_hash(source), f'Installed library hash mismatch: {source.name}')
            os.replace(copy, installed)
            installed_libraries[str(source.relative_to(ROOT))] = file_hash(installed)
        app = staged / 'MH4U Runtime.app'
        shutil.copytree(ROOT / 'build/MH4U Runtime.app', app)
        info_path = app / 'Contents/Info.plist'
        with info_path.open('rb') as stream:
            info = plistlib.load(stream)
        info['MH4UWorkspace'] = str(support)
        with info_path.open('wb') as stream:
            plistlib.dump(info, stream)
        run('codesign', '--force', '--sign', '-', app)
        previous = None
        if destination.exists():
            previous = staged / 'previous.app'
            destination.rename(previous)
        try:
            app.rename(destination)
        except OSError:
            if previous:
                previous.rename(destination)
            raise
        (support / 'installation.json').write_text(json.dumps({
            'workspace': str(ROOT), 'game_sha256': file_hash(installed_game),
            'libraries': installed_libraries, 'renderer': 'vulkan', 'application': str(destination),
            'save_directory': str(support / '.local/state/Azahar')
        }, indent=2) + '\n')
    finally:
        shutil.rmtree(staged)
    print(destination)


def verify(frames, timeout, compare, allow_black=False):
    require(frames > 0 and timeout > 0, 'Frames and timeout must be positive')
    game = prepared_game()
    build(rebuild_core=False)
    run('ctest', '--test-dir', ROOT / 'build', '--output-on-failure')
    reports = ROOT / '.local/reports'
    reports.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    folder = Path(tempfile.mkdtemp(prefix=f'boot-{stamp}-', dir=reports))
    report = {'schema_version': 1, 'scope': 'finite boot test, not gameplay validation',
              'core_sha256': file_hash(CORE), 'game_sha256': file_hash(game), 'runs': []}
    for cpu in (['jit', 'interpreter'] if compare else ['jit']):
        state = folder / f'{cpu}-state'
        state.mkdir()
        capture = folder / f'{cpu}.ppm'
        command = host_command(game, '--headless', '--cpu', cpu, '--frames', frames,
                               '--state-dir', state, '--capture', capture)
        stdout, stderr = folder / f'{cpu}.json', folder / f'{cpu}.log'
        with stdout.open('w') as out, stderr.open('w') as err:
            try:
                result = subprocess.run(command, cwd=ROOT, stdout=out, stderr=err, timeout=timeout)
                record = {'cpu': cpu, 'exit_code': result.returncode, 'timeout': False}
            except subprocess.TimeoutExpired:
                record = {'cpu': cpu, 'exit_code': None, 'timeout': True}
        if capture.exists():
            record['capture_sha256'] = file_hash(capture)
        if record['exit_code'] == 0:
            try:
                record['metrics'] = json.loads(stdout.read_text())
            except (ValueError, OSError):
                record['invalid_metrics'] = True
        report['runs'].append(record)
        (folder / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        require(record['exit_code'] == 0 and capture.exists(), f'Boot test failed; evidence: {folder}')
        metrics = record.get('metrics', {})
        require(metrics.get('frame_limit_reached') and metrics.get('video_frames', 0) >= frames,
                f'Boot test did not finish the requested frames; evidence: {folder}')
        require(allow_black or metrics.get('nonblack_frames', 0) > 0,
                f'Boot test produced only black frames; evidence: {folder}')
        print(f'{cpu}: {capture}', flush=True)
    if compare:
        report['final_frame_equal'] = report['runs'][0]['capture_sha256'] == report['runs'][1]['capture_sha256']
        report['comparison_scope'] = 'Diagnostic only: asynchronous boot timing and UI animation can differ; this is not deterministic replay.'
    (folder / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'Report: {folder / "report.json"}')
    if compare and not report['final_frame_equal']:
        print('Both CPU modes completed; final captures differ. See comparison_scope in the report.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('prepare')
    sub.add_parser('build')
    sub.add_parser('setup')
    sub.add_parser('install')
    launch = sub.add_parser('run')
    launch.add_argument('host_args', nargs=argparse.REMAINDER)
    smoke = sub.add_parser('verify')
    smoke.add_argument('--frames', type=int, default=120)
    smoke.add_argument('--timeout', type=int, default=300)
    smoke.add_argument('--compare', action='store_true')
    smoke.add_argument('--allow-black', action='store_true', help='Accept early black boot frames for diagnostics')
    args = parser.parse_args()
    if args.command == 'prepare':
        print(prepared_game())
    elif args.command == 'build':
        build()
    elif args.command == 'setup':
        print(prepared_game())
        build()
    elif args.command == 'install':
        install()
    elif args.command == 'verify':
        verify(args.frames, args.timeout, args.compare, args.allow_black)
    else:
        game = prepared_game()
        build(rebuild_core=False)
        extra = args.host_args
        if extra[:1] == ['--']:
            extra = extra[1:]
        require(not any(arg in ('--game', '--core') or arg.startswith(('--game=', '--core=')) for arg in extra),
                'The title launcher uses only the validated prepared game and local built core')
        command = host_command(game, *extra)
        os.chdir(ROOT)
        os.execvp(command[0], command)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, subprocess.CalledProcessError, OSError) as error:
        print(f'mh4u: {error}', file=sys.stderr)
        sys.exit(1)

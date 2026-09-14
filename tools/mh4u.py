#!/usr/bin/env python3
"""Prepare, build, run and verify the local MH4U Apple Silicon runtime."""
import argparse
import contextlib
import ctypes
from datetime import datetime, timezone
import fcntl
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
SAVE_SUFFIX = Path('sdmc/Nintendo 3DS/00000000000000000000000000000000/00000000000000000000000000000000/title/00040000/00126100/data/00000001')
SDMC_SAVE_SUFFIX = SAVE_SUFFIX.relative_to('sdmc')


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


def _profile_manifest(root):
    require(root.is_dir() and not root.is_symlink(), f'Invalid profile directory: {root}')
    result = {}
    for path in sorted(root.rglob('*')):
        require(not path.is_symlink(), f'Profile migration rejects symbolic links: {path}')
        require(path.is_dir() or path.is_file(), f'Profile migration rejects special files: {path}')
        if path.is_file():
            result[str(path.relative_to(root))] = file_hash(path)
    return result


def _reject_symlink_chain(path):
    current = Path(path).absolute()
    for item in (current, *current.parents):
        if item.exists() or item.is_symlink():
            require(not item.is_symlink(), f'Profile migration rejects symbolic links: {item}')


def _sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _sync_tree(root):
    for path in root.rglob('*'):
        if path.is_file():
            with path.open('rb') as stream:
                os.fsync(stream.fileno())
    for path in sorted((path for path in root.rglob('*') if path.is_dir()),
                       key=lambda item: len(item.parts), reverse=True):
        _sync_directory(path)
    _sync_directory(root)


@contextlib.contextmanager
def _state_locks(*states):
    locks = []
    try:
        for state in sorted(map(Path, states), key=lambda path: str(path.resolve())):
            lock_dir = state / 'save-import'
            _reject_symlink_chain(state)
            _reject_symlink_chain(lock_dir)
            lock_dir.mkdir(parents=True, exist_ok=True)
            descriptor = os.open(lock_dir / 'session.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            stream = os.fdopen(descriptor, 'a+b')
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                stream.close()
                raise RuntimeError(f'Another MH4U Runtime session is using {state}')
            locks.append(stream)
        yield
    finally:
        for stream in reversed(locks):
            stream.close()


def _swap_directories(first, second):
    renamex_np = ctypes.CDLL(None, use_errno=True).renamex_np
    renamex_np.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    renamex_np.restype = ctypes.c_int
    if renamex_np(os.fsencode(first), os.fsencode(second), 2):  # RENAME_SWAP
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def migrate_install_profile(source_state=ROOT / '.local/state', target_state=SUPPORT / '.local/state'):
    """Copy a valid workspace profile only when the installed profile has no hunter."""
    source_state, target_state = Path(source_state), Path(target_state)
    source = source_state / 'Azahar/sdmc'
    if not source.exists() and not source.is_symlink():
        return {'migrated': False, 'reason': 'workspace profile is absent'}
    _reject_symlink_chain(source_state)
    _reject_symlink_chain(target_state)
    target_state.mkdir(parents=True, exist_ok=True)
    with _state_locks(source_state, target_state):
        source_pending, target_pending = (source_state / 'save-import/pending',
                                          target_state / 'save-import/pending')
        require(not source_pending.exists() and not source_pending.is_symlink(), 'Workspace has a pending save import')
        require(not target_pending.exists() and not target_pending.is_symlink(), 'Installed profile has a pending save import')
        target = target_state / 'Azahar/sdmc'
        _reject_symlink_chain(source)
        _reject_symlink_chain(target)
        source_raw, target_raw = source / SDMC_SAVE_SUFFIX, target / SDMC_SAVE_SUFFIX
        if target.exists() or target.is_symlink():
            _profile_manifest(target)
        if any((target_raw / name).is_file() for name in ('user1', 'user2', 'user3')):
            return {'migrated': False, 'reason': 'installed profile already has a user save'}
        before = _profile_manifest(source)
        if not source_raw.is_dir():
            return {'migrated': False, 'reason': 'workspace profile has no user save'}
        present_users = [name for name in ('user1', 'user2', 'user3') if (source_raw / name).exists()]
        if not present_users:
            return {'migrated': False, 'reason': 'workspace profile has no user save'}
        require((source_raw / 'system').is_file() and (source_raw / 'system').stat().st_size == 512,
                'Workspace profile has no valid system save')
        entries = {path.name: path for path in source_raw.iterdir()}
        require(set(entries) <= {'system', 'user1', 'user2', 'user3'}, 'Workspace savedata has unknown files')
        for name in present_users:
            require(entries[name].is_file() and entries[name].stat().st_size == 81408,
                    f'Workspace profile has invalid {name}')

        migration = target_state / 'profile-migration'
        _reject_symlink_chain(migration)
        stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
        staging = migration / f'.staging-{stamp}'
        backup = migration / 'backups' / stamp / 'sdmc'
        _reject_symlink_chain(backup)
        had_target = target.exists()
        work = backup if had_target else staging / 'Azahar'
        work.parent.mkdir(parents=True)
        target.parent.mkdir(parents=True, exist_ok=True)
        _reject_symlink_chain(target.parent)
        keep_work = False
        try:
            shutil.copytree(source, work)
            require(_profile_manifest(source) == before, 'Workspace profile changed during migration')
            require(_profile_manifest(work) == before, 'Copied profile failed hash verification')
            _sync_tree(work)
            if had_target:
                _swap_directories(target, work)
                keep_work = True  # The old installed profile is already at its permanent backup path.
                try:
                    require(_profile_manifest(target) == before, 'Activated profile failed verification')
                    require(_profile_manifest(source) == before, 'Workspace profile changed during activation')
                    _sync_directory(target.parent)
                except Exception:
                    try:
                        _swap_directories(target, work)
                        keep_work = False
                    except Exception:
                        pass  # Failed rollback still leaves the old profile intact at `work`.
                    raise
                _sync_directory(backup.parent)
            else:
                work.rename(target)
                try:
                    require(_profile_manifest(source) == before, 'Workspace profile changed during activation')
                except Exception:
                    target.rename(work)
                    raise
                _sync_directory(target.parent)
                backup = None
            record = {'migrated': True, 'source': str(source.resolve()),
                      'target': str(target.resolve()), 'backup': str(backup) if backup else '',
                      'scope': 'sdmc savedata and extdata', 'files': before,
                      'preserved': ['nand', 'sysdata', 'load', 'cheats', 'shaders', 'savestates']}
            temporary = migration / '.migration.json.tmp'
            temporary.write_text(json.dumps(record, indent=2) + '\n')
            with temporary.open('rb') as stream:
                os.fsync(stream.fileno())
            os.replace(temporary, migration / 'migration.json')
            _sync_directory(migration)
            return record
        finally:
            if not keep_work:
                shutil.rmtree(work, ignore_errors=True)
            shutil.rmtree(staging, ignore_errors=True)


def install():
    """Install only the validated runtime inputs outside macOS's protected Desktop.

    A normal native app can then open its own data without asking for access to
    the whole Desktop. The original image and development artifacts stay put.
    """
    game = prepared_game()
    migrate_install_profile()
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

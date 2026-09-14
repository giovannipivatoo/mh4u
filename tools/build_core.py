#!/usr/bin/env python3
"""Build the pinned arm64 Azahar reference core without fetching its key blob."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / '.local/azahar-src'
BUILD = ROOT / '.local/core-build'
COMMIT = '26e608f6fa292b27cda0ae8c84e148d17600a5e6'
TAG = '2126.1'
URL = 'https://github.com/azahar-emu/azahar.git'
EXCLUDED = 'src/core/hw/default_keys.h'
MODULES = [
    'dist/compatibility_list', 'externals/boost', 'externals/nihstro',
    'externals/soundtouch', 'externals/dynarmic', 'externals/fmt',
    'externals/enet', 'externals/inih/inih', 'externals/teakra',
    'externals/lodepng/lodepng', 'externals/zstd', 'externals/dds-ktx',
    'externals/faad2/faad2', 'externals/library-headers', 'externals/oaknut',
    'externals/xxHash', 'externals/libretro-common/libretro-common',
    'externals/cryptopp',
]


def run(*args, cwd=ROOT, **kwargs):
    return subprocess.run([str(a) for a in args], cwd=cwd, check=True, **kwargs)


def git(*args, cwd=SOURCE, **kwargs):
    return run('git', *args, cwd=cwd, **kwargs)


def write_export_identity():
    """Give CMake the pinned identity after the private checkout metadata is removed."""
    (SOURCE / 'GIT-COMMIT').write_text(COMMIT + '\n')
    (SOURCE / 'GIT-TAG').write_text(TAG + '\n')


def prepare_source():
    """Sparse checkout excludes the blob before any source file is downloaded."""
    if (SOURCE / 'CMakeLists.txt').exists():
        if (SOURCE / EXCLUDED).exists():
            raise RuntimeError('Refusing source checkout containing the excluded key header')
        provenance_path = ROOT / '.local/core-provenance.json'
        if ((SOURCE / '.git/objects').exists() or not provenance_path.exists()
                or json.loads(provenance_path.read_text()).get('commit') != COMMIT):
            raise RuntimeError('Source preparation is incomplete or unverified; refusing to build it')
        write_export_identity()
        return
    SOURCE.mkdir(parents=True, exist_ok=True)
    git('init')
    git('remote', 'add', 'origin', URL)
    git('config', 'remote.origin.promisor', 'true')
    git('config', 'remote.origin.partialclonefilter', 'blob:none')
    git('fetch', '--depth=1', '--filter=blob:none', 'origin', COMMIT)
    git('sparse-checkout', 'init', '--no-cone')
    git('sparse-checkout', 'set', '--no-cone', '--stdin',
        input=f'/*\n!/{EXCLUDED}\n', text=True)
    git('checkout', '--detach', COMMIT)
    # GIT_NO_LAZY_FETCH ensures this check cannot retrieve the excluded object.
    entry = git('ls-tree', COMMIT, EXCLUDED, capture_output=True, text=True).stdout
    blob = entry.split()[2]
    check = subprocess.run(['git', 'cat-file', '-e', blob], cwd=SOURCE,
                           env={**os.environ, 'GIT_NO_LAZY_FETCH': '1'},
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if check.returncode == 0 or (SOURCE / EXCLUDED).exists():
        shutil.rmtree(SOURCE)
        raise RuntimeError('Server did not honor the source blob exclusion; checkout removed')
    git('submodule', 'update', '--init', '--depth=1', '--jobs=8', '--', *MODULES)
    git('submodule', 'update', '--init', '--depth=1', '--jobs=2', '--',
        'externals/mcl', 'externals/robin-map', cwd=SOURCE / 'externals/dynarmic')
    provenance = {'url': URL, 'tag': TAG, 'commit': COMMIT,
                  'excluded': [EXCLUDED], 'excluded_blob_not_downloaded': True,
                  'submodules': []}
    pointers = [p for p in SOURCE.rglob('.git') if p.is_file()]
    for pointer in pointers:
        revision = git('rev-parse', 'HEAD', cwd=pointer.parent,
                       capture_output=True, text=True).stdout.strip()
        provenance['submodules'].append({'path': str(pointer.parent.relative_to(SOURCE)),
                                         'commit': revision})
    (ROOT / '.local/core-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    for pointer in pointers:
        pointer.unlink()
    shutil.rmtree(SOURCE / '.git')
    write_export_identity()


def apply_source_patch(source, patch):
    """Apply once; --force prevents BSD patch silently reversing a dry-run."""
    command = ['patch', '--force', '--fuzz=0', '-p1', '-i', str(patch)]
    reverse = subprocess.run([*command, '--dry-run', '-R'], cwd=source, capture_output=True)
    if reverse.returncode == 0:
        return
    forward = subprocess.run([*command, '--dry-run'], cwd=source, capture_output=True)
    if forward.returncode != 0:
        raise RuntimeError(f'Patch does not match source in either direction: {patch}')
    run(*command, cwd=source)


def ensure_build_tools():
    if subprocess.run(['xcrun', '--find', 'clang++'], capture_output=True).returncode:
        raise RuntimeError('Apple command-line developer tools are unavailable')
    if not shutil.which('brew'):
        raise RuntimeError('Homebrew is required to provision CMake, Ninja and OpenSSL 3')
    missing = [name for name in ('cmake', 'ninja') if not shutil.which(name)]
    openssl = subprocess.run(['brew', 'list', '--versions', 'openssl@3'],
                             capture_output=True, text=True)
    if openssl.returncode or not openssl.stdout.strip():
        missing.append('openssl@3')
    if missing:
        run('brew', 'install', *missing)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--jobs', type=int, default=8)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    prepare_source()
    for patch in sorted((ROOT / 'patches').glob('azahar-*.patch')):
        apply_source_patch(SOURCE, patch)
    apply_source_patch(SOURCE, ROOT / 'patches/libretro-touch-bounds.patch')
    if args.prepare_only:
        return
    ensure_build_tools()
    openssl = run('brew', '--prefix', 'openssl@3', capture_output=True, text=True).stdout.strip()
    run('cmake', '-S', SOURCE, '-B', BUILD, '-G', 'Ninja',
        '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_ARCHITECTURES=arm64',
        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5', '-DENABLE_LIBRETRO=ON',
        '-DENABLE_VULKAN=OFF', '-DENABLE_OPENGL=OFF',
        '-DENABLE_SOFTWARE_RENDERER=ON', '-DENABLE_BUILTIN_KEYBLOB=OFF',
        '-DENABLE_TESTS=OFF', '-DENABLE_LTO=OFF', '-DCITRA_WARNINGS_AS_ERRORS=OFF',
        '-DUSE_SYSTEM_OPENSSL=ON', f'-DOPENSSL_ROOT_DIR={openssl}')
    run('cmake', '--build', BUILD, '--target', 'citra_libretro', '-j', args.jobs)
    print(BUILD / 'bin/Release/azahar_libretro.dylib')


if __name__ == '__main__':
    main()

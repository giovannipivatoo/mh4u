#!/usr/bin/env python3
"""Build the key-free GPU libretro core and pinned MoltenVK, without Qt."""
import argparse
import configparser
import json
import shutil
import tarfile
import urllib.request

from build_core import COMMIT, ROOT, SOURCE, apply_source_patch, ensure_build_tools, prepare_source, run
from prepare_image import file_hash, require

BUILD = ROOT / '.local/core-vulkan-build'
MODULES = ('externals/glslang', 'externals/vma', 'externals/vulkan-headers',
           'externals/sirit/sirit', 'externals/spirv-tools', 'externals/spirv-headers')
MOLTENVK_URL = 'https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.1/MoltenVK-all.tar'
MOLTENVK_SHA256 = '2c498bf8c98b88ba1e84c1f153403d4c1a8490c122d9e2a3df238b25d4e10557'


def prepare_graphics_dependencies():
    metadata = ROOT / f'.local/reference/upstream-tree-{COMMIT}.json'
    metadata.parent.mkdir(parents=True, exist_ok=True)
    if not metadata.exists():
        with urllib.request.urlopen(f'https://api.github.com/repos/azahar-emu/azahar/git/trees/{COMMIT}?recursive=1') as response:
            metadata.write_bytes(response.read())
    tree = json.loads(metadata.read_text())
    require(not tree.get('truncated'), 'Incomplete pinned dependency tree')
    revisions = {entry['path']: entry['sha'] for entry in tree['tree'] if entry['type'] == 'commit'}
    modules = configparser.ConfigParser()
    modules.read(SOURCE / '.gitmodules')
    urls = {modules[s]['path']: modules[s]['url'] for s in modules.sections()}
    provenance_path = ROOT / '.local/vulkan-source-provenance.json'
    known = {}
    for path in (ROOT / '.local/reference/provenance.json', provenance_path):
        if path.exists():
            data = json.loads(path.read_text())
            if data.get('source_commit') == COMMIT:
                known.update({item['path']: item['commit'] for item in data['submodules']})
    provenance = {'source_commit': COMMIT, 'submodules': []}
    for module in MODULES:
        path = SOURCE / module
        path.mkdir(parents=True, exist_ok=True)
        if not any(path.iterdir()) or (path / '.git').exists():
            run('git', 'init', path)
            run('git', 'config', 'remote.origin.url', urls[module], cwd=path)
            run('git', 'fetch', '--depth=1', 'origin', revisions[module], cwd=path)
            run('git', 'checkout', '--detach', 'FETCH_HEAD', cwd=path)
            known[module] = revisions[module]
        require(known.get(module) == revisions[module], f'Unverified graphics dependency: {module}')
        provenance['submodules'].append({'path': module, 'url': urls[module], 'commit': revisions[module]})
        provenance_path.write_text(json.dumps(provenance, indent=2) + '\n')
        if (path / '.git').exists():
            shutil.rmtree(path / '.git')


def prepare_moltenvk():
    target = ROOT / '.local/vulkan'
    target.mkdir(parents=True, exist_ok=True)
    archive = ROOT / '.local/reference-build/externals/MoltenVK.tar'
    if not archive.exists():
        archive = target / 'MoltenVK-all.tar'
        if not archive.exists():
            partial = archive.with_suffix('.part')
            try:
                urllib.request.urlretrieve(MOLTENVK_URL, partial)
                require(file_hash(partial) == MOLTENVK_SHA256, 'MoltenVK download SHA-256 mismatch')
                partial.replace(archive)
            finally:
                partial.unlink(missing_ok=True)
    require(file_hash(archive) == MOLTENVK_SHA256, 'MoltenVK archive SHA-256 mismatch')
    # Extract only the macOS runtime, not the other platforms bundled upstream.
    with tarfile.open(archive) as package:
        member = package.getmember('MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib')
        require(member.isfile(), 'Expected a regular MoltenVK dynamic library')
        data = package.extractfile(member).read()
    library = target / 'libMoltenVK.dylib'
    if not library.exists() or library.read_bytes() != data:
        library.write_bytes(data)
        library.chmod(0o755)
    (target / 'provenance.json').write_text(json.dumps({'url': MOLTENVK_URL,
        'archive_sha256': MOLTENVK_SHA256, 'library_sha256': file_hash(library)}, indent=2) + '\n')
    return library


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--jobs', type=int, default=8)
    args = parser.parse_args()
    require(args.jobs > 0, 'Jobs must be positive')
    prepare_source()
    for patch in sorted((ROOT / 'patches').glob('azahar-*.patch')):
        apply_source_patch(SOURCE, patch)
    apply_source_patch(SOURCE, ROOT / 'patches/libretro-vulkan-frame-completion.patch')
    apply_source_patch(SOURCE, ROOT / 'patches/libretro-touch-bounds.patch')
    prepare_graphics_dependencies()
    print(f'MoltenVK: {prepare_moltenvk()}', flush=True)
    if args.prepare_only:
        return
    ensure_build_tools()
    openssl = run('brew', '--prefix', 'openssl@3', capture_output=True, text=True).stdout.strip()
    run('cmake', '-S', SOURCE, '-B', BUILD, '-G', 'Ninja',
        '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_ARCHITECTURES=arm64',
        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5', '-DENABLE_LIBRETRO=ON',
        '-DENABLE_VULKAN=ON', '-DENABLE_OPENGL=OFF',
        '-DENABLE_SOFTWARE_RENDERER=ON', '-DENABLE_BUILTIN_KEYBLOB=OFF',
        '-DENABLE_TESTS=OFF', '-DENABLE_LTO=OFF', '-DCITRA_WARNINGS_AS_ERRORS=OFF',
        '-DUSE_SYSTEM_OPENSSL=ON', f'-DOPENSSL_ROOT_DIR={openssl}')
    run('cmake', '--build', BUILD, '--target', 'citra_libretro', '-j', args.jobs)
    print(BUILD / 'bin/Release/azahar_libretro.dylib')


if __name__ == '__main__':
    main()

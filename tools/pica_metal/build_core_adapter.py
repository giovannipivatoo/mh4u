#!/usr/bin/env python3
"""Build the experimental PICA Metal Azahar core from the verified local export."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[2]
EXPORT = ROOT / ".local/azahar-src"
DEFAULT_SOURCE = ROOT / ".local/pica-metal-core-source"
DEFAULT_BUILD = ROOT / ".local/pica-metal-core-build"
EXCLUDED_KEY_HEADER = "src/core/hw/default_keys.h"
PATCH = ROOT / "patches/experimental-pica-metal-core-adapter.patch"
AZAHAR_COMMIT = "26e608f6fa292b27cda0ae8c84e148d17600a5e6"


def run(*arguments, cwd=ROOT, capture_output=False):
    return subprocess.run([str(value) for value in arguments], cwd=cwd, check=True,
                          capture_output=capture_output, text=capture_output)


def verify_source_export():
    provenance_path = ROOT / ".local/core-provenance.json"
    if not provenance_path.is_file():
        raise RuntimeError("verified local Azahar provenance is missing")
    source_provenance = json.loads(provenance_path.read_text())
    if (source_provenance.get("commit") != AZAHAR_COMMIT or
        EXCLUDED_KEY_HEADER not in source_provenance.get("excluded", [])):
        raise RuntimeError("local Azahar provenance does not prove the pinned key-free export")
    if not (EXPORT / "CMakeLists.txt").is_file() or (EXPORT / EXCLUDED_KEY_HEADER).exists():
        raise RuntimeError("local Azahar export is missing or contains the excluded key header")
    return source_provenance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--build", type=Path, default=DEFAULT_BUILD)
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    local = (ROOT / ".local").resolve()
    args.source = args.source.resolve()
    args.build = args.build.resolve()
    if (not args.source.is_relative_to(local) or not args.build.is_relative_to(local) or
        args.source == EXPORT.resolve() or args.source == args.build or
        args.source in args.build.parents or args.build in args.source.parents):
        raise RuntimeError("candidate source and build must be distinct paths below .local")
    source_provenance = verify_source_export()
    if args.source.exists() or args.build.exists():
        raise RuntimeError("candidate source/build already exists; choose fresh --source and --build")
    if not shutil.which("cmake") or not shutil.which("ninja"):
        raise RuntimeError("CMake and Ninja must already be installed")

    shutil.copytree(EXPORT, args.source, symlinks=True)
    if (args.source / EXCLUDED_KEY_HEADER).exists():
        raise RuntimeError("copied candidate unexpectedly contains the excluded key header")
    run("git", "apply", "--check", PATCH, cwd=args.source)
    run("git", "apply", PATCH, cwd=args.source)
    openssl = run("brew", "--prefix", "openssl@3", capture_output=True).stdout.strip()
    configure = [
        "cmake", "-S", args.source, "-B", args.build, "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_ARCHITECTURES=arm64",
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DENABLE_LIBRETRO=ON",
        "-DENABLE_QT=OFF", "-DENABLE_SDL2=OFF", "-DENABLE_TESTS=OFF",
        "-DENABLE_ROOM=OFF", "-DENABLE_WEB_SERVICE=OFF", "-DENABLE_SCRIPTING=OFF",
        "-DENABLE_GDBSTUB=OFF", "-DENABLE_CUBEB=OFF", "-DENABLE_OPENAL=OFF",
        "-DENABLE_LIBUSB=OFF", "-DENABLE_VULKAN=OFF", "-DENABLE_OPENGL=OFF",
        "-DENABLE_SOFTWARE_RENDERER=ON", "-DENABLE_BUILTIN_KEYBLOB=OFF",
        "-DENABLE_LTO=OFF", "-DCITRA_WARNINGS_AS_ERRORS=OFF",
        "-DUSE_SYSTEM_OPENSSL=ON", f"-DOPENSSL_ROOT_DIR={openssl}",
        "-DENABLE_MH4U_PICA_METAL=ON", f"-DMH4U_PICA_METAL_ROOT={ROOT}",
    ]
    run(*configure)
    run("cmake", "--build", args.build, "--target", "azahar_libretro", "-j", args.jobs)
    provenance = {
        "source_export": str(EXPORT),
        "source_provenance": source_provenance,
        "excluded_key_header": EXCLUDED_KEY_HEADER,
        "enable_builtin_keyblob": False,
        "patch_sha256": hashlib.sha256(PATCH.read_bytes()).hexdigest(),
        "configure": [str(value) for value in configure],
    }
    args.build.mkdir(parents=True, exist_ok=True)
    (args.build / "pica-metal-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(args.build / "bin/Release/azahar_libretro.dylib")


if __name__ == "__main__":
    main()

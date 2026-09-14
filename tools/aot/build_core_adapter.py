#!/usr/bin/env python3
"""Build the isolated, fail-closed Azahar AOT adapter from verified local inputs."""

import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess


ROOT = pathlib.Path(__file__).resolve().parents[2]
BASE_SOURCE = ROOT / ".local/azahar-src"
CANDIDATE_SOURCE = ROOT / ".local/aot-core-source"
BUILD = ROOT / ".local/aot-core-build"
CODE = ROOT / ".local/game/exefs/code.bin"
ARTIFACT = ROOT / ".local/aot-core-title-chain.cpp"
MANIFEST = ROOT / ".local/aot-core-title-chain.json"
PATCH = ROOT / "patches/experimental-aot-core-adapter.patch"
EXPECTED_CODE_SHA256 = "63940d7ef1fecc119f9fb820f5f6a2cf2f2a5549e4a70f00319fbd6c9c1ad8dc"
EXPECTED_CORE_COMMIT = "26e608f6fa292b27cda0ae8c84e148d17600a5e6"
EXCLUDED_KEY_BLOB = "src/core/hw/default_keys.h"


def run(*args, cwd=ROOT, capture=False):
    return subprocess.run([str(arg) for arg in args], cwd=cwd, check=True,
                          text=True, capture_output=capture)


def apply_patch() -> None:
    command = ["patch", "--force", "--fuzz=0", "-p1", "-i", str(PATCH)]
    reverse = subprocess.run([*command, "--dry-run", "-R"], cwd=CANDIDATE_SOURCE,
                             capture_output=True)
    if reverse.returncode == 0:
        return
    forward = subprocess.run([*command, "--dry-run"], cwd=CANDIDATE_SOURCE,
                             capture_output=True)
    if forward.returncode != 0:
        raise RuntimeError("experimental AOT adapter patch does not match the pinned source")
    run(*command, cwd=CANDIDATE_SOURCE)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--generator", default=ROOT / ".local/aot-candidate/mh4u-aot-generator",
                        type=pathlib.Path)
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args()
    if args.jobs <= 0:
        parser.error("--jobs must be positive")
    if (BASE_SOURCE / EXCLUDED_KEY_BLOB).exists():
        raise RuntimeError("refusing source tree containing the excluded built-in key header")
    provenance = json.loads((ROOT / ".local/core-provenance.json").read_text())
    if provenance.get("commit") != EXPECTED_CORE_COMMIT:
        raise RuntimeError("local Azahar provenance does not match the pinned commit")
    if EXCLUDED_KEY_BLOB not in provenance.get("excluded", []):
        raise RuntimeError("local Azahar provenance does not record the key blob exclusion")
    if not CANDIDATE_SOURCE.exists():
        shutil.copytree(BASE_SOURCE, CANDIDATE_SOURCE)
    if (CANDIDATE_SOURCE / EXCLUDED_KEY_BLOB).exists():
        raise RuntimeError("refusing candidate source containing the built-in key header")
    apply_patch()
    digest = hashlib.sha256(CODE.read_bytes()).hexdigest()
    if digest != EXPECTED_CODE_SHA256:
        raise RuntimeError(f"title code SHA-256 mismatch: {digest}")
    run(args.generator, "--binary", CODE, "--base", "0x100000", "--pc", "0x100000",
        "--cpsr", "0x10", "--fpscr", "0x03c00010", "--max-blocks", "64",
        "--max-instructions", "4096", "--max-dispatch-steps", "1000000",
        "--input-sha256", digest, "--artifact-root", ROOT / ".local",
        "--output", ARTIFACT, "--manifest", MANIFEST)
    openssl = run("brew", "--prefix", "openssl@3", capture=True).stdout.strip()
    run("cmake", "-S", CANDIDATE_SOURCE, "-B", BUILD, "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_ARCHITECTURES=arm64",
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DENABLE_LIBRETRO=ON",
        "-DENABLE_VULKAN=OFF", "-DENABLE_OPENGL=OFF", "-DENABLE_SOFTWARE_RENDERER=ON",
        "-DENABLE_BUILTIN_KEYBLOB=OFF", "-DENABLE_TESTS=OFF", "-DENABLE_LTO=OFF",
        "-DCITRA_WARNINGS_AS_ERRORS=OFF", "-DUSE_SYSTEM_OPENSSL=ON",
        f"-DOPENSSL_ROOT_DIR={openssl}", "-DENABLE_MH4U_AOT=ON",
        f"-DMH4U_AOT_RUNTIME_ROOT={ROOT}", f"-DMH4U_AOT_ARTIFACT={ARTIFACT}")
    run("cmake", "--build", BUILD, "--target", "citra_libretro", "-j", args.jobs)
    print(BUILD / "bin/Release/azahar_libretro.dylib")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

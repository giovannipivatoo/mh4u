#!/usr/bin/env python3
"""Build one fail-closed Azahar core with the preserved-hot AOT and Metal adapters."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[2]
LOCAL = (ROOT / ".local").resolve()
EXPORT = ROOT / ".local/azahar-src"
DEFAULT_SOURCE = ROOT / ".local/aot-metal-combined-core-source"
DEFAULT_BUILD = ROOT / ".local/aot-metal-combined-core-build"
DEFAULT_ARTIFACT = ROOT / ".local/aot-hot-preservation-final-20260915/iteration-02/title.cpp"
DEFAULT_MANIFEST = ROOT / ".local/aot-hot-preservation-final-20260915/iteration-02/title.json"
PATCH = ROOT / "patches/experimental-aot-metal-core-adapter.patch"
CORE_PROVENANCE = ROOT / ".local/core-provenance.json"
EXCLUDED_KEY_HEADER = "src/core/hw/default_keys.h"
AZAHAR_COMMIT = "26e608f6fa292b27cda0ae8c84e148d17600a5e6"
TITLE_CODE_SHA256 = "63940d7ef1fecc119f9fb820f5f6a2cf2f2a5549e4a70f00319fbd6c9c1ad8dc"
ARTIFACT_SHA256 = "91e417c95f31996baebe7a777bbc8ee523532366c641f3549e8109c4e9726418"
MANIFEST_SHA256 = "8801d71a04e5fd8d4ad0a4317e9d2c3a9569506632cdfad2f1700e407ba43c78"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*arguments, cwd=ROOT, capture=False):
    return subprocess.run([str(value) for value in arguments], cwd=cwd, check=True,
                          text=True, capture_output=capture)


def verify_local_file(path: Path, label: str) -> Path:
    resolved = path.resolve()
    if not resolved.is_relative_to(LOCAL) or not resolved.is_file():
        raise RuntimeError(f"{label} must be an existing file below .local")
    return resolved


def verify_inputs(artifact: Path, manifest_path: Path) -> tuple[dict, dict]:
    provenance = json.loads(CORE_PROVENANCE.read_text())
    if (provenance.get("commit") != AZAHAR_COMMIT or
            EXCLUDED_KEY_HEADER not in provenance.get("excluded", [])):
        raise RuntimeError("local Azahar provenance does not prove the pinned key-free export")
    if not (EXPORT / "CMakeLists.txt").is_file() or (EXPORT / EXCLUDED_KEY_HEADER).exists():
        raise RuntimeError("local Azahar export is missing or contains the excluded key header")
    if sha256(artifact) != ARTIFACT_SHA256 or sha256(manifest_path) != MANIFEST_SHA256:
        raise RuntimeError("combined build requires the verified hot-preservation iteration-02 artifact")
    manifest = json.loads(manifest_path.read_text())
    expected = {
        "input_sha256": TITLE_CODE_SHA256,
        "architecture": "ARMv6K",
        "entry_descriptor_count": 152,
        "block_count": 1024,
        "max_blocks": 1024,
        "max_guest_instruction_fetches": 65536,
        "continue_after_svc": True,
        "emitted_blocks_supported": True,
    }
    for name, value in expected.items():
        if type(manifest.get(name)) is not type(value) or manifest.get(name) != value:
            raise RuntimeError(f"hot-preservation iteration-02 manifest has unexpected {name}")
    return provenance, manifest


def apply_patch(source: Path) -> None:
    command = ["patch", "--batch", "--forward", "--fuzz=0", "-p1", "-i", str(PATCH)]
    check = subprocess.run([*command, "--dry-run"], cwd=source, text=True,
                           capture_output=True)
    if check.returncode != 0:
        raise RuntimeError("combined AOT/Metal patch does not match the pinned source")
    run(*command, cwd=source)
    markers = {
        "CMakeLists.txt": ("option(ENABLE_MH4U_AOT", "option(ENABLE_MH4U_PICA_METAL"),
        "src/core/CMakeLists.txt": ("arm/aot/arm_aot.cpp", "ENABLE_MH4U_PICA_METAL"),
        "src/core/core.cpp": ("Experimental ARM_Aot active", "preserve_experimental_fatal"),
        "src/citra_libretro/citra_libretro.cpp": ("LibRetro::Shutdown()",),
        "src/video_core/renderer_software/renderer_software.cpp": ("MH4U_PICA_METAL_CORE",),
    }
    for relative, required in markers.items():
        text = (source / relative).read_text()
        if not all(marker in text for marker in required):
            raise RuntimeError(f"combined patch marker missing from {relative}")
    if not (source / "src/core/arm/aot/arm_aot.cpp").is_file():
        raise RuntimeError("combined patch did not install ARM_Aot")


def verify_cache(build: Path) -> None:
    entries = {}
    for line in (build / "CMakeCache.txt").read_text().splitlines():
        if not line.startswith(("//", "#")) and ":" in line and "=" in line:
            name, value = line.split("=", 1)
            entries[name.split(":", 1)[0]] = value
    required = {
        "ENABLE_MH4U_AOT": "ON",
        "ENABLE_MH4U_PICA_METAL": "ON",
        "ENABLE_BUILTIN_KEYBLOB": "OFF",
        "ENABLE_VULKAN": "OFF",
        "ENABLE_OPENGL": "OFF",
        "ENABLE_SOFTWARE_RENDERER": "ON",
    }
    missing = [f"{name}={value}" for name, value in required.items()
               if entries.get(name) != value]
    if missing:
        raise RuntimeError("combined CMake cache is missing required flags: " + ", ".join(missing))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--build", type=Path, default=DEFAULT_BUILD)
    parser.add_argument("--artifact", type=Path, default=DEFAULT_ARTIFACT)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    source = args.source.resolve()
    build = args.build.resolve()
    artifact = verify_local_file(args.artifact, "--artifact")
    manifest_path = verify_local_file(args.manifest, "--manifest")
    if (not source.is_relative_to(LOCAL) or not build.is_relative_to(LOCAL) or
            source == EXPORT.resolve() or source == build or source in build.parents or
            build in source.parents):
        raise RuntimeError("candidate source and build must be distinct paths below .local")
    if source.exists() or build.exists():
        raise RuntimeError("candidate source/build already exists; choose fresh paths")
    if not shutil.which("cmake") or not shutil.which("ninja"):
        raise RuntimeError("CMake and Ninja must already be installed")
    source_provenance, artifact_manifest = verify_inputs(artifact, manifest_path)
    shutil.copytree(EXPORT, source, symlinks=True)
    if (source / EXCLUDED_KEY_HEADER).exists():
        raise RuntimeError("copied candidate unexpectedly contains the excluded key header")
    apply_patch(source)
    openssl = run("brew", "--prefix", "openssl@3", capture=True).stdout.strip()
    configure = [
        "cmake", "-S", source, "-B", build, "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_ARCHITECTURES=arm64",
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DENABLE_LIBRETRO=ON",
        "-DENABLE_QT=OFF", "-DENABLE_SDL2=OFF", "-DENABLE_TESTS=OFF",
        "-DENABLE_ROOM=OFF", "-DENABLE_WEB_SERVICE=OFF", "-DENABLE_SCRIPTING=OFF",
        "-DENABLE_GDBSTUB=OFF", "-DENABLE_CUBEB=OFF", "-DENABLE_OPENAL=OFF",
        "-DENABLE_LIBUSB=OFF", "-DENABLE_VULKAN=OFF", "-DENABLE_OPENGL=OFF",
        "-DENABLE_SOFTWARE_RENDERER=ON", "-DENABLE_BUILTIN_KEYBLOB=OFF",
        "-DENABLE_LTO=OFF", "-DCITRA_WARNINGS_AS_ERRORS=OFF",
        "-DUSE_SYSTEM_OPENSSL=ON", f"-DOPENSSL_ROOT_DIR={openssl}",
        "-DENABLE_MH4U_AOT=ON", f"-DMH4U_AOT_RUNTIME_ROOT={ROOT}",
        f"-DMH4U_AOT_ARTIFACT={artifact}", "-DENABLE_MH4U_PICA_METAL=ON",
        f"-DMH4U_PICA_METAL_ROOT={ROOT}",
    ]
    run(*configure)
    verify_cache(build)
    run("cmake", "--build", build, "--target", "azahar_libretro", "-j", args.jobs)
    core = build / "bin/Release/azahar_libretro.dylib"
    if not core.is_file():
        raise RuntimeError("combined core product is missing")
    pica_sources = sorted((ROOT / "src/pica_metal").glob("*"))
    aot_sources = (ROOT / "src/aot/runtime.h", ROOT / "src/aot/runtime.cpp")
    report = {
        "schema_version": 1,
        "scope": "experimental combined AOT/Metal core build, not gameplay",
        "source_export": str(EXPORT.relative_to(ROOT)),
        "source_provenance": source_provenance,
        "excluded_key_header": EXCLUDED_KEY_HEADER,
        "combined_patch_sha256": sha256(PATCH),
        "aot_artifact": {
            "path": str(artifact.relative_to(ROOT)),
            "sha256": sha256(artifact),
            "manifest_path": str(manifest_path.relative_to(ROOT)),
            "manifest_sha256": sha256(manifest_path),
            "entry_descriptor_count": artifact_manifest["entry_descriptor_count"],
        },
        "pica_sources": {
            str(path.relative_to(ROOT)): sha256(path) for path in pica_sources if path.is_file()
        },
        "aot_runtime_sources": {
            str(path.relative_to(ROOT)): sha256(path) for path in aot_sources
        },
        "core": {"path": str(core.relative_to(ROOT)), "sha256": sha256(core)},
        "configure": [str(value) for value in configure],
    }
    (build / "aot-metal-provenance.json").write_text(json.dumps(report, indent=2) + "\n")
    print(core)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

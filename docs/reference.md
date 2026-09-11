# Reference emulator and CPU runtime

The core and standalone reference use **Azahar 2126.1**, pinned to
`26e608f6fa292b27cda0ae8c84e148d17600a5e6`.
[Upstream release](https://github.com/azahar-emu/azahar/releases/tag/2126.1).

The installed standalone application is `~/Applications/Azahar Reference.app`
(bundle ID `local.mh4u.azaharreference`). It uses its own state in
`~/Library/Application Support/Azahar Reference/`. The native MH4U runtime has
separate saves. Both applications deny network access through a macOS process
sandbox; disabling upstream web features alone would not provide that boundary.
The reference's optional UDP input listener was made tolerant of sandbox denial.
An opt-in test setting holds Qt key and touch taps for 75ms for guest input polling;
it is enabled only by the reference installer's `--test-input` option.

```sh
python3 tools/build_vulkan_core.py          # runtime GPU core, no Qt needed
python3 tools/build_core.py                 # software-only diagnostic core
python3 tools/build_reference.py --install  # standalone Qt reference application
```

The GPU core is `.local/core-vulkan-build/bin/Release/azahar_libretro.dylib`.
It dynamically loads verified MoltenVK 1.4.1 and includes the software rasterizer
as a fallback. The separate software-only build remains under `.local/core-build`.
All executables run natively as arm64. The core currently links Homebrew OpenSSL;
the installed native application is local to this development machine, not a
self-contained distributable package. Git metadata is removed from sanitized
source exports; `.local/core-provenance.json`, `.local/vulkan-source-provenance.json`
and `.local/reference/provenance.json` retain pinned revision provenance.

The standalone reference created the disposable Hunter/Palico save and reached
the opening sandship deck. Movement was visibly verified; its status bar showed
59–60 FPS at 99–100% speed in that scene. These are observations, not a controlled
benchmark or independent emulation validation. Evidence is recorded in
`.local/reference/playable-validation.json`. Opening Qt Preferences subsequently
hung while waiting for microphone authorization. No permission was accepted;
a thread sample was saved and the exact reference process was forcibly stopped
after its ordinary game save had already persisted. The reference's settings
dialog and rebuilt savestate compatibility remain known limitations. The native
GPU bridge independently passes 300-frame startup and 1,500-frame scripted input
tests; captures show formatting completion and Circle Pad Pro confirmation.
Exact binary hashes and unpaced timings are in `.local/vulkan/regression/report.json`.

`patches/libretro-vulkan-frame-completion.patch` fixes the libretro handoff used
by our synchronous bridge: the producer previously flushed asynchronous worker
commands and supplied no synchronization semaphore. Completing producer work
before handing off the image avoids racing host readback. The host also honors
provided semaphores and restores image layouts. This conservative synchronous
path has an explicit GPU/readback performance cost.

Embedded keys are disabled and excluded from source preparation. No firmware
is needed for the tested HLE boot path. [Build options](https://github.com/azahar-emu/azahar/blob/2126.1/CMakeLists.txt).

The official prebuilt archive was downloaded before its default embedded-key
option was discovered, then immediately deleted without execution. The source's
`default_keys.h` was deleted without reading it, along with Git objects that
could retain it. Future clean preparation uses a filtered sparse Git checkout
excluding that header before blob retrieval, verifies the excluded object is
absent with lazy fetching disabled, then removes Git metadata. A synthetic local
Git fixture verified both working-tree and object-store exclusion. An initial
CTRTool extraction binary/archive was also removed after discovering that it
contained static key defaults. Extraction now uses our Python standard-library
implementation and independently reproduced every extracted file. No firmware,
ROM, or game assets were downloaded.

For specialized ARMv6K-to-AArch64 execution, reuse Dynarmic's A32 interface:
it supplies memory callbacks, SVC hooks, tick control, and instrumentation.
Azahar pins Dynarmic `e77b1ba0b7da7cbe93021b01a663acfe7c4dd516`.
Its own code uses the permissive 0BSD license; dependency licenses still apply.
Azahar source files specify GPL-2.0-or-later, so reusing its HLE/core code carries
those obligations. A native wrapper does not change the emulator core's license.
[Dynarmic](https://github.com/azahar-emu/dynarmic),
[license](https://github.com/azahar-emu/dynarmic/blob/master/LICENSE.txt),
[Azahar source notice](https://github.com/azahar-emu/azahar/blob/2126.1/src/core/core.cpp).

Panda3DS is another open-source macOS-capable HLE emulator using Dynarmic, under
GPL-3.0. Its upstream describes compatibility and audio as incomplete, so it was
not selected as this first reference. That choice is an engineering assessment,
not a claim that MH4U was tested against either emulator.
[Panda3DS](https://github.com/wheremyfoodat/Panda3DS).

## Local software-renderer crash correction

The supplied MH4U image initially crashed during boot in both CPU modes.
LLDB identified `LookupTexelInTile` reading an invalid host address while
sampling a valid 8×8 VRAM texture at physical address `0x18154900`.
The rasterizer runs scanlines concurrently, but `GetPhysMemRegionInfo` used a
shared mutable cache for backing storage and region boundaries. Unsynchronized
calls could return storage from one region with another region's base.

`patches/azahar-memory-region-race.patch` removes that four-region cache and
returns each lookup result locally. This fixes the shared translation path,
without masking texture samples or disabling parallel rendering. The build
script applies the patch idempotently; reverse/apply round-trip was checked.

After rebuilding, both fresh-state 300-frame boot tests completed with exit 0:
JIT produced 245 nonblack frames in 17.53 seconds; interpreter produced 248 in
19.71 seconds. These simultaneously executed runs are functional checks, not
benchmarks. The JIT capture visibly shows “Formatting complete.” Final frame
hashes differ, so this does not establish deterministic CPU equivalence or
gameplay compatibility. Local evidence: `.local/reference/lldb-crash.txt`,
`fixed-jit-300.log`, `fixed-interpreter-300.log`, and their PPM captures.

Regression command (uses the supplied local image and isolated state):

```sh
python3 tools/mh4u.py verify --frames 300
```

## Checkpoint after the Preferences correction

On 2026-09-11 a Sol agent added
`patches/azahar-reference-passive-microphone-enumeration.patch`, removing the
synchronous authorization request from Preferences device enumeration. Actual
microphone capture retains its permission check. The reference was rebuilt,
installed and code-signature verified; no microphone permission was granted.
Opening Preferences and its Audio page still needs visible CUA validation after
the user resumes work. The earlier hang described above is historical evidence,
not proof that the corrected build still hangs.

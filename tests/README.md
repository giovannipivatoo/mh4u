# Local runtime checks

CTest runs synthetic input/extraction/patch tests, an actual GPU device check,
and Metal 4FX, legacy MetalFX and bilinear presentation checks. No ROM is needed
for the synthetic tests; the device/presentation checks require Apple Silicon.

`native-video` / `--video-self-test` exercises the real frontend consumers with
synthetic frames: padded software rows, opaque black Vulkan output, producer
buffer reuse, a colored final pixel at 4×, downscaling and duplicate preservation.
It requires no game image or GPU context; actual Vulkan/Metal integration is
validated separately with finite private game replays.

`native-texture-pack` exercises recursive import, supported-file filtering,
regional-title checks, symbolic-link rejection and staged activation using
temporary data under `.local/`. Texture integration evidence is kept separately
in `.local/texture-validation/`: a finite Vulkan boot with synthetic replacement
textures checks actual output pixels. It is not full-pack or gameplay validation.

`audio-buffer-policy` checks stereo ordering, bounded backlog with old samples
discarded on overflow, smooth fade/crossfade transitions, starvation/rebuffer
recovery, and 600 simulated producer/consumer ticks without steady-state loss.
`--audio-self-test` checks a real AudioQueue using silence: volume and mute
parameters, callback suspension during pause, and sustained callback recovery
and consumption of new samples after eight pause/resume cycles. It also induces
a source stall and verifies buffered recovery, including teardown errors.
It runs as `native-audio-settings` in CTest. The input self-test checks that closing
settings preserves a manual pause. Presentation tests also disable and restore
spatial MetalFX while running, without changing saved preferences.
`native-menu-tracking` opens an actual Cocoa menu and checks that the shared
tracking scheduler advances while its nested event loop is active. Finite game
runs report `menu_tracking_frames` for verification of actual emulation under a menu.
Presentation tests hide the window and check that the frontend skips acquiring
a drawable, which would otherwise block the shared emulation/audio producer.
`--settings-preview` opens the graphics panel without loading a game or saves;
it is a manual preview, not an automated passing test.

Presentation checks also exercise 2× and 4× inputs with proportional lower-LCD
cropping and cursor readback. `--resolution 1|2|3|4` sets the initial internal
resolution. For a finite live-update check, use `--frames 600 --resolution 1
--resolution-change 150:4 --resolution-change 300:2 --resolution-change 450:1`
with an isolated `--state-dir`. The JSON records requested changes and actual
frame-dimension transitions. These CLI settings do not write user preferences.

`boot-input.json` advances initial save-formatting prompts. `sandship-input.json`
loads the first existing character, dismisses the opening sandship dialogue and
moves forward. Both contain only controller events with zero-based guest frame
numbers; they contain no game code or savedata.

The sandship replay requires an isolated copy of a newly created character save,
with the opening tutorial still pending. Use `--state-dir` to keep it separate
from normal saves. A typical finite native-window run is:

```sh
build/mh4u-runtime --state-dir .local/test-state \
  --input-script tests/sandship-input.json --frames 7400 \
  --capture .local/test-state/final.ppm
```

The scripts are functional checks for this supplied revision and starting state,
not deterministic replays or general gameplay bots. Inspect captures to establish
which scene actually ran; a frame count or nonblack result alone is insufficient.

The native input self-test also covers remapping validation, host-toggle edge and
focus release gating, overlay touch coordinates, hidden-screen touch rejection,
and the upper LCD aspect ratio. The presentation checks read back both cropped
LCD textures and pixels of the final drawable, exercising the lower overlay,
hidden overlay, resizing, and all three presentation paths. Captures from
`--capture` retain the original dual-screen core canvas, not the window layout.

Touchpad cursor checks cover relative movement and bounds, repeated swipes,
finger lift and recontact without cursor jumps, R3 press/release latching,
mouse coexistence, and hidden/focus/
disconnect cancellation. The final drawable readback checks the cursor's white
center and black outline in each Metal presentation mode. Synthetic checks do
not substitute for physical touchpad movement and R3 confirmation by the user.

On Bluetooth, the tested DualSense initially sent simple reports with no touch
data. The runtime uses a public IOKit feature 0x09 read to enable enhanced reports
at connection, then reads touch through GameController. Physical validation covers
one Sony 054c:0ce6 controller; multiple-controller selection is not validated.

### Temporal MetalFX / frame interpolation

`cmake --build build --target temporal-probe && ./build/temporal-probe` executes
real GPU temporal scaling and interpolation on a synthetic moving planar scene.
CTest `metal-temporal-interpolation` skips unsupported devices/OS with code 77.
The test checks scaled object position, cleared stale history after reset, and
three steady interpolated centroids within four output pixels of the true
midpoint and at least four pixels away from either source frame. It records
29 consecutive pairs, allowing the first 26 for history initialization.
This validates the API path, not MH4U temporal rendering or frame pacing.

`patches/azahar-temporal-depth-probe.patch` is an opt-in Vulkan diagnostic.
`MH4U_TEMPORAL_PROBE=1`, `MH4U_TEMPORAL_PROBE_START=N`, and
`MH4U_TEMPORAL_PROBE_FRAMES=N` bound its log window. Use only a finite local
replay with an isolated state directory; color/depth provenance is a candidate,
not proof that every final composite pixel has valid depth.

### Integrated experimental temporal runtime

`temporal-runtime-probe` / CTest `temporal-runtime` exercises the production Metal
motion estimator and TemporalProcessor, including midpoint sign, history reset,
and invalid-motion fallback at each internal scale 1×–4×. CTest
`scaled-optical-motion` checks scaled displacement and validity masks on the GPU.
Unsupported MetalFX devices skip with status 77.
Finite actual-scene tests require the patched core and a private Native save copy:

```sh
build/mh4u-runtime --core .local/temporal-validation/azahar_libretro.dylib \
  --headless --frames 7400 --resolution 1 --state-dir .local/temporal-integration-validation/state \
  --input-script tests/sandship-input.json --no-custom-textures --new-3ds \
  --experimental-frame-generation --temporal-start 7300 \
  --temporal-capture .local/temporal-integration-validation/scene
```

For all-scale coverage, use `--frames 7420 --temporal-start 7240` and
`--resolution-change 7280:2 --resolution-change 7320:3 --resolution-change 7360:4`.
The local scaled validation replay adds movement at frame 7240. Check each
`temporal_scales` entry for successful processing/generation and actual dimensions;
scale changes should reset history and briefly fall back until depth is available.
The first successful depth sample reports its range and the number of pixels with
differing depth inside a native-pixel block (zero by definition at 1×).

Headless generation must report zero generated presentations. A windowed replay
checks generated presentations separately. Neither is proof of smoother gameplay;
the conservative image estimator retains the current image in uncertain regions.

For a short visible presentation check after unpaced loading, replace `--headless`
with `--window-start 7300`. The window appears only for the final segment. This
requires `--frames` greater than the start index and cannot combine with `--headless`.

### Savestates

`native-savestate` / `--savestate-self-test` checks the actual disk container with
synthetic serialization callbacks: roundtrip, corrupt/incompatible rejection before
the core callback, and preservation of an existing slot when serialization fails.
It uses temporary data under `.local/` and needs no game image.

`--savestate-save FRAME:SLOT` saves after the specified zero-based core iteration;
`--savestate-load FRAME:SLOT` loads before it. Both are repeatable, use slots 1–9,
and require an explicit `--state-dir` and finite `--frames` with all action frames
below the limit. Use only an isolated copy of savedata for regression work.
For example, save the ship scene with:

```sh
build/mh4u-runtime --state-dir .local/test-state --headless --frames 7400 \
  --input-script tests/sandship-input.json --savestate-save 7399:1
build/mh4u-runtime --state-dir .local/test-state --headless --frames 180 \
  --savestate-load 120:1 --capture .local/test-state/restored.ppm
```

Use identical core/settings for both processes. Inspect the restored capture to
establish actual scene behavior; successful deserialization alone is insufficient.
Savestates do not snapshot ordinary disk savedata or extdata.

### Game save import

`native-save-import` / `--save-import-self-test` uses synthetic files under
`.local/` to check staged import, merging at activation, backup, file validation,
pending integrity and concurrent-session exclusion. The UI can be exercised with
`--save-import-preview --state-dir .local/import-ui-state`; no game is loaded.
`--import-save PATH --state-dir DIR` stages and exits, so a normal finite game
launch must follow to verify real character recognition. Never use canonical
play data for this validation. The user-supplied `.local/completeSaves/` is private
and must not be committed, uploaded, or modified by tests.

`relocated-savestate-paths` serializes a real core SaveDataArchive in one process
and restores it in a second process with a different user directory. It opens
and writes a new file through the restored backend and requires that only the
destination receives the exact bytes. This failed against the old core's raw
absolute mount strings; it passes with the relative-path patch. The probe links
the local GPU core archives, so rebuild that core after applying source patches.
All fixtures are synthetic and temporary under `.local/`.

`test_install_profile.py` runs within `local-input-boundaries`. Synthetic SDMC
profiles exercise initial workspace-to-installed migration, an absent target,
preservation of existing hunters and installed textures/system files, backup
integrity, session locks, symlink rejection, concurrent source changes and
rollback after a post-swap sync failure. No canonical game data is used.

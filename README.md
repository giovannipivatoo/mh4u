# MH4U Apple Silicon runtime

**Sessione ripresa su richiesta dell’utente il 2026-09-12.** Il contesto persistente è in [RESUME.md](RESUME.md); usare agenti Sol per il lavoro delegato.

A local native macOS host specialized for the supplied **Monster Hunter 4 Ultimate (Europe)** image (`0004000000126100`, `CTR-P-BFGP`). It uses Azahar's ARMv6K → AArch64 JIT and 3DS services, with a Cocoa window, Metal presentation, runtime-selected spatial MetalFX, native audio and input.

**Development status:** the supplied image is extracted and hash-verified. The arm64 runtime boots with both JIT and interpreter CPU paths; accelerated graphics use Azahar's Vulkan PICA backend through MoltenVK, followed by Metal presentation and spatial MetalFX. The native frontend has created and reloaded a character, and automated Harvest Tours have completed through ordinary save and fresh Continue. The user also reports a smooth hunt and confirms DualSense touchpad movement, lower-screen toggle and R3 touch selection. The reproduced post-quest Circle Pad Pro loss was repaired in the user's save and verified across two follow-up mission sequences. A tutorial cannon hit reproduces across two headless runs and the installed native window; the latter submits 750 frames at 59.85 FPS over 12.53 seconds at 1× with spatial MetalFX, without custom textures or audio. These checks establish working gameplay on this machine, not compatibility or performance for every mission. This is a specialized native recompilation runtime with an emulator core and dynamic ARM translation.

## Local use

The `feat/apple-silicon-aot-metal` branch also contains opt-in
[AOT and direct Metal experiments](docs/aot-metal.md). These build separate tools
and tests; the playable runtime described below still uses JIT/Vulkan.

All preparation/build/test commands have been run by the agent. Open `~/Applications/MH4U Runtime.app` or double-click `MH4U.command` to launch the development runtime. The installed app uses verified private copies under Application Support and requires no Desktop-folder permission. The launcher prepares missing local inputs, builds the host and denies network access to the running game. It validates the exact title/code profile and local CXI hash before execution.

```sh
python3 tools/mh4u.py setup                 # prepare supplied input and build
python3 tools/mh4u.py run                   # native window, persistent local saves
python3 tools/mh4u.py run -- --renderer software # slower diagnostic fallback
python3 tools/mh4u.py install               # update the installed native app and private inputs
python3 tools/mh4u.py verify --compare      # finite JIT/interpreter boot comparison
```

The source build uses installed CMake/Ninja, the Apple SDK and Homebrew OpenSSL. Extraction uses only the Python standard library. No account, emulator firmware, console key or game download is required. Everything in `.local/` and `build/` is private/generated and ignored by Git. The original `.3ds` stays untouched.

## Import existing game saves

Use **Game → Import Game Save…** and select an extracted MH4U save folder
containing `user1`, `user2`, `user3` and `system`, or a single `user1`–`user3` file.
The raw `00000001` save folder from Citra/Azahar is supported. The review lists
the files that will be imported; only same-named files are replaced.
Restart the app to apply the queued import, then use **Continue** in MH4U.
An existing savestate restores the older running session, not the imported save.

Before applying the import, the runtime backs up the latest game save folder.
Use **Game → Open Save Backups…** to find it; select a backup's `data/00000001`
folder in the importer to restore it. Staging leaves the current game untouched,
and unselected slots are merged from the latest on-disk data at the next launch.
Only one runtime can use a given state directory at a time.

Supported file sizes are 81,408 bytes for each `user` file and 512 bytes for
`system`. Names and sizes are checked; MH4U validates the actual contents.
Use saves compatible with the supplied European MH4U game. ZIP files, encrypted
SD-card/`.sav` archives, savestates, and extdata (guild cards, downloaded quests,
etc.) are not imported. A fresh destination needs the `system` file as well.

The supplied example source is stored unchanged in `.local/completeSaves/`.
For scripts, `--import-save PATH --state-dir DIR` stages an import and exits;
a later normal launch using that directory applies it. Imports and backups stay
under `<state-dir>/save-import/` in the runtime's private storage.

## Graphics, pause and audio

Use **Settings → Graphics…** for internal resolution and spatial MetalFX, **Settings → Audio…** for volume
and mute, and **Game → Pause Game / Resume Game** (`⌘P`) to pause or continue.
Graphics and audio preferences persist across launches. Browsing the menu bar
keeps emulation running. Opening a settings panel temporarily pauses emulation;
closing it preserves an existing manual pause. Volume and mute can be changed
repeatedly without restarting the game.
Pause keeps the current session in memory and is not a disk save or savestate.

Savestates capture the running session separately from MH4U's normal saves. Use
**Game → Save State / Load State** (three slots); `⌘S` and `⌘L` operate on slot 1.
Files live under `<state-dir>/savestates/` (the installed app uses
`~/Library/Application Support/MH4U Runtime/.local/state/savestates/`).
A state requires the same core binary and compatible emulation settings; damaged
or incompatible files are rejected before loading. Saving replaces that slot
atomically. Loading discards current unsaved session progress, but **does not
roll back ordinary savedata/extdata on disk**. Continue using in-game saves for
long-term progress; a core update can invalidate these snapshots.

Internal resolution supports **1× (400×240), 2× (800×480), 3× (1200×720), and
4× (1600×960)** for the upper LCD. Changes apply when gameplay resumes, without
restarting the core. Higher values render more pixels and increase GPU/readback
work; 4× has sixteen times as many pixels as 1×. The lower LCD and touch mapping
retain their original proportions. `--resolution 1|2|3|4` overrides the saved
preference for a launch, including finite headless validation runs.

Experimental temporal options are available in **Settings → Graphics…** when the
core supports synchronized depth streaming. **MetalFX temporal — estimated motion**
preserves the selected internal resolution, from 1× through 4×. The upper-screen
output is 800×480 at 1×/2×, 1200×720 at 3×, and 1600×960 at 4×; the
normal compositor fits that image to the window. At 2×–4× temporal processing uses
the internal pixel dimensions. Spatial MetalFX remains the fallback
for unsupported scenes or missing/mismatched depth. Pause, scene discontinuities
and setting changes reset history. The lower screen is composited separately.

**Frame generation — optical flow** is a separate experimental Metal interpolator,
not MetalFX frame interpolation. It presents an estimated midpoint before the current
frame, using the measured image motion. Unreliable regions retain the current image.
It can add latency and does not promise a frame-rate increase or improved quality;
most pixels fell back to the current image in the checked sandship sequence.
Both experimental options default off. The HD pack can remain enabled, but this
new temporal path has not been validated across the entire pack or during hunts.

For finite local validation, use `--experimental-temporal` or
`--experimental-frame-generation`, `--resolution 1` through `4`, and an isolated `--state-dir`.
`--temporal-start FRAME` delays processing and requires a larger `--frames` limit.
`--temporal-capture PREFIX` writes processed PPM captures inside `.local/` and requires
an explicit state directory and frame limit. `--no-temporal` overrides saved settings.
The runtime JSON distinguishes temporal processing, generated images, and actual
generated presentations. The native `temporal-runtime-probe` tests the production
motion estimator, temporal history/reset, and conservative interpolation on the GPU.

## HD texture packs

Use **Settings → Textures… → Install Texture Pack…** and select an extracted
Citra/Azahar texture folder. For this European game, select `0004000000126100`
(or its parent). PNG, DDS, KTX and `pack.json` retain their subfolders. Archives
must be extracted first. Apply the author's patches to the extracted folder before
importing; installing a pack replaces the previous pack. The runtime copies it into its private state;
installation, activation and system-profile changes take effect after restarting.
Enable **Use custom textures** in the same panel. Large packs can take several
minutes to copy; textures are loaded on demand rather than preloaded into RAM.

The author's [MH4U HD v3.0 instructions](https://pastebin.com/45Pu5HQP) specify
the EU pack, **Old 3DS** for monster texture matching, and game update 1.1 to
avoid font problems. Choose the system profile explicitly in the texture panel.
The runtime does not install game updates or download texture packs. Compatibility
with every texture in that pack requires testing with a locally supplied copy.
Texture replacement is separate from internal rendering resolution and MetalFX;
a pack does not change the 3DS screen aspect ratio or select a 1920×1080 canvas.

For an isolated run:

```sh
build/mh4u-runtime --state-dir .local/texture-test-state \
  --texture-pack .local/my-pack/0004000000126100 \
  --custom-textures --old-3ds --resolution 4
```

CLI choices do not change saved UI preferences. The installed app's texture
storage is beneath `~/Library/Application Support/MH4U Runtime/.local/state/Azahar/load/textures/`.

## DualSense and screens

The installed app starts with the upper 3DS screen in macOS full screen, preserving
its 400:240 aspect ratio. Click the DualSense touchpad to show or hide the lower
screen in a corner. Slide a finger on the DualSense touchpad to move its visible
cursor like a mouse, then press **R3** (right-stick click) to touch that point.
Movement is relative: lift and reposition your finger to continue moving toward
any edge without jumping the cursor. Holding R3 supports dragging. The mouse still works.
R3 is reserved for touch while the lower screen is visible. **Settings → Controller…**
(`⌘,`) remaps each 3DS button, the Circle Pad/C-Stick and **Toggle Lower**. Press
**Save** to keep the configuration across launches. Defaults follow physical
positions: Circle=A, Cross=B, Triangle=X, Square=Y; L1/R1=L/R, L2/R2=ZL/ZR,
Options=Start and Create=Select. The control assigned to Toggle Lower is reserved
for that action and does not also press a game button.

**Settings → Show Lower Screen** (`⌘B`) works without a controller. **Start in Full
Screen** controls the window mode and remembers the choice; Escape leaves full
screen, and Escape in a window quits. The standard green window button also works.
Controller mapping pauses game execution while the dialog is open; release the
controller buttons/sticks before continuing after changing focus or settings.

| Control | Keyboard |
|---|---|
| Circle Pad | W A S D |
| D-pad | Arrow keys |
| B / A / Y / X | J / K / U / I |
| L / R | Q / E |
| ZL / ZR | 1 / 3 |
| Start / Select | Enter / Tab |
| Touchscreen | Click the lower screen |
| Quit | Escape or close window |

If the game reports **“Circle Pad Pro disconnected” after a quest** with an
imported save, open the game's **Options → page 3 → Circle Pad Pro Buttons**.
Cycle **Type 4 → Type 1 → Type 4**, confirm, and save normally. If Circle Pad Pro
is Off, enable it as well. A supplied save contained an invalid button selector
that displayed as Type 4; merely toggling Off/On left it unchanged. The selector
repair has passed quest completion and an ordinary-save reload on the unchanged
core. This procedure applies to that reproduced save issue, not every possible
controller disconnection.

Connected controllers use Apple's GameController API. The user has confirmed a smooth hunt, touchpad cursor movement and R3 touch selection. Both native app bundles and the launcher use `~/Library/Application Support/MH4U Runtime/.local/state/Azahar`. Installation migrates workspace savedata and extdata together only if the installed profile has no hunter save, keeping an atomic backup of the previous SDMC tree. Existing installed texture packs and system files are preserved; the workspace profile remains untouched. An explicit `--state-dir` overrides the default for isolated verification. An unbundled CLI executable retains its workspace default.

## Local evidence and implementation

- `.local/game/manifest.json`: source/CXI/code identity, segment layout, checksums and extraction validation.
- `.local/game/exefs/code.bin`: decompressed game executable; `.local/game/romfs/`: extracted title assets.
- `.local/metal-capabilities.json`: actual M2 Pro device tests, including Metal 4 support. The presentation tests additionally execute Metal 4FX work and verify GPU color readback.
- `.local/core-provenance.json`: pinned upstream and dependency revisions; `.local/reports/`: finite boot logs, metrics and captures.
- `.local/vulkan/regression/report.json` and `.local/vulkan/gameplay/report.json`: GPU boot/input, saved-character loading and movement evidence with exact binary hashes; unpaced timings are not gameplay benchmarks.
- `tools/prepare_image.py`: bounded local input validation and extraction; `tools/build_core.py`: pinned source preparation with embedded-key header excluded.
- `tools/build_vulkan_core.py`: GPU core and verified MoltenVK provisioning; `src/vulkan_bridge.mm`: offscreen libretro GPU handoff.
- `src/main.mm`: the native frontend; `docs/architecture.md`, `docs/reference.md` and `docs/status.md`: reuse boundaries, validation evidence and remaining acceptance work.

Synthetic parser tests, the GPU dispatch test, and presentation/fallback tests run through `ctest --test-dir build --output-on-failure`. A boot comparison shares Azahar's services and renderer; it is not an independent real-hardware correctness test.

The host/core integration is licensed under GPL-2.0-or-later; upstream dependencies retain their licenses. No game code, extracted assets or proprietary system files belong in Git or a distributable application. This project is unaffiliated with Nintendo or Capcom.

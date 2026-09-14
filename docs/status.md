# Validation checkpoint — 2026-09-13

**Resumed explicitly by the user on 2026-09-12.** Read `RESUME.md` for persistent
context; use Sol agents. Current gameplay validation uses a private save copy.

Machine: Apple M2 Pro, arm64, macOS 26.5.2, Apple SDK 26.5.

| Area | Verified result | Local evidence |
|---|---|---|
| Repeatable combat / paced native window | Tutorial cannon hit reaches explicit guest-game confirmation in two identical headless replays and the installed native window. 750 paced frames at 59.85 submitted FPS over 12.53 seconds, 7 work overruns, 40.98 ms maximum work; bootstrap and RAM load excluded. M2 Pro, 1×, spatial MetalFX on, custom textures/audio/temporal off. This covers a short tutorial interaction, not a kill or full-hunt benchmark | `.local/combat-validation-20260913/report.json`, `.local/install-integration-validation/paced-combat-report.json`, `final-manifest.json` |
| Installed profile integration (2026-09-13) | Both app bundles default to private Application Support state. Migrated repaired workspace SDMC only into an installed profile with no hunter; workspace and all other installed assets remain hash-identical, old SDMC backed up. 17 CTests and 10 migration regressions pass. Installed arm64 app: fresh Continue, 6,600 frames, zero RAM loads, 600 Metal4/MetalFX presentations; village and same equipment inspected | `.local/install-integration-validation/report.json`, `.local/app-routing-validation/report.json` |
| Frame transfer (2026-09-13) | Removed a full CPU pixel copy and duplicate alpha pass; 17 CTests pass. 1,200-frame captures match byte-for-byte at 1× and 4×. Real 1→4→1 temporal replay processes 204 frames with zero alignment rejections. Installed frontend passes 300-frame 4× smoke; core and 20 canonical save files unchanged. No reliable FPS improvement established | `.local/frame-transfer-validation/final-comparison.json`, `final-temporal.json`, `installation.json`, `installed-report.json` |
| Completed Harvest Tour | Entered Volcanic Hollow, delivered Paw Pass, inspected QUEST COMPLETE/rewards/return; ordinary Sora save changed while other slots remained identical. Fresh processes with zero savestate loads recognize play time and Continue to Val Habar. No combat in this automated test | `.local/advanced-save-validation-20260913/completion-report.json` |
| User hunt / Circle Pad Pro | User reports a smooth completed hunt, then “circle pad pro disconnected” on village return while other buttons work. Root cause: imported CPP Buttons value FF despite the UI displaying Type 4. Cycling Type 4→Type 1→Type 4 and saving stores valid value 3. Two subsequent Harvest completions retain CPP; fresh Continue and C-stick camera rotation pass. Applied the UI-only repair to the actual user profile with verified backups and unrelated savedata/extdata unchanged; no core patch | `.local/cpp-mode-validation/report.json`, `.local/cpp-user-repair/final-report.json` |
| Supplied input | Plaintext main NCCH; exact title/code/CXI identity; all ExeFS and RomFS IVFC levels checked | `.local/game/manifest.json`, `.local/game-reverify/verification.json` |
| Native build | Cocoa host, Dynarmic AArch64 JIT and GPU-enabled core run as arm64. Current installed core SHA starts 37f9a923; older Vulkan build reports describe historical binaries | `build/`, `.local/install-integration-validation/report.json` |
| Metal | Real device dispatch/readback; Metal 4FX, legacy MetalFX and bilinear presentation tests pass | `.local/metal-capabilities.json`, CTest |
| GPU game output | 300 offscreen Vulkan frames read back and presented with 300 Metal 4FX submissions | `.local/vulkan-gui-300.json` |
| CPU comparison | Both JIT and interpreter finish 300 GPU-rendered boot frames; animated final captures differ | `.local/reports/boot-20260911T143758Z-t2lb9vl3/report.json` |
| Title progression | Title screen, main menu, two distinct opening-cinematic scenes visible | `.local/vulkan/progression/report.json` |
| Relocated savestate paths (2026-09-13) | Real archive write regression failed before the fix and passes afterward; all 16 CTests pass. New-core 7,400-frame ship replay and relocated 600-frame load preserve the source tree, with no absolute source mounts in snapshots. Corrected core installed; old app/core retained for legacy snapshots, active game not restarted | `.local/savestate-path-validation/report.json`, `installation.json` |
| Native save creation/reload | Created Native/Palico through native touch UI; clean exit; fresh process recognizes the ordinary save | `.local/native-creation/validation.json` |
| Native gameplay | Repeated saved-character loading, sandship deck rendering, dialogue dismissal, forward movement with camera tracking | `.local/vulkan/gameplay/report.json` |
| Native window and pacing | 7,400 Vulkan frames and Metal 4FX presentations in 124.172 seconds (59.595 submitted FPS); final capture shows Hunter after movement | `.local/vulkan/pacing-hunter/movement7400.json`, `movement7400.png` |
| Reference gameplay | Hunter/Palico saved; opening sandship deck and movement observed; later Qt Preferences hung on microphone authorization | `.local/reference/playable-validation.json` |
| Reference Preferences fix | Corrected build opens Preferences and Audio responsively without a microphone consent sheet; settings unchanged, clean exit | `.local/reference/preferences-validation-20260912.json` |
| Software fallback | Same GPU-enabled core renders 300 software frames without loading MoltenVK | `.local/gpu-core-software-300.json` |
| Installed app | Verified game/core/MoltenVK copies; installed executable completes GPU boot test | `.local/installed-gpu-test/`, private Application Support `installation.json` |
| DualSense and display layout | Persistent remapping menu recognizes DualSense; upper LCD fullscreen and lower toggle overlay visibly checked; Retina touch alignment and final GPU composite checks pass. User confirms Circle advances the game and touchpad click toggles the lower screen | `.local/controller-validation/report.json`, `smoke.json` |
| Touchpad cursor and R3 | Initial physical tests failed because Bluetooth simple reports omitted touch. Public IOKit feature 0x09 initialization restored 1,755 continuous GameController callbacks and correct R3; user confirms diagnostic values change. Automatic initialization installed and logged in reopened game; user confirms both cursor movement and R3 selection work in the game. All six CTests and 300-frame boot pass | `.local/touchcursor-validation/report.json`, `smoke-final.json`, `.local/gamecontroller-probe-result.txt` |
| Input | Quick-tap, held-button, analog, touch-latch and focus-loss self-tests pass; real keyboard taps advance startup prompts | `--input-self-test`, native UI checks |
| Boundaries | Synthetic corruption/path/encryption rejection tests pass; native forged-header rejection occurs before core loading; process network access denied | `tests/`, CTest, runtime metrics |
| Graphics, pause and audio menus | Installed spatial MetalFX toggle, volume/mute and pause/resume; seven CTest groups, real AudioQueue callback pause/resume and parameters, GPU probe, isolated 300-frame boot pass. This original menu checkpoint preceded the experimental temporal integration below. Manual in-game panel inspection not performed | `.local/settings-validation/report.json`, `ctest.txt`, `smoke.json` |
| Internal resolution 1×–4× | Installed live resolution selector, current MetalFX status; nine CTest groups and 300-frame Vulkan boot at each scale pass. Live 1×→4×→2×→1× changes produce matching frame dimensions; Graphics panel visually verified at 4× with Metal 4FX active. No hunt performance claim | `.local/resolution-validation/report.json`, `live.out`, `gui.out` |
| Temporal / frame interpolation groundwork | Real GPU synthetic scaler/reset/intermediate-centroid checks pass. Opt-in core patch captures aligned scene color/depth from a finite isolated sandship replay. Initial groundwork checkpoint; later frontend integration is described below, with geometric motion/projection/full HUD handling still incomplete | `.local/temporal-validation/metal-temporal.json`, `depth-run.json`, `top-depth-metadata.json`, `depth-decoded.json` |

The 7,400-frame windowed replay covers startup, loading and initial movement,
with 27 work frames over the 16.67ms budget and a 332ms maximum. It is not a
steady-state hunt benchmark or a controlled speedup comparison. Pacing includes
Cocoa work and uses persistent deadlines with bounded recovery after long stalls.
The JSON reports separate core, presentation, event and sleep time.

These are functional tests, not comprehensive gameplay compatibility coverage. Headless execution
is unpaced, concurrent development processes were sometimes running, and startup
UI does not exercise a full quest. Audio sample delivery and the native audio
queue are implemented; audible quality has not been independently assessed.
Physical DualSense Circle and overlay-toggle controls are user-confirmed; touch motion
and R3 selection are now also explicitly user-confirmed in the updated game.
The touch bounds correction is
covered by a test executing the actual core pointer branches against synthetic
two-screen coordinates (`tests/test_touch_bounds.py`).

A private Harvest Tour has completed through ticket delivery, ordinary save and
fresh-process Continue; the user separately reports a smooth completed hunt.
The reproduced post-quest CPP loss was traced to an imported save with an invalid
button-selector value that displayed as Type 4. Cycling Type 4 → Type 1 → Type 4
and saving produced the valid value 3. Two isolated Harvest completions then retained
the connection on the unchanged core, including after ordinary-save Continue;
a second-quest C-stick comparison visibly rotated the camera. Evidence is in
`.local/cpp-mode-validation/report.json`. The actual workspace play profile had the same invalid value. Its settings were
repaired through the game on a private copy, verified by two fresh boots, then
atomically applied with an exact backup. Only system/user1 changed; other characters
and extdata remain byte-identical. `.local/cpp-user-repair/final-report.json` records
the application. Old RAM savestates retain their previous settings. Remaining acceptance work includes repeatable combat coverage
and frame-pacing measurements in representative scenes.
These results do not establish compatibility with all missions or settings. The
standalone reference shares the same core and cannot establish real-hardware
accuracy. Online features are outside this offline runtime's tested scope.

MoltenVK teardown reports `MTLDevice.currentAllocatedSize`, which can include
still-live native Metal presenter textures and scaler resources. That message
alone does not establish a Vulkan resource leak. Cross-queue producer paths and
GPU-hang recovery remain unexercised; bounded CLI tests use an external watchdog.

Final interactive check before pause: native-created Native/Palico was reloaded;
walking, stairs, NPC dialogue and camera controls worked. Looking at the Remobra
flock triggered the Dah’ren Mohran encounter, whose geometry rendered visibly.
The run was closed cleanly during the rope/bilge tutorial instruction. The
encounter was not completed and its progress is not verified saved. Ordinary
savedata, hashes, final runtime metrics and last capture were retained under
`.local/checkpoints/20260911T152420Z` and `.local/native-creation/`.

## Integrated experimental temporal path

The frontend now consumes synchronized scene depth, estimates image motion on Metal,
and presents actual temporal outputs. Optical-flow frame generation is separately
labelled experimental and preserves the current image in unreliable regions. It
is not MetalFX frame interpolation. Windowed validation distinguishes generated
images from generated presentations; the measured visible work exceeded the core
frame budget, so no performance improvement is claimed. Final integration evidence
is under `.local/temporal-integration-validation/`; see RESUME.md for install status.


The subsequent 1×–4× extension preserves internal resolution when either experimental
mode is enabled. ABI 2 reads actual scaled Vulkan scene color/depth; motion uses a
native-size proxy with scaled displacements. All 13 CTest groups pass. A finite
1→2→3→4 replay produced 172 temporal frames and 167 optical frames with zero
alignment rejections; its final 4× window presented 57 optical frames. Captures are
1600×960. All visible iterations exceeded the core frame budget, so these are
correctness checks, not a speedup claim. Evidence: `.local/temporal-scales-validation/`.

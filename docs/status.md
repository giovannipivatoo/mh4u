# Validation checkpoint — 2026-09-12

**Resumed explicitly by the user on 2026-09-12.** Read `RESUME.md` for persistent
context; use Sol agents. Current gameplay validation uses a private save copy.

Machine: Apple M2 Pro, arm64, macOS 26.5.2, Apple SDK 26.5.

| Area | Verified result | Local evidence |
|---|---|---|
| Supplied input | Plaintext main NCCH; exact title/code/CXI identity; all ExeFS and RomFS IVFC levels checked | `.local/game/manifest.json`, `.local/game-reverify/verification.json` |
| Native build | Cocoa host, Dynarmic AArch64 JIT and GPU-enabled core run as arm64 | `build/`, `.local/vulkan/core-build-validation.json` |
| Metal | Real device dispatch/readback; Metal 4FX, legacy MetalFX and bilinear presentation tests pass | `.local/metal-capabilities.json`, CTest |
| GPU game output | 300 offscreen Vulkan frames read back and presented with 300 Metal 4FX submissions | `.local/vulkan-gui-300.json` |
| CPU comparison | Both JIT and interpreter finish 300 GPU-rendered boot frames; animated final captures differ | `.local/reports/boot-20260911T143758Z-t2lb9vl3/report.json` |
| Title progression | Title screen, main menu, two distinct opening-cinematic scenes visible | `.local/vulkan/progression/report.json` |
| Native save creation/reload | Created Native/Palico through native touch UI; clean exit; fresh process recognizes the ordinary save | `.local/native-creation/validation.json` |
| Native gameplay | Repeated saved-character loading, sandship deck rendering, dialogue dismissal, forward movement with camera tracking | `.local/vulkan/gameplay/report.json` |
| Native window and pacing | 7,400 Vulkan frames and Metal 4FX presentations in 124.172 seconds (59.595 submitted FPS); final capture shows Hunter after movement | `.local/vulkan/pacing-hunter/movement7400.json`, `movement7400.png` |
| Reference gameplay | Hunter/Palico saved; opening sandship deck and movement observed; later Qt Preferences hung on microphone authorization | `.local/reference/playable-validation.json` |
| Reference Preferences fix | Corrected build opens Preferences and Audio responsively without a microphone consent sheet; settings unchanged, clean exit | `.local/reference/preferences-validation-20260912.json` |
| Software fallback | Same GPU-enabled core renders 300 software frames without loading MoltenVK | `.local/gpu-core-software-300.json` |
| Installed app | Verified game/core/MoltenVK copies; installed executable completes GPU boot test | `.local/installed-gpu-test/`, private Application Support `installation.json` |
| DualSense and display layout | Persistent remapping menu recognizes DualSense; upper LCD fullscreen and lower toggle overlay visibly checked; Retina touch alignment and final GPU composite checks pass. User confirms Circle advances the game and touchpad click toggles the lower screen | `.local/controller-validation/report.json`, `smoke.json` |
| Touchpad cursor and R3 | Initial physical tests failed because Bluetooth simple reports omitted touch. Public IOKit feature 0x09 initialization restored 1,755 continuous GameController callbacks and correct R3; user confirms diagnostic values change. Automatic initialization installed and logged in reopened game; final in-game physical verification pending. All six CTests and 300-frame boot pass | `.local/touchcursor-validation/report.json`, `smoke-final.json`, `.local/gamecontroller-probe-result.txt` |
| Input | Quick-tap, held-button, analog, touch-latch and focus-loss self-tests pass; real keyboard taps advance startup prompts | `--input-self-test`, native UI checks |
| Boundaries | Synthetic corruption/path/encryption rejection tests pass; native forged-header rejection occurs before core loading; process network access denied | `tests/`, CTest, runtime metrics |

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
and R3 are confirmed in the diagnostic, with final in-game verification pending.
The touch bounds correction is
covered by a test executing the actual core pointer branches against synthetic
two-screen coordinates (`tests/test_touch_bounds.py`).

Remaining acceptance work: exercise combat and complete a quest, validate saving
and reloading gameplay progress, and measure frame pacing in representative
gameplay scenes. Ordinary character-save loading and initial movement pass;
a changed native save file alone does not prove that quest progress persisted. The
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

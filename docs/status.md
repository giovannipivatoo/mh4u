# Validation checkpoint — 2026-09-11

Machine: Apple M2 Pro, arm64, macOS 26.5.2, Apple SDK 26.5.

| Area | Verified result | Local evidence |
|---|---|---|
| Supplied input | Plaintext main NCCH; exact title/code/CXI identity; all ExeFS and RomFS IVFC levels checked | `.local/game/manifest.json`, `.local/game-reverify/verification.json` |
| Native build | Cocoa host, Dynarmic AArch64 JIT and GPU-enabled core run as arm64 | `build/`, `.local/vulkan/core-build-validation.json` |
| Metal | Real device dispatch/readback; Metal 4FX, legacy MetalFX and bilinear presentation tests pass | `.local/metal-capabilities.json`, CTest |
| GPU game output | 300 offscreen Vulkan frames read back and presented with 300 Metal 4FX submissions | `.local/vulkan-gui-300.json` |
| CPU comparison | Both JIT and interpreter finish 300 GPU-rendered boot frames; animated final captures differ | `.local/reports/boot-20260911T143758Z-t2lb9vl3/report.json` |
| Title progression | Title screen, main menu, two distinct opening-cinematic scenes visible | `.local/vulkan/progression/report.json` |
| Native gameplay | Repeated saved-character loading, sandship deck rendering, dialogue dismissal, forward movement with camera tracking | `.local/vulkan/gameplay/report.json` |
| Native window | 6,500 Vulkan frames presented through Metal 4FX; final capture shows Hunter on sandship deck | `.local/native-playtest/gui6500.json`, `gui6500.png` |
| Reference gameplay | Hunter/Palico saved; opening sandship deck and movement observed; later Qt Preferences hung on microphone authorization | `.local/reference/playable-validation.json` |
| Software fallback | Same GPU-enabled core renders 300 software frames without loading MoltenVK | `.local/gpu-core-software-300.json` |
| Installed app | Verified game/core/MoltenVK copies; installed executable completes GPU boot test | `.local/installed-gpu-test/`, private Application Support `installation.json` |
| Input | Quick-tap, held-button, analog, touch-latch and focus-loss self-tests pass; real keyboard taps advance startup prompts | `--input-self-test`, native UI checks |
| Boundaries | Synthetic corruption/path/encryption rejection tests pass; native forged-header rejection occurs before core loading; process network access denied | `tests/`, CTest, runtime metrics |

These are functional tests, not a measured gameplay benchmark. Headless execution
is unpaced, concurrent development processes were sometimes running, and startup
UI does not exercise a full quest. Audio sample delivery and the native audio
queue are implemented; audible quality has not been independently assessed.
Physical controller hardware has not been tested. The touch bounds correction is
covered by a test executing the actual core pointer branches against synthetic
two-screen coordinates (`tests/test_touch_bounds.py`).

Remaining acceptance work: exercise combat and complete a quest, validate saving
and reloading gameplay progress, and measure frame pacing in representative
gameplay scenes. Ordinary character-save loading and initial movement pass;
a changed native save file alone does not prove that quest progress persisted. The
standalone reference shares the same core and cannot establish real-hardware
accuracy. Online features are outside this offline runtime's tested scope.

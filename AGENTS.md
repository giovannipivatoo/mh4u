# MH4U Apple Silicon runtime

The user authorizes autonomous engineering and parallel agents. Coordinate ownership before edits.

- Use only the user-supplied workspace image. Never fetch ROMs, console/title keys, Nintendo firmware, or proprietary game assets. Never upload the image or extracted data.
- Keep every proprietary/generated artifact under `.local/` (ignored), apart from the original image, which stays untouched. The installed app may keep verified runtime copies and saves in its private `~/Library/Application Support/MH4U Runtime/` folder to avoid requesting broad Desktop access. Never stage proprietary files or third-party binary artifacts.
- Upstream Azahar releases can include embedded keys. Build the pinned source with `ENABLE_BUILTIN_KEYBLOB=OFF`; fetch source using the exclusion in `tools/build_core.py`. Do not fetch the excluded header or retain its Git blob.
- Do not extract system-update partitions. Preparation handles only the main game partition and fails closed on encryption or invalid bounds/hashes.
- Prefer the pinned recompiler and HLE core to new CPU/kernel emulation. Keep the native frontend small. Do not submit changes or reports upstream without explicit user authorization.
- Report actual evidence: boot frames are not gameplay, software PICA with Metal presentation is not a native PICA GPU renderer, and capability probes are not proof of rendered game behavior.
- Build with CMake. Run the synthetic input tests, device probe, and finite local game smoke test after relevant changes. Keep captures, logs, manifests, state and checkpoints local.

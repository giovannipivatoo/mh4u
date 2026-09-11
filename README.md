# MH4U Apple Silicon runtime

**Sessione in pausa su richiesta dell’utente.** Per ripartire, leggere [RESUME.md](RESUME.md); usare agenti Sol per il lavoro delegato.

A local native macOS host specialized for the supplied **Monster Hunter 4 Ultimate (Europe)** image (`0004000000126100`, `CTR-P-BFGP`). It uses Azahar's ARMv6K → AArch64 JIT and 3DS services, with a Cocoa window, Metal presentation, runtime-selected spatial MetalFX, native audio and input.

**Development status:** the image is fully extracted and hash-verified. Both CPU backends complete boot tests. GPU rendering now uses Azahar's Vulkan PICA backend through MoltenVK on the M2 Pro; the native host reads its output into Metal for presentation and spatial MetalFX. Boot/input tests reach the title screen, main menu, opening cinematic and playable sandship deck; loading a saved hunter and forward movement are verified. A software-rasterizer memory race and a GPU frame-completion handoff were corrected in the pinned core. The native frontend also created its own character/companion through touch input and reloaded the ordinary save after restarting. Combat, complete quests and saving/reloading gameplay progress remain unverified. This is a specialized native recompilation runtime, with an emulator core and dynamic ARM translation.

## Local use

All preparation/build/test commands have been run by the agent. Open `~/Applications/MH4U Runtime.app` or double-click `MH4U.command` to launch the development runtime. The installed app uses verified private copies under Application Support and requires no Desktop-folder permission. The launcher prepares missing local inputs, builds the host and denies network access to the running game. It validates the exact title/code profile and local CXI hash before execution.

```sh
python3 tools/mh4u.py setup                 # prepare supplied input and build
python3 tools/mh4u.py run                   # native window, persistent local saves
python3 tools/mh4u.py run -- --renderer software # slower diagnostic fallback
python3 tools/mh4u.py install               # update the installed native app and private inputs
python3 tools/mh4u.py verify --compare      # finite JIT/interpreter boot comparison
```

The source build uses installed CMake/Ninja, the Apple SDK and Homebrew OpenSSL. Extraction uses only the Python standard library. No account, emulator firmware, console key or game download is required. Everything in `.local/` and `build/` is private/generated and ignored by Git. The original `.3ds` stays untouched.

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

Connected controllers use Apple's GameController API. Controller gameplay and the full touch path still require verification. Normal play saves stay in `~/Library/Application Support/MH4U Runtime/.local/state/Azahar`; verification runs use isolated state directories so they do not replace play saves.

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

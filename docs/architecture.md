# Implementation boundary

## Accepted port direction — 2026-09-14

The user approved a staged move toward game code translated before launch (AOT,
with no runtime JIT in the target path) and a direct PICA-to-Metal renderer, initially
reusing Azahar's kernel and HLE services. This is the intended architecture, not
the current implementation or a claim that complete AOT coverage is feasible yet.
The user also wants to be able to replace the remaining Azahar-derived parts later.

Implement each replacement behind the smallest concrete integration boundary:

- Keep Azahar-specific types, headers and ownership inside the integration layer
  when adding the AOT path; translated game code should use explicit guest CPU,
  memory and system-call contracts rather than depend on Azahar internals.
- Preserve guest address semantics, thread scheduling, timing, synchronization and
  observable service results across that boundary. Host OS calls are not automatic
  substitutes for 3DS semantics. Specify these contracts as each integration is built.
- Separate graphics command handling from the rendering backend so Metal can be
  introduced without simultaneously replacing the kernel or every service.
- Retain kernel/SVC/IPC, SRV, FS, APT/CFG/PTM, HID/IR and DSP behavior initially.
  Investigate LDR/RO and executable modules before claiming complete AOT coverage;
  the title's service ACL alone does not establish actual use.
- Replace further subsystems incrementally, comparing behavior against the pinned
  runtime and testing ordinary save compatibility on isolated copies. Existing RAM
  savestates are not assumed portable to new execution or service implementations.

Reuse existing boundaries where they suffice. Introduce an adapter only for a
concrete replacement; a plugin framework, generic service bus or placeholder
implementations for every service are not required. Keep the working JIT/Vulkan
runtime available as a reference; any experimental JIT fallback must be reported
explicitly and cannot count as an AOT-only acceptance result. This decision does
not establish multiplayer support, a distribution target or a performance guarantee.

## Current implementation

This project specializes a native macOS host for the supplied MH4U European cartridge image. It reuses the Azahar core rather than recreating ARM11, the 3DS kernel and services. The title's ARMv6K instructions are dynamically recompiled to AArch64 by Dynarmic. Game code and assets remain runtime inputs under `.local/`; none are compiled into the host or committed.

The accelerated graphics path is Azahar's Vulkan PICA rasterizer → MoltenVK → offscreen GPU image → synchronized staging readback → native Metal texture → Cocoa presentation. The GPU core also contains the slower software rasterizer for diagnostic fallback. The bridge is intentionally synchronous: it completes the core's GPU producer before copying its image, waits for readback, and converts RGBA to BGRA. The bridge transfers its owned opaque BGRA vector to the frontend by swapping buffers; the frontend preserves it for duplicate frames and avoids a second pixel copy or alpha rewrite. Software-rendered frames still use their supplied row pitch and normalize alpha before the shared presentation path. GPU readback is a measured cost and a candidate for later optimization; this is not a direct PICA-to-Metal shader backend or zero-copy implementation.

Spatial MetalFX runs where runtime support and scaler creation succeed. On macOS 26 and supported hardware, scaling uses real Metal 4 command buffers, residency tracking and completion feedback; the completed texture is then presented through a standard Metal render pass. A synthetic presentation test reads GPU output back to check color/channel correctness and resizing; the device probe separately checks Metal 4 queues/compiler and GPU execution. The experimental temporal path adds synchronized depth through a private callback and estimates motion on Metal; standard libretro color-only presentation remains the fallback. MetalFX frame interpolation still lacks verified game camera/projection inputs.

The host paces frames against a persistent deadline that includes Cocoa event
handling. A full-frame stall discards accumulated backlog; shorter sleep drift
can be recovered without unlimited catch-up. Timing metrics separate core work,
presentation, event handling and sleeping.

The frontend exposes the pinned core's internal resolution factor from 1× to 4×.
The Vulkan bridge accepts only the stacked 400×480 canvas at those integer scales,
using a bounded 12.3 MB staging allocation. Live updates use libretro's option-change
notification, followed by the core's settings/layout update at the next run call.
Metal crops and scales both LCDs proportionally; touch remains normalized to the
same virtual two-screen canvas. Higher resolution increases both rasterization
and synchronous readback work. It does not add texture-pack detail or temporal data.

The core also supplies process memory, scheduling, SVCs, IPC services, RomFS access, input and audio emulation. System services use HLE/open-source replacements; there is no firmware-download step. Network-facing build features and embedded keys are disabled. Only the main title partition is prepared; the cartridge's update partitions are unused.

The reference is a pinned local Azahar source build (2126.1, commit `26e608f6fa292b27cda0ae8c84e148d17600a5e6`), available as both libretro cores and an installed standalone Qt application. JIT/interpreter comparisons test CPU-path differences, but share the same HLE and PICA implementations and cannot establish independent hardware accuracy. The Qt frontend provides a separate presentation/input comparison, not independent emulation. Captures and performance measurements must be labeled by the exact frame range, state, and renderer used.

## Acceptance progression

1. Validate the supplied image, hashes, memory layout and extracted filesystem.
2. Build native arm64 host/core; pass a real device dispatch and finite game-load test.
3. Confirm visible title/menu frames, audio delivery and working input in the native window.
4. Exercise character creation, village, quest loading/combat, save/reload and representative rendering. Record regressions and speed on this machine.
5. Optimize measured bottlenecks. A native PICA Metal backend requires independent coverage of rasterization, texture formats, TEV combiners, depth/stencil/blending, transfers and shader semantics; it is substantial remaining work, not implied by the presentation layer.

See README and local validation reports for which stages have actually passed.

## Temporal rendering work in progress

`tools/temporal_probe.mm` executes the MetalFX temporal scaler and frame
interpolator, reads their outputs, and verifies object position and reset behavior.
The interpolator uses consecutive temporal outputs with coherent planar depth and
current-to-previous motion. Initial outputs can repeat an endpoint; steady checks
require a true midpoint, so successful encoding alone cannot pass the test.

The opt-in `azahar-temporal-depth-probe.patch` traces color/depth associations
through draws and display transfers, including a source subrectangle inside a
larger render target. It can flush and capture one color/depth pair before that
depth target is reused. The private frame ABI now transports those bounded snapshots, keyed to the
actually selected top display buffer. Color/depth alignment is checked again by
the frontend. Native geometric motion, camera projection and complete HUD handling
remain necessary for a higher-quality temporal/MetalFX frame-interpolation path.

The integrated frontend uses a private libretro environment callback for bounded
400s×240s scene color/depth snapshots (s = 1–4) tied to the selected display buffer.
ABI 2 includes the scale and reads actual scaled Vulkan color/depth surfaces before
display transfer reuse. Motion is estimated on a 400×240 box-filtered proxy and
expanded with pixel displacements multiplied by s; color and depth retain their
full resolution. Temporal output is max(800, 400s)×max(480, 240s). It rejects
unsupported depth conventions and mismatched composites; optical motion supplies
a validity mask, and the MetalFX output is composited with current native color in
invalid regions. History resets on pause/settings, frame gaps, or photometric cuts.
Generated optical frames are displayed before current frames with a half core-period
delay. This synchronous implementation adds work and can lower the base frame rate;
there is no validated speedup claim. MetalFX resources are explicitly destroyed
before core/frontend teardown to avoid late MPS framework destruction.

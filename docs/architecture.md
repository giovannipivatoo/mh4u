# Implementation boundary

This project specializes a native macOS host for the supplied MH4U European cartridge image. It reuses the Azahar core rather than recreating ARM11, the 3DS kernel and services. The title's ARMv6K instructions are dynamically recompiled to AArch64 by Dynarmic. Game code and assets remain runtime inputs under `.local/`; none are compiled into the host or committed.

The accelerated graphics path is Azahar's Vulkan PICA rasterizer → MoltenVK → offscreen GPU image → synchronized staging readback → native Metal texture → Cocoa presentation. The GPU core also contains the slower software rasterizer for diagnostic fallback. The bridge is intentionally synchronous: it completes the core's GPU producer before copying its image, waits for readback, and converts RGBA to BGRA. GPU readback is a measured cost and a candidate for later optimization; this is not a direct PICA-to-Metal shader backend or zero-copy implementation.

Spatial MetalFX runs where runtime support and scaler creation succeed. On macOS 26 and supported hardware, scaling uses real Metal 4 command buffers, residency tracking and completion feedback; the completed texture is then presented through a standard Metal render pass. A synthetic presentation test reads GPU output back to check color/channel correctness and resizing; the device probe separately checks Metal 4 queues/compiler and GPU execution. Temporal MetalFX/frame interpolation requires motion/depth inputs that the current framebuffer interface does not supply.

The core also supplies process memory, scheduling, SVCs, IPC services, RomFS access, input and audio emulation. System services use HLE/open-source replacements; there is no firmware-download step. Network-facing build features and embedded keys are disabled. Only the main title partition is prepared; the cartridge's update partitions are unused.

The reference is a pinned local Azahar source build (2126.1, commit `26e608f6fa292b27cda0ae8c84e148d17600a5e6`), available as both libretro cores and an installed standalone Qt application. JIT/interpreter comparisons test CPU-path differences, but share the same HLE and PICA implementations and cannot establish independent hardware accuracy. The Qt frontend provides a separate presentation/input comparison, not independent emulation. Captures and performance measurements must be labeled by the exact frame range, state, and renderer used.

## Acceptance progression

1. Validate the supplied image, hashes, memory layout and extracted filesystem.
2. Build native arm64 host/core; pass a real device dispatch and finite game-load test.
3. Confirm visible title/menu frames, audio delivery and working input in the native window.
4. Exercise character creation, village, quest loading/combat, save/reload and representative rendering. Record regressions and speed on this machine.
5. Optimize measured bottlenecks. A native PICA Metal backend requires independent coverage of rasterization, texture formats, TEV combiners, depth/stencil/blending, transfers and shader semantics; it is substantial remaining work, not implied by the presentation layer.

See README and local validation reports for which stages have actually passed.

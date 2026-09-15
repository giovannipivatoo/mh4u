# PICA Metal vertical slice

This module rasterizes real post-vertex-shader PICA batches with Metal. The
Azahar adapter consumes the same `Pica::OutputVertex` objects queued through
`RasterizerInterface::AddTriangle` and decodes the live `RegsInternal` state.
Azahar headers stop at `azahar_adapter.cpp`; the Metal API uses plain owned or
borrowed C++ data.

The conversion matches the pinned accelerated renderer:

- PICA float24 vertex outputs are expanded to float32 by the adapter.
- Clip position becomes `(x, -y, -z, w)`. The unconditional Y inversion
  compensates for Metal's positive viewport mapping NDC +1 to its top row, so
  target row Y matches PICA screen Y `(ndc_y + 1) * half_height + corner_y`.
  The adapter passes the PICA viewport corner and include-scissor coordinates
  directly in that target coordinate system.
- The fragment shader reconstructs PICA `z/w` as `-[[position]].z`, applies the
  float24-expanded depth range and offset, clamps to `[0,1]`, and truncates to
  D16 or D24 before the Metal depth test. Clear depth uses the same truncation.
- Six TEV stages preserve the accelerated generator's per-stage 8-bit rounding,
  delayed combiner-buffer visibility, stage-zero `Previous` substitution, and
  color/alpha multipliers. Filtered texture samples remain floating point until
  the combiner output is rounded, as in the pinned shader generator. The
  diagnostic software rasterizer intentionally truncates some arithmetic
  instead; the golden records the known 157 vs 156 result for `200 * 200 / 255`
  rather than treating either path as hardware proof.

The first slice supports triangle lists, RGBA8 color, all fourteen tiled PICA
texture0 formats decoded by the pinned core (including ETC1/ETC1A4), 2D sampling,
the observed procedural texture3 profile (perspective-correct `tc2`, clamp to
edge, U color map, linear level-0 LUT width 128), TEV, alpha test, culling,
include scissor, Z buffering, D16/D24/D24S8 depth and stencil tests/writes and
the PICA fixed-function blend equations and factors. Procedural LUT values and
signed differences are copied from the live PICA core and remain floating point
until the TEV stage rounds its result. It fails closed on exclude scissor,
partial color masks, non-copy logic operations, W buffering, lighting, fog,
other procedural modes, mipmaps, TEV reads from texture units 1/2, shadow/gas
modes, and custom clipping planes. Inert texture1/2 enable bits are ignored.

`Frame` keeps color and depth across ordered `DrawTriangles` batches. The lower
level `Target` API also keeps an owned Metal color/depth-stencil target across
separate submissions: creation takes an explicit color clear or RGBA8 import and
an explicit depth/stencil clear or row-major CPU snapshot. `draw` uses
`LoadActionLoad`; color and depth/stencil readback are explicit. Snapshot depth
values represent PICA-quantized `n / ((1 << bits) - 1)` values. Metal plane
transfers use separate `MTLBlitOptionDepthFromDepthStencil` and
`MTLBlitOptionStencilFromDepthStencil` copies.
Submission failure poisons the target; callers must discard it instead of using
possibly partial color/depth contents.

`CoreRasterizer` is the first experimental Azahar integration seam. It receives
the CPU PICA vertex stage's `AddTriangle` output, keys one persistent target by
guest color/depth address, format and dimensions, and marks the union of its guest
pages rasterizer-cached. Color readback is encoded into the tiled guest RGBA8
surface before the existing software framebuffer presenter or CPU transfer reads
it. D16, D24 and D24S8 guest surfaces are decoded into the initial Metal target;
dirty Metal depth/stencil planes are quantized to the nearest PICA integer and
encoded back into the tiled guest surface. CPU invalidation flushes all dirty
planes before discarding the target, including when the write overlaps only one
of its intervals.

This core seam deliberately supports one non-aliased RGBA8 target, the three PICA
depth formats, and texture0 with separate 4 MiB encoded and decoded bounds. Fatal
state is sticky. The candidate integration logs `metal_draws`, Metal
`submissions`, and its stop reason, then terminates the libretro run instead of
falling back to software rasterization.

The current fresh-state real-game smoke completed its finite 300-frame run with
8,167 Metal draw submissions. It decoded a coherent 512x256 ETC1A4 texture
(128 KiB encoded, 512 KiB RGBA), consumed the live procedural texture3 profile,
and stopped normally. The headless presenter reported 300 video frames, 245 with
nonzero RGB, and zero presentations. Its captured final frame has readable boot
text with the same orientation and placement as the Vulkan reference. This
proves sustained live CPU-vertex-to-Metal rendering through the boot sequence;
boot frames are not gameplay. A usable core renderer still needs more target
formats and aliases, coherent multi-target lifetime, the real transfer/fill
paths, more procedural texture modes and lighting. Vertex shader execution
remains in the PICA core until a separate PICA shader-ISA translation path is
implemented.

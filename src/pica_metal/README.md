# PICA Metal vertical slice

This module rasterizes real post-vertex-shader PICA batches with Metal. The
Azahar adapter consumes the same `Pica::OutputVertex` objects queued through
`RasterizerInterface::AddTriangle` and decodes the live `RegsInternal` state.
Azahar headers stop at `azahar_adapter.cpp`; the Metal API uses plain owned or
borrowed C++ data.

The conversion matches the pinned accelerated renderer:

- PICA float24 vertex outputs are expanded to float32 by the adapter.
- Clip position becomes `(x, flip ? -y : y, -z, w)`, matching Azahar's trivial
  vertex shader. The adapter derives the viewport from the PICA half-size and
  corner registers; Metal receives its top-left target coordinates.
- The fragment shader reconstructs PICA `z/w` as `-[[position]].z`, applies the
  float24-expanded depth range and offset, clamps to `[0,1]`, and truncates to
  D16 or D24 before the Metal depth test. Clear depth uses the same truncation.
- Six TEV stages preserve the accelerated generator's per-stage 8-bit rounding,
  delayed combiner-buffer visibility, stage-zero `Previous` substitution, and
  color/alpha multipliers. The diagnostic software rasterizer intentionally
  truncates some arithmetic instead; the golden records the known 157 vs 156
  result for `200 * 200 / 255` rather than treating either path as hardware proof.

The first slice supports triangle lists, RGBA8 color and texture0, 2D sampling,
TEV, alpha test, culling, include scissor, Z buffering, D16/D24/D24S8 depth and
stencil tests/writes and the PICA fixed-function blend equations and factors. It
fails closed on exclude scissor, partial color masks, non-copy logic operations,
W buffering, lighting, fog, procedural textures, mipmaps, other texture units and
formats, shadow/gas modes, and custom clipping planes.

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
depth formats, and bounded tiled RGBA8 texture0. Fatal state is sticky. The
candidate integration logs `metal_draws`, Metal `submissions`, and its stop
reason, then terminates the libretro run instead of falling back to software
rasterization.

The current real-game smoke reached 54 Metal draw submissions before rejecting a
non-RGBA8 texture and stopped before presenting a frame. This proves the live
CPU-vertex-to-Metal seam and depth/stencil target lifecycle, not gameplay. A
usable core renderer still needs more target formats and aliases, coherent
multi-target lifetime, the real transfer/fill paths, more texture formats and
procedural texturing. Vertex shader execution remains in the PICA core until a
separate PICA shader-ISA translation path is implemented.

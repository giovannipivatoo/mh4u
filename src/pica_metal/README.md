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
separate submissions: creation takes an explicit color clear or RGBA8 import plus
an explicit depth/stencil clear, `draw` uses `LoadActionLoad`, and `readback` is
explicit. Depth/stencil snapshot import is not implemented yet.
Submission failure poisons the target; callers must discard it instead of using
possibly partial color/depth contents.

This is not yet a core renderer or a game-rendering result. The next integration
step is a small `RasterizerInterface` adapter mapping guest color/depth physical
addresses, formats and dimensions to these targets, with explicit memory
flush/invalidate and display-transfer handling. Vertex shader execution remains
in the PICA core until a separate PICA shader-ISA translation path is implemented.

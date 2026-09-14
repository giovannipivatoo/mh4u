# Experimental AOT and direct Metal port

The accepted direction is game code compiled before launch, a direct PICA Metal
renderer and initially reused Azahar HLE services. The integration boundaries must
allow those services to be replaced later. See [architecture.md](architecture.md).

The new modules are experimental. Enabling their build options builds separate
tools and tests; it does not switch `mh4u-runtime` or the installed app to AOT or
direct Metal. Separate opt-in core patches exercise the adapters in the real
runtime. The ordinary runtime still uses Dynarmic JIT and Vulkan/MoltenVK.

## Build and check

Use the already prepared, pinned source export and local core archives with the
built-in key blob disabled. Build experimental artifacts under `.local/`:

```sh
cmake -S . -B .local/aot-metal-candidate -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DMH4U_ENABLE_AOT=ON -DMH4U_ENABLE_PICA_METAL=ON
cmake --build .local/aot-metal-candidate -j 6
ctest --test-dir .local/aot-metal-candidate --output-on-failure
```

GPU tests require access to the Metal device. A sandbox hiding the device cannot
establish renderer correctness. Test captures, translated title code, objects,
manifests and executables remain local; none belongs in a commit.

The separate core adapter can be built from the prepared local source:

```sh
python3 tools/aot/build_core_adapter.py \
  --generator .local/aot-metal-candidate/mh4u-aot-generator
python3 tools/aot/core_smoke.py \
  --host .local/aot-metal-candidate/mh4u-runtime \
  --core .local/aot-core-build/bin/Release/azahar_libretro.dylib \
  --game .local/game/main.cxi \
  --state-dir .local/aot-checkpoint-validation/state --frames 300 --timeout 20
```

Use a fresh state directory on every run. This smoke specifically checks the
current expected missing-block stop, not successful frame production. The core
verifies the translated instruction words before executing and reaches the real
HLE SVC. The current 512-block artifact includes the observed FPSCR mode change;
it executes another 43 blocks after that SVC, then stops at missing PC
`0x001067ec` without a frame or timeout. Its AOT build
forces the CPU adapter; the ordinary host's `cpu: jit` option label is not evidence
of the CPU actually selected inside that experimental core. The smoke records
that distinction and requires AOT identity/exit telemetry.

## Execution boundaries

- **AOT:** the build-time generator uses the pinned Dynarmic ARM/Thumb translator
  and emits C++ compiled into a separate executable. The generated runner does not
  link Dynarmic. Guest registers and memory/SVC/timing callbacks use project-owned
  types; Azahar-specific decoding and instruction timing stay in the generator
  and reference tool. Unsupported IR is rejected rather than interpreted silently.
  Memory/callback faults are fatal for this slice: completed register and memory
  effects may remain, while the fault PC and elapsed ticks are not yet precise at
  an instruction boundary. A caller must stop, not retry or resume that state.
- **Metal:** the adapter copies PICA register state and post-vertex-shader output
  into project-owned draw data. The backend uses Metal rasterization, texture
  sampling and TEV fragment operations. This does not yet translate the PICA vertex
  shader ISA into Metal. Accelerated Azahar shader behavior is the TEV reference;
  differences from its diagnostic software renderer are not hardware validation.
- **HLE:** a game CPU adapter must expose the same guest state through
  `ARM_Interface`, because SVC reads and writes the active core's registers.
  Context switches, CP15, exclusive operations, page tables, invalidation and
  scheduling remain necessary parts of that integration.

## Acceptance and remaining integration

ARM/Thumb fixture comparisons check registers, preserved extension state, memory,
ticks and SVC behavior in separate JIT and AOT processes. Preserving extension
registers does not prove VFP instruction support. The title differential currently
executes 62 compiled blocks to the first SVC at PC `0x107328`, consuming 477,324
Azahar ticks. Registers, memory changes and ticks match a separate JIT process.
That test supplies a synthetic memory mapping and SVC callback; it does not prove
kernel boot, gameplay or complete code coverage. Static graph discovery stops at
the first discovered SVC by default. The core build enables bounded continuation
and accepts explicit additional PC/CPSR/FPSCR entry descriptors. Its manifest
records 512 blocks, a remaining frontier of 62 entries and 113 unresolved indirect
points; coverage remains incomplete. The initial entry uses FPSCR mode
`0x03c00000`; the observed continuation at `0x0010b6f0` uses `0x03000000`.
Additional differential tests cover exclusive accesses, FPSCR state changes,
signed byte extension, BIC, 64-bit memory accesses and rotate through carry.

Metal fixtures exercise multiple draws sharing a target, texture/TEV behavior,
quantized depth comparisons and rejection of unsupported states. Rendering a
fixture through the PICA adapter does not establish rendered game behavior.

The isolated game-batch replay now accepts the first eight captured batches,
including bounded texture data read after a synchronous GPU cache flush. These
draws are black or nearly black and use explicit synthetic initial clears; this
is not an image-equivalence test. A later eight-batch window encounters ETC1A4 and
procedural-texture states that remain unsupported. Persistent render targets and
an original initial state are needed before comparing a complete draw sequence.

The Metal API exposes persistent targets: create with an explicit clear or
imported color/depth/stencil, submit draws preserving those attachments, then
read them back. Separate Metal blits transfer depth and stencil. Per-pixel GPU
tests cover D16/D24S8 snapshots, stencil comparison/increment and depth writes.
The core preserves quantized guest depth using nearest-integer conversion on
export rather than truncating a second time.

The experimental core adapter now maps a guest color/depth pair to a persistent
target, tracks cached guest pages and writes attachments back in PICA tiled format.
It reuses the software RAM presentation path, with CPU PICA vertex processing;
there is no Vulkan rasterization fallback when Metal is selected. A fresh-state
live run now submits 54 real game draws to Metal and produces 52 black video
frames before rejecting a non-RGBA8 texture. This proves live GPU submission,
not a correct visible game screen or gameplay.

A candidate crash was isolated to inconsistent `RendererSoftware` layout across
translation units. A conditional member moved `ScreenInfo` in one compilation
unit while the libretro window read the old offset. The layout is now invariant.
The corrected candidate with Metal disabled completes 300 frames. Metal enabled
now stops explicitly on unsupported graphics state, without the previous crash.

The next integration gates are:

1. Extend linked-block and instruction coverage using observed entry descriptors,
   retaining identities, tick/dispatch limits and explicit missing blocks.
2. Validate the AOT kernel adapter across longer bounded runs, context switches
   and memory operations. Unsupported code must stop an AOT-only run;
   a hybrid fallback, if introduced, must be named and counted separately.
3. Add the graphics states encountered by the live core, including additional
   texture formats, and compare complete frames against the reference.
4. Combine AOT and Metal once each backend advances independently, then validate
   finite game runs, ordinary saves and representative gameplay. Keep the working
   runtime as a reference and
   do not assume RAM savestates are portable across backend changes.

There is no measured performance improvement or complete AOT/Metal game support
claim at this stage.

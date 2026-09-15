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
HLE SVC. The current 1,024-block artifact includes observed ARM/Thumb entries
and the FPSCR mode change. After eight offline compile/run iterations it executes
five AOT batches, then stops at missing PC `0x00104618` without a frame or timeout.
Its AOT build
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
records 1,024 blocks, a remaining frontier of 134 entries and 225 unresolved indirect
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
procedural-texture states that remain unsupported by the replay. Persistent render targets and
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
live run now completes 300 video frames with 8,167 Metal draw submissions and
245 nonblack frames. The captured “Formatting complete.” screen is readable and
has the same orientation and layout as a fresh Vulkan reference run. The RGB
comparison still differs (mean absolute error 0.837 on a 0–255 scale, maximum 50);
this is a visible boot-screen check, not image equivalence or gameplay validation.

The core decodes the encountered ETC1A4 texture and implements the observed
procedural Texture3 profile: coordinate2, edge clamp, U mapping, linear filtering,
width128/offset0, no noise, separate alpha or shifts. LUT values and signed
differences are copied from PICA state into owned snapshots; interpolation remains
floating point through the TEV operation. Other procedural configurations fail
explicitly. Texture1/2 enable bits can be inert; actual TEV reads from those units
remain unsupported.

A mirrored first capture exposed a mismatch between Metal NDC Y and the target's
PICA screen coordinates. The adapter now consistently maps to the normalized
target, including viewport/scissor and culling. Asymmetric GPU/adapter fixtures
cover the correction. Guest tiled import/export and the shared presenter were
already correct and retain their behavior.

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
3. Add the graphics states encountered by the live core, beyond the observed
   procedural Texture3 profile, and compare complete frames against the reference.
4. Combine AOT and Metal once each backend advances independently, then validate
   finite game runs, ordinary saves and representative gameplay. Keep the working
   runtime as a reference and
   do not assume RAM savestates are portable across backend changes.

There is no measured performance improvement or complete AOT/Metal game support
claim at this stage.

The reproducible default-helper AOT checkpoint: eight offline compile/run iterations,
1,024-block graph cap and 65,536-fetch cap. Added UQSUB8 and low-word multiply,
both checked against Dynarmic with differential edge matrices; the negative
fixture still rejects a genuinely unsupported instruction without partial output.
The final fresh-state run verifies instruction identity, executes five AOT batches
and stops at missing descriptor PC `0x00104618`, CPSR `0x20000010`, FPSCR
`0x03000000`, after 318,332 block callbacks. No timeout and no video frames;
18 AOT tests pass. This is continued startup coverage, not a completed AOT boot.

Texture decoding now accepts all 14 pinned PICA formats through a shared core/test
boundary with exact input spans and separate 4 MiB encoded/decoded limits. Linear
samples remain floating point until TEV stage quantization, verified with a golden
case that distinguishes premature rounding. Three PICA tests pass on the GPU.
The trace replay still rejects non-RGBA8 input and lacks procedural LUT snapshots; new-format evidence comes from
the decoder tests and live core, not replayed traces.

## Bounded offline coverage discovery

`tools/aot/expand_core_graph.py` performs at most eight compile/run iterations:

```sh
python3 tools/aot/expand_core_graph.py \
  --output-dir .local/aot-offline-check --iterations 8 --total-timeout 1200
```

Every launch uses a fresh local profile. The tool accepts only an identity-verified,
well-formed missing-block result from the expected normal error exit. It normalizes
PC/CPSR/FPSCR descriptors and stops on duplicates, timeouts, invalid reports or
unsupported IR. The graph/fetch caps remain 1,024/65,536. No compiler runs inside
the game process and no fallback executes missing code.

The local manifest records commands, input and core hashes, compiled descriptors
and the last pending descriptor separately. A descriptor observed in the final
iteration is not yet included in the compiled artifact. Logs and generated source
stay under `.local/`.

The first automated batch completed eight valid iterations in 785 seconds. Seven
new descriptors are compiled into iteration08; the final observed ARM descriptor
`0x00104614` (CPSR `0x20000010`, FPSCR `0x03000000`) is pending. The final core
verifies identity and stops after 318,331 callbacks, without video or timeout.
Its 1,024-block artifact has 17 entry descriptors, 107 frontier entries and 242
unresolved indirect points. A bounded static graph can change coverage as entry
priorities change; descriptor count alone does not prove monotonic runtime progress.
The complete candidate CMake suite passes 41/41 tests, including input and device
checks. Detailed batch manifests remain local.

## Combined-core integration contract

The combined candidate enables both experimental adapters in a fresh local
source export, with the built-in key blob, Vulkan and OpenGL disabled. The AOT
factory selects `ARM_Aot` for every guest CPU. Metal uses the RAM presenter
selected by `--renderer software`, but requires `MH4U_PICA_METAL_CORE=1` to select
the actual `CoreRasterizer`; a build flag alone does not prove that selection.
The combined smoke verifies both backend selections from runtime evidence.

Both patches modify the core error loop and libretro shutdown path. Their merged
form must preserve a single sticky fatal status, then shut down and return instead
of waiting indefinitely for a frame. AOT memory accesses already go through the
pinned MemorySystem cache hooks, including exclusive writes; they must retain that
path so Metal guest-memory coherence also applies.

A combined build and fresh-state missing-block smoke can check linking, backend
selection and bounded shutdown now. Since AOT still stops before video, such a
result cannot demonstrate CPU/GPU cooperation on rendered game frames.

Build the verified combined checkpoint using the local iteration08 artifact:

```sh
python3 tools/aot/build_combined_core.py --jobs 8
python3 tools/aot/core_smoke.py --require-aot-metal \
  --host build/mh4u-runtime \
  --core .local/aot-metal-combined-core-build/bin/Release/azahar_libretro.dylib \
  --game .local/game/main.cxi \
  --state-dir .local/aot-metal-check/state --frames 300 --timeout 20
```

The helper requires fresh source/build paths and pins the verified artifact and
manifest hashes. The actual combined build and fresh smoke pass: both backend
banners and instruction identity are verified, the core returns exactly 1 on
missing PC `0x00104614`, and no timeout or video frames occur. Core SHA-256 is
`277964a6e2fef6b984fc5b7d1f41d439210ee07dee7ffdeb413a9b795e609ad9`;
build provenance and smoke agree. This establishes the combined path, not a
completed AOT boot or a game frame rendered with AOT execution.

Further Metal input validation reached 427 frames in a sampled finite run; the
450/1,500-frame attempts timed out. Sampling at that point attributed about 61%
of main-thread samples to repeated texture decoding and 17% to draw-completion
waits. These are sampled costs in that run, not whole-game performance measurements.
The next optimization is bounded texture reuse with exact guest-byte validation.

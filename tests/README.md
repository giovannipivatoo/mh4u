# Local runtime checks

CTest runs synthetic input/extraction/patch tests, an actual GPU device check,
and Metal 4FX, legacy MetalFX and bilinear presentation checks. No ROM is needed
for the synthetic tests; the device/presentation checks require Apple Silicon.

`boot-input.json` advances initial save-formatting prompts. `sandship-input.json`
loads the first existing character, dismisses the opening sandship dialogue and
moves forward. Both contain only controller events with zero-based guest frame
numbers; they contain no game code or savedata.

The sandship replay requires an isolated copy of a newly created character save,
with the opening tutorial still pending. Use `--state-dir` to keep it separate
from normal saves. A typical finite native-window run is:

```sh
build/mh4u-runtime --state-dir .local/test-state \
  --input-script tests/sandship-input.json --frames 7400 \
  --capture .local/test-state/final.ppm
```

The scripts are functional checks for this supplied revision and starting state,
not deterministic replays or general gameplay bots. Inspect captures to establish
which scene actually ran; a frame count or nonblack result alone is insufficient.

The native input self-test also covers remapping validation, host-toggle edge and
focus release gating, overlay touch coordinates, hidden-screen touch rejection,
and the upper LCD aspect ratio. The presentation checks read back both cropped
LCD textures and pixels of the final drawable, exercising the lower overlay,
hidden overlay, resizing, and all three presentation paths. Captures from
`--capture` retain the original dual-screen core canvas, not the window layout.

Touchpad cursor checks cover normalized coordinate orientation and bounds, finger
lift retention, R3 press/release latching, mouse coexistence, and hidden/focus/
disconnect cancellation. The final drawable readback checks the cursor's white
center and black outline in each Metal presentation mode. Synthetic checks do
not substitute for physical touchpad movement and R3 confirmation by the user.

On Bluetooth, the tested DualSense initially sent simple reports with no touch
data. The runtime uses a public IOKit feature 0x09 read to enable enhanced reports
at connection, then reads touch through GameController. Physical validation covers
one Sony 054c:0ce6 controller; multiple-controller selection is not validated.

`relocated-savestate-paths` serializes a real core SaveDataArchive in one process
and restores it in a second process with a different user directory. It opens
and writes a new file through the restored backend and requires that only the
destination receives the exact bytes. This failed against the old core's raw
absolute mount strings; it passes with the relative-path patch. The probe links
the local GPU core archives, so rebuild that core after applying source patches.
All fixtures are synthetic and temporary under `.local/`.

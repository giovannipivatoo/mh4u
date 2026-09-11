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

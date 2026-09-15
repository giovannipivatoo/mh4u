#!/usr/bin/env python3
import argparse
import json
import pathlib
import subprocess


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest")
    parser.add_argument("--generator")
    parser.add_argument("--fixture")
    parser.add_argument("--input-sha256")
    parser.add_argument("--artifact-root")
    args = parser.parse_args()
    if args.manifest:
        data = json.loads(pathlib.Path(args.manifest).read_text())
        mandatory = data["entry_descriptors"]
        emitted = data["emitted_descriptors"]
        assert data["mandatory_entry_descriptor_count"] == 2
        assert data["mandatory_entries_emitted"] is True
        assert data["emitted_descriptor_count"] == 2
        assert emitted[:len(mandatory)] == mandatory
        assert any(item["pc"] == "0x1008" for item in data["frontier"])
        return 0
    root = pathlib.Path(args.artifact_root)
    output = root / "mandatory-overflow-must-not-exist.cpp"
    manifest = root / "mandatory-overflow-must-not-exist.json"
    output.unlink(missing_ok=True)
    manifest.unlink(missing_ok=True)
    result = subprocess.run([
        args.generator, "--fixture", args.fixture, "--max-blocks", "1",
        "--entry-descriptor", "0x1010,0x10,0",
        "--input-sha256", args.input_sha256, "--artifact-root", args.artifact_root,
        "--output", str(output), "--manifest", str(manifest),
    ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert result.returncode != 0
    assert "mandatory entry descriptor count 2 exceeds --max-blocks 1" in result.stderr
    assert not output.exists() and not manifest.exists()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Run the experimental AOT core with a fresh local profile and a wall-clock bound."""

import argparse
import hashlib
import json
import math
import os
import pathlib
import re
import subprocess
import sys


HOT_MARKER = "AOT hot descriptors:"
CORE_BANNER_MARKER = "Experimental ARM_Aot active:"
HOT_LINE = re.compile(
    r".*AOT hot descriptors: input_sha256=([0-9a-fA-F]{64}|missing) core=(\d+) "
    r"count=(\d+) overflow=([01]) entries=((?:[0-9a-fA-F]{8},[0-9a-fA-F]{8},"
    r"[0-9a-fA-F]{8})(?:;[0-9a-fA-F]{8},[0-9a-fA-F]{8},[0-9a-fA-F]{8})*)?")
CORE_BANNER_LINE = re.compile(r".*Experimental ARM_Aot active: ([1-9]\d*) guest cores")


def parse_hot_telemetry(stderr: str, core_sha256: str) -> tuple[list[dict], bool, list[int]]:
    banner_lines = [line for line in stderr.splitlines() if CORE_BANNER_MARKER in line]
    banner_matches = [CORE_BANNER_LINE.fullmatch(line) for line in banner_lines]
    parse_error = (len(banner_matches) != 1 or any(match is None for match in banner_matches))
    expected_core_ids = (list(range(int(banner_matches[0].group(1))))
                         if len(banner_matches) == 1 and banner_matches[0] else [])

    hot_sets = []
    for line in (line for line in stderr.splitlines() if HOT_MARKER in line):
        match = HOT_LINE.fullmatch(line)
        if match is None:
            parse_error = True
            continue
        input_sha, core_id, count, overflow, entries_text = match.groups()
        entries = []
        if entries_text:
            for entry in entries_text.split(";"):
                pc, cpsr, fpscr = entry.split(",")
                entries.append({"pc": f"0x{pc}", "cpsr_mode": f"0x{cpsr}",
                                "fpscr_mode": f"0x{fpscr}"})
        hot_sets.append({
            "input_sha256": input_sha.lower(),
            "core_sha256": core_sha256,
            "core_id": int(core_id),
            "count": int(count),
            "overflow": overflow == "1",
            "entries": entries,
        })
    actual_core_ids = [item["core_id"] for item in hot_sets]
    if sorted(actual_core_ids) != expected_core_ids or len(set(actual_core_ids)) != len(hot_sets):
        parse_error = True
    return hot_sets, parse_error, expected_core_ids


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--core", required=True)
    parser.add_argument("--game", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--frames", type=int, default=300)
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--require-aot-metal", action="store_true")
    args = parser.parse_args()
    if args.frames <= 0 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--frames must be positive and --timeout must be positive and finite")
    root = pathlib.Path(__file__).resolve().parents[2]
    local = (root / ".local").resolve()
    state = pathlib.Path(args.state_dir).resolve()
    if local not in state.parents:
        parser.error("--state-dir must be below the workspace .local directory")
    if state.exists():
        parser.error("--state-dir must be fresh")
    state.mkdir(parents=True)
    command = [args.host, "--core", args.core, "--game", args.game, "--headless",
               "--renderer", "software", "--frames", str(args.frames),
               "--state-dir", str(state), "--no-audio"]
    environment = os.environ.copy()
    if args.require_aot_metal:
        environment["MH4U_PICA_METAL_CORE"] = "1"
    core_path = pathlib.Path(args.core).resolve()
    if not core_path.is_file():
        parser.error("--core must be an existing file")
    core_sha256 = hashlib.sha256(core_path.read_bytes()).hexdigest()
    timed_out = False
    try:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=args.timeout, env=environment)
        returncode = result.returncode
        stdout = result.stdout
        stderr = result.stderr
    except subprocess.TimeoutExpired as error:
        timed_out = True
        returncode = None
        stdout = error.stdout or ""
        stderr = error.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode(errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors="replace")
    metrics = {}
    for line in reversed(stdout.splitlines()):
        try:
            candidate = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(candidate, dict):
            metrics = candidate
            break
    failure = re.search(
        r"AOT execution stopped \(exit=(\d+), pc=([0-9a-fA-F]+), detail=([0-9a-fA-F]+)\)",
        stderr)
    failure_state = re.search(
        r"AOT execution stopped .*\[cpsr=([0-9a-fA-F]+), fpscr=([0-9a-fA-F]+)\]",
        stderr)
    runs = re.findall(r"AOT run=(\d+) blocks=(\d+) exit=(\d+) pc=([0-9a-fA-F]+)", stderr)
    hot_sets, hot_parse_error, expected_core_ids = parse_hot_telemetry(stderr, core_sha256)
    expected_failure = failure is not None and int(failure.group(1)) == 6
    identity_verified = "AOT identity verified:" in stderr
    aot_backend_active = "Experimental ARM_Aot active:" in stderr
    pica_metal_backend_active = "Experimental PICA Metal rasterizer active:" in stderr
    report = {
        "schema_version": 1,
        "scope": "experimental AOT core fail-closed smoke, not gameplay",
        "timed_out": timed_out,
        "returncode": returncode,
        "requested_frames": args.frames,
        "command": command,
        "environment": ({"MH4U_PICA_METAL_CORE": environment["MH4U_PICA_METAL_CORE"]}
                        if "MH4U_PICA_METAL_CORE" in environment else {}),
        "core_sha256": core_sha256,
        "outcome": "expected-missing-block" if expected_failure else "unexpected",
        "aot_failure_reported": failure is not None,
        "aot_exit": int(failure.group(1)) if failure else None,
        "aot_pc": f"0x{failure.group(2)}" if failure else None,
        "aot_detail": f"0x{failure.group(3)}" if failure else None,
        "aot_cpsr": f"0x{failure_state.group(1)}" if failure_state else None,
        "aot_fpscr": f"0x{failure_state.group(2)}" if failure_state else None,
        "aot_run_count": int(runs[-1][0]) if runs else 0,
        "aot_block_callbacks": int(runs[-1][1]) if runs else 0,
        "aot_hot_descriptor_sets": hot_sets,
        "aot_hot_telemetry_parse_error": hot_parse_error,
        "aot_expected_core_ids": expected_core_ids,
        "first_run_exit": int(runs[0][2]) if runs else None,
        "identity_verified": identity_verified,
        "aot_backend_active": aot_backend_active,
        "pica_metal_requested": args.require_aot_metal,
        "pica_metal_backend_active": pica_metal_backend_active,
        "host_cpu_option": metrics.get("cpu"),
        "actual_cpu_evidence": "AOT telemetry and identity verification",
        "frame_limit_reached": metrics.get("frame_limit_reached"),
        "video_frames": metrics.get("video_frames"),
        "retro_run_calls": metrics.get("retro_run_calls"),
    }
    output = state.parent / "aot-core-smoke.json"
    output.write_text(json.dumps(report, indent=2) + "\n")
    (state.parent / "aot-core-smoke.stdout.log").write_text(stdout)
    (state.parent / "aot-core-smoke.stderr.log").write_text(stderr)
    print(json.dumps(report, indent=2))
    passed = (not timed_out and returncode == 1 and expected_failure and
              identity_verified and report["first_run_exit"] == 2 and
              report["aot_cpsr"] is not None and report["aot_fpscr"] is not None and
              not hot_parse_error and report["frame_limit_reached"] is False and
              report["video_frames"] == 0)
    if args.require_aot_metal:
        passed = passed and aot_backend_active and pica_metal_backend_active
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Run the experimental AOT core with a fresh local profile and a wall-clock bound."""

import argparse
import json
import math
import pathlib
import re
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--core", required=True)
    parser.add_argument("--game", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--frames", type=int, default=300)
    parser.add_argument("--timeout", type=float, default=20)
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
    timed_out = False
    try:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=args.timeout)
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
    expected_failure = failure is not None and int(failure.group(1)) == 6
    identity_verified = "AOT identity verified:" in stderr
    report = {
        "schema_version": 1,
        "scope": "experimental AOT core fail-closed smoke, not gameplay",
        "timed_out": timed_out,
        "returncode": returncode,
        "requested_frames": args.frames,
        "outcome": "expected-missing-block" if expected_failure else "unexpected",
        "aot_failure_reported": failure is not None,
        "aot_exit": int(failure.group(1)) if failure else None,
        "aot_pc": f"0x{failure.group(2)}" if failure else None,
        "aot_detail": f"0x{failure.group(3)}" if failure else None,
        "aot_cpsr": f"0x{failure_state.group(1)}" if failure_state else None,
        "aot_fpscr": f"0x{failure_state.group(2)}" if failure_state else None,
        "aot_run_count": int(runs[-1][0]) if runs else 0,
        "aot_block_callbacks": int(runs[-1][1]) if runs else 0,
        "first_run_exit": int(runs[0][2]) if runs else None,
        "identity_verified": identity_verified,
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
    passed = (not timed_out and returncode not in (None, 0) and expected_failure and
              identity_verified and report["first_run_exit"] == 2 and
              report["aot_cpsr"] is not None and report["aot_fpscr"] is not None and
              report["frame_limit_reached"] is False and report["video_frames"] == 0)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())

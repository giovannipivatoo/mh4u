#!/usr/bin/env python3
"""Bounded offline discovery of additional AOT entry descriptors."""

import argparse
import dataclasses
import hashlib
import json
import math
import os
import pathlib
import re
import signal
import subprocess
import sys
import time

import build_core_adapter


ROOT = pathlib.Path(__file__).resolve().parents[2]
LOCAL = (ROOT / ".local").resolve()
CODE_BASE = 0x100000
CPSR_MODE_MASK = 0x0600FE20
FPSCR_MODE_MASK = 0x07F70000
IT_MASK = 0x0600FC00
PRIMARY_DESCRIPTOR = "0x100000,0x10,0x03c00010"
HEX_U32 = re.compile(r"0x[0-9a-fA-F]{1,8}\Z")


class ReportError(ValueError):
    pass


@dataclasses.dataclass(frozen=True, order=True)
class Descriptor:
    pc: int
    cpsr_mode: int
    fpscr_mode: int

    def argument(self) -> str:
        return f"0x{self.pc:x},0x{self.cpsr_mode:x},0x{self.fpscr_mode:x}"

    def record(self) -> dict:
        return {
            "pc": f"0x{self.pc:x}",
            "cpsr_mode": f"0x{self.cpsr_mode:x}",
            "fpscr_mode": f"0x{self.fpscr_mode:x}",
        }


def normalize_descriptor(pc: int, cpsr: int, fpscr: int) -> Descriptor:
    if any(type(value) is not int or not 0 <= value <= 0xFFFFFFFF
           for value in (pc, cpsr, fpscr)):
        raise ReportError("descriptor fields must be unsigned 32-bit integers")
    if cpsr & IT_MASK:
        raise ReportError("Thumb IT state is unsupported")
    thumb = bool(cpsr & 0x20)
    if (thumb and pc & 1) or (not thumb and pc & 3):
        raise ReportError("PC is not aligned for its ARM/Thumb mode")
    return Descriptor(pc, cpsr & CPSR_MODE_MASK, fpscr & FPSCR_MODE_MASK)


def parse_descriptor(text: str) -> Descriptor:
    fields = text.split(",")
    if len(fields) != 3:
        raise ReportError("descriptor must be PC,CPSR,FPSCR")
    try:
        values = [int(field, 0) for field in fields]
    except ValueError as error:
        raise ReportError("descriptor contains an invalid integer") from error
    return normalize_descriptor(*values)


def report_u32(report: dict, name: str) -> int:
    value = report.get(name)
    if not isinstance(value, str) or not HEX_U32.fullmatch(value):
        raise ReportError(f"{name} must be a hexadecimal 32-bit string")
    return int(value, 16)


def descriptor_from_report(report: dict, code_size: int) -> Descriptor:
    required = {
        "schema_version": 1,
        "timed_out": False,
        "returncode": 1,
        "outcome": "expected-missing-block",
        "aot_failure_reported": True,
        "aot_exit": 6,
        "first_run_exit": 2,
        "identity_verified": True,
        "frame_limit_reached": False,
        "video_frames": 0,
    }
    for name, expected in required.items():
        if type(report.get(name)) is not type(expected) or report.get(name) != expected:
            raise ReportError(f"unexpected {name}")
    for name in ("aot_run_count", "aot_block_callbacks", "retro_run_calls"):
        value = report.get(name)
        if type(value) is not int or value <= 0:
            raise ReportError(f"{name} must be a positive integer")
    pc = report_u32(report, "aot_pc")
    if report_u32(report, "aot_detail") != pc:
        raise ReportError("MissingBlock detail does not match PC")
    cpsr = report_u32(report, "aot_cpsr")
    fpscr = report_u32(report, "aot_fpscr")
    descriptor = normalize_descriptor(pc, cpsr, fpscr)
    instruction_bytes = 2 if descriptor.cpsr_mode & 0x20 else 4
    if (code_size < instruction_bytes or pc < CODE_BASE or
            pc - CODE_BASE > code_size - instruction_bytes):
        raise ReportError("MissingBlock PC is outside the verified title code")
    return descriptor


def decide_next(report: dict, known: set[Descriptor], previous: Descriptor | None,
                code_size: int) -> tuple[str, Descriptor | None]:
    descriptor = descriptor_from_report(report, code_size)
    if descriptor == previous:
        return "repeated-gap", descriptor
    if descriptor in known:
        return "duplicate-descriptor", descriptor
    return "add-descriptor", descriptor


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_below(path: pathlib.Path, parent: pathlib.Path, label: str) -> pathlib.Path:
    resolved = path.resolve()
    if resolved == parent or parent not in resolved.parents:
        raise ValueError(f"{label} must be below {parent}")
    return resolved


def run_bounded(command: list[str], timeout: float, stdout_path: pathlib.Path,
                stderr_path: pathlib.Path) -> tuple[int | None, bool, float]:
    started = time.monotonic()
    with stdout_path.open("w") as stdout, stderr_path.open("w") as stderr:
        process = subprocess.Popen(command, cwd=ROOT, text=True, stdout=stdout, stderr=stderr,
                                   start_new_session=True)
        try:
            returncode = process.wait(timeout=timeout)
            timed_out = False
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            returncode = None
            timed_out = True
    return returncode, timed_out, time.monotonic() - started


def write_json(path: pathlib.Path, value: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def command_record(command: list[str]) -> list[str]:
    result = []
    for argument in command:
        path = pathlib.Path(argument)
        if path.is_absolute():
            try:
                result.append(str(path.relative_to(ROOT)))
                continue
            except ValueError:
                pass
        result.append(argument)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True, type=pathlib.Path)
    parser.add_argument("--generator", default=ROOT / ".local/aot-candidate/mh4u-aot-generator",
                        type=pathlib.Path)
    parser.add_argument("--host", default=ROOT / "build/mh4u-runtime", type=pathlib.Path)
    parser.add_argument("--game", default=ROOT / ".local/game/main.cxi", type=pathlib.Path)
    parser.add_argument("--iterations", type=int, default=8)
    parser.add_argument("--smoke-timeout", type=float, default=20)
    parser.add_argument("--total-timeout", type=float, default=1200)
    parser.add_argument("--frames", type=int, default=300)
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 8:
        parser.error("--iterations must be between 1 and 8")
    if (not math.isfinite(args.smoke_timeout) or args.smoke_timeout <= 0 or
            not math.isfinite(args.total_timeout) or args.total_timeout <= 0):
        parser.error("timeouts must be positive and finite")
    if args.frames <= 0 or args.jobs <= 0:
        parser.error("--frames and --jobs must be positive")
    try:
        output_dir = require_below(args.output_dir, LOCAL, "--output-dir")
        generator = require_below(args.generator, LOCAL, "--generator")
        game = require_below(args.game, LOCAL, "--game")
        host = require_below(args.host, ROOT, "--host")
    except ValueError as error:
        parser.error(str(error))
    for path, label in ((generator, "generator"), (game, "game"), (host, "host")):
        if not path.is_file():
            parser.error(f"{label} does not exist: {path}")
    if output_dir.exists():
        parser.error("--output-dir must be fresh")
    output_dir.mkdir(parents=True)
    deadline = time.monotonic() + args.total_timeout
    code = build_core_adapter.CODE
    provenance_path = ROOT / ".local/core-provenance.json"
    report_path = output_dir / "offline-expansion.json"
    known = {parse_descriptor(PRIMARY_DESCRIPTOR)}
    known.update(parse_descriptor(value) for value in build_core_adapter.DEFAULT_ENTRY_DESCRIPTORS)
    added: list[Descriptor] = []
    report = {
        "schema_version": 1,
        "scope": "bounded offline AOT descriptor discovery, not gameplay",
        "limits": {
            "iterations": args.iterations,
            "smoke_timeout_seconds": args.smoke_timeout,
            "total_timeout_seconds": args.total_timeout,
            "frames_per_smoke": args.frames,
            "max_blocks": 1024,
            "max_guest_instruction_fetches": 65536,
        },
        "inputs": {
            "title_code": {"path": str(code.relative_to(ROOT)), "sha256": sha256(code)},
            "game": {"path": str(game.relative_to(ROOT)), "sha256": sha256(game)},
            "generator": {"path": str(generator.relative_to(ROOT)), "sha256": sha256(generator)},
            "host": {"path": str(host.relative_to(ROOT)), "sha256": sha256(host)},
            "adapter_patch": {
                "path": str(build_core_adapter.PATCH.relative_to(ROOT)),
                "sha256": sha256(build_core_adapter.PATCH),
            },
            "core_provenance": json.loads(provenance_path.read_text()),
        },
        "initial_descriptors": [item.record() for item in sorted(known)],
        "iterations": [],
        "stop_reason": "running",
    }
    compiled_added_count = 0
    write_json(report_path, report)
    previous: Descriptor | None = None
    for index in range(1, args.iterations + 1):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            report["stop_reason"] = "total-timeout"
            break
        iteration_dir = output_dir / f"iteration-{index:02d}"
        iteration_dir.mkdir()
        artifact = iteration_dir / "title.cpp"
        manifest = iteration_dir / "title.json"
        build_command = [
            sys.executable, str(ROOT / "tools/aot/build_core_adapter.py"),
            "--generator", str(generator), "--jobs", str(args.jobs),
            "--artifact", str(artifact), "--manifest", str(manifest),
        ]
        for descriptor in added:
            build_command.extend(("--entry-descriptor", descriptor.argument()))
        iteration = {
            "index": index,
            "descriptors_added_before_build": [item.record() for item in added],
            "build_command": command_record(build_command),
        }
        report["iterations"].append(iteration)
        write_json(report_path, report)
        try:
            returncode, timed_out, elapsed = run_bounded(
                build_command, remaining, iteration_dir / "build.stdout.log",
                iteration_dir / "build.stderr.log")
        except OSError as error:
            iteration["build"] = {"launch_error": str(error)}
            report["stop_reason"] = "build-launch-error"
            break
        iteration["build"] = {
            "returncode": returncode,
            "timed_out": timed_out,
            "elapsed_seconds": round(elapsed, 3),
        }
        if timed_out:
            report["stop_reason"] = "total-timeout"
            break
        if returncode != 0:
            build_error = (iteration_dir / "build.stderr.log").read_text(errors="replace")
            iteration["build"]["unsupported_ir"] = "unsupported IR opcode" in build_error
            report["stop_reason"] = (
                "unsupported-ir" if iteration["build"]["unsupported_ir"] else "build-error")
            break
        try:
            generated_manifest = json.loads(manifest.read_text())
        except (OSError, json.JSONDecodeError) as error:
            iteration["build"]["manifest_error"] = str(error)
            report["stop_reason"] = "invalid-generator-manifest"
            break
        if (generated_manifest.get("max_blocks") != 1024 or
                generated_manifest.get("max_guest_instruction_fetches") != 65536):
            report["stop_reason"] = "translation-limit-mismatch"
            break
        compiled_added_count = len(added)
        core = build_core_adapter.BUILD / "bin/Release/azahar_libretro.dylib"
        iteration["artifacts"] = {
            "source_sha256": sha256(artifact),
            "manifest_sha256": sha256(manifest),
            "core_sha256": sha256(core),
            "generator_manifest": generated_manifest,
        }
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            report["stop_reason"] = "total-timeout"
            break
        state = iteration_dir / "state"
        smoke_command = [
            sys.executable, str(ROOT / "tools/aot/core_smoke.py"),
            "--host", str(host), "--core", str(core), "--game", str(game),
            "--state-dir", str(state), "--frames", str(args.frames),
            "--timeout", str(args.smoke_timeout),
        ]
        iteration["smoke_command"] = command_record(smoke_command)
        try:
            returncode, timed_out, elapsed = run_bounded(
                smoke_command, min(remaining, args.smoke_timeout + 10),
                iteration_dir / "smoke.stdout.log", iteration_dir / "smoke.stderr.log")
        except OSError as error:
            iteration["smoke"] = {"launch_error": str(error)}
            report["stop_reason"] = "smoke-launch-error"
            break
        iteration["smoke"] = {
            "returncode": returncode,
            "timed_out": timed_out,
            "elapsed_seconds": round(elapsed, 3),
        }
        smoke_report_path = iteration_dir / "aot-core-smoke.json"
        if timed_out:
            report["stop_reason"] = (
                "total-timeout" if time.monotonic() >= deadline else "smoke-wrapper-timeout")
            break
        if returncode != 0 or not smoke_report_path.is_file():
            report["stop_reason"] = "invalid-smoke-result"
            break
        try:
            smoke_report = json.loads(smoke_report_path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            iteration["smoke"]["report_error"] = str(error)
            report["stop_reason"] = "invalid-smoke-json"
            break
        iteration["smoke_report"] = smoke_report
        try:
            decision, descriptor = decide_next(smoke_report, known, previous, code.stat().st_size)
        except (ReportError, TypeError) as error:
            iteration["decision_error"] = str(error)
            report["stop_reason"] = "invalid-smoke-report"
            break
        iteration["decision"] = decision
        iteration["observed_descriptor"] = descriptor.record()
        if decision != "add-descriptor":
            report["stop_reason"] = decision
            break
        previous = descriptor
        known.add(descriptor)
        added.append(descriptor)
        print(f"iteration {index}: add {descriptor.argument()}", flush=True)
        report["stop_reason"] = "max-iterations" if index == args.iterations else "running"
        write_json(report_path, report)
    report["elapsed_seconds"] = round(args.total_timeout - max(0, deadline - time.monotonic()), 3)
    report["discovered_descriptors"] = [item.record() for item in added]
    report["compiled_discovered_descriptors"] = [
        item.record() for item in added[:compiled_added_count]
    ]
    report["pending_descriptor"] = (
        added[compiled_added_count].record() if compiled_added_count < len(added) else None
    )
    write_json(report_path, report)
    print(json.dumps({
        "manifest": str(report_path.relative_to(ROOT)),
        "stop_reason": report["stop_reason"],
        "iterations": len(report["iterations"]),
        "discovered": len(added),
    }))
    return 0 if report["stop_reason"] in {
        "max-iterations", "repeated-gap", "duplicate-descriptor", "unsupported-ir"
    } else 1


if __name__ == "__main__":
    raise SystemExit(main())

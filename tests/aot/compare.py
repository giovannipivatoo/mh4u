#!/usr/bin/env python3
import argparse
import json
import pathlib
import subprocess
import sys
import tempfile


def run(command: list[str]) -> bytes:
    return subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--jit")
    parser.add_argument("--runner")
    parser.add_argument("--fixture")
    parser.add_argument("--manifest")
    parser.add_argument("--generator")
    parser.add_argument("--artifact-root")
    parser.add_argument("--input-sha256")
    parser.add_argument("--code-bin")
    parser.add_argument("--matrix", action="store_true")
    parser.add_argument("--shift-matrix", action="store_true")
    parser.add_argument("--dispatcher-controls", action="store_true")
    parser.add_argument("--exclusive", action="store_true")
    parser.add_argument("--signextend", action="store_true")
    args = parser.parse_args()
    if args.generator:
        output = pathlib.Path(args.artifact_root) / "must-not-exist.cpp"
        manifest = pathlib.Path(args.artifact_root) / "must-not-exist.json"
        output.unlink(missing_ok=True)
        manifest.unlink(missing_ok=True)
        result = subprocess.run([
            args.generator, "--fixture", args.fixture, "--input-sha256", args.input_sha256,
            "--artifact-root", args.artifact_root, "--output", str(output),
            "--manifest", str(manifest),
        ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert result.returncode != 0
        assert "unsupported IR opcode at guest PC 0x1000: SignExtendWordToLong" in result.stderr
        assert not output.exists() and not manifest.exists()
        return 0
    if args.manifest:
        data = json.loads(pathlib.Path(args.manifest).read_text())
        assert data["input_kind"] == "title-code"
        assert data["input_sha256"] == "63940d7ef1fecc119f9fb820f5f6a2cf2f2a5549e4a70f00319fbd6c9c1ad8dc"
        assert data["architecture"] == "ARMv6K"
        assert data["tick_model"] == "Azahar Core::TicksForInstruction"
        assert data["pc"] == "0x100000"
        assert data["entry_descriptor_count"] == len(data["entry_descriptors"])
        assert data["entry_descriptors"][0]["pc"] == data["pc"]
        assert 0 < data["block_count"] <= data["max_blocks"]
        assert data["guest_instruction_fetches"] <= data["max_guest_instruction_fetches"]
        assert data["max_dispatch_steps"] > 0
        assert data["next_pc"] == "0x100024"
        assert data["emitted_blocks_supported"] is True
        assert data["frontier_count"] == len(data["frontier"])
        assert data["unresolved_indirect_count"] == len(data["unresolved_indirect"])
        assert data["coverage_complete"] is (
            data["static_direct_frontier_exhausted"] and
            data["unresolved_indirect_count"] == 0)
        if data["block_count"] > 1:
            assert data["static_direct_graph_reached_svc"] is True
            assert data["continue_after_svc"] is False
            assert data["coverage_complete"] is False
            assert data["stop_reason"] == "svc-discovered"
            assert data["static_direct_frontier_exhausted"] is False
            assert data["unresolved_indirect_count"] > 0
            assert 1 < data["block_count"] <= 64
            assert 0 < data["guest_instruction_fetches"] <= 4096
            expected = run([args.jit, args.fixture, args.code_bin])
            actual = run([args.runner, args.fixture, args.code_bin])
            if expected != actual:
                sys.stderr.write("Title JIT reference:\n" + expected.decode())
                sys.stderr.write("Title AOT runner:\n" + actual.decode())
                return 1
            values = dict(line.split("=", 1) for line in actual.decode().splitlines())
            assert values["ticks_elapsed"] == "477324"
            assert values["svc"] != ""
            assert int(values["memory_changed_bytes"]) > 0
            symbols = subprocess.run(["nm", args.runner], check=True, text=True,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
            assert "Dynarmic" not in symbols
            return 0
        if args.runner:
            output = run([args.runner, args.fixture, "--linked"]).decode()
            values = dict(line.split("=", 1) for line in output.splitlines())
            assert values["r14"] == "00100004"
            assert values["r15"] == "00100024"
            assert values["ticks_elapsed"] == "1"
            assert values["ticks_remaining"] == "99"
        return 0
    if not (args.jit and args.runner and args.fixture):
        if not (args.dispatcher_controls and args.runner and args.fixture):
            parser.error("comparison needs --jit, --runner and --fixture")
    if args.dispatcher_controls:
        template = pathlib.Path(args.fixture).read_text()
        with tempfile.TemporaryDirectory(prefix="aot-controls-",
                                         dir=pathlib.Path(args.runner).parent) as directory:
            zero = pathlib.Path(directory) / "zero.fixture"
            crossing = pathlib.Path(directory) / "crossing.fixture"
            zero.write_text(template.replace("ticks 100", "ticks 0"))
            crossing.write_text(template.replace("ticks 100", "ticks 3"))
            cases = [
                (zero, "--dispatch", "00000000", "0", "0"),
                (crossing, "--dispatch", "00000002", "4", "0"),
                (pathlib.Path(args.fixture), "--limit", "00000002", "4", "96"),
            ]
            for fixture, expected_exit, r0, elapsed, remaining in cases:
                output = run([args.runner, str(fixture), expected_exit]).decode()
                values = dict(line.split("=", 1) for line in output.splitlines())
                assert values["r0"] == r0
                assert values["r15"] == "00001000"
                assert values["ticks_elapsed"] == elapsed
                assert values["ticks_remaining"] == remaining
                assert values["svc"] == ""
        return 0
    fixtures = [args.fixture]
    temporary = None
    if args.matrix:
        template = pathlib.Path(args.fixture).read_text()
        cases = [(0, 0), (1, 0xffffffff), (0x7fffffff, 1),
                 (0x80000000, 0xffffffff), (0xffffffff, 1)]
        temporary = tempfile.TemporaryDirectory(prefix="aot-matrix-",
                                                dir=pathlib.Path(args.runner).parent)
        fixtures = []
        for carry in (0, 1):
            for index, (lhs, rhs) in enumerate(cases):
                text = template.replace("cpsr 0x10", f"cpsr {0x20000010 if carry else 0x10:#x}")
                text = text.replace("reg 0 0", f"reg 0 {lhs:#x}")
                text = text.replace("reg 1 0", f"reg 1 {rhs:#x}")
                path = pathlib.Path(temporary.name) / f"case-{carry}-{index}.fixture"
                path.write_text(text)
                fixtures.append(str(path))
    elif args.shift_matrix:
        template = pathlib.Path(args.fixture).read_text()
        values = (0, 1, 0x7fffffff, 0x80000000, 0xffffffff)
        amounts = (0, 1, 31, 32, 33, 255)
        temporary = tempfile.TemporaryDirectory(prefix="aot-shifts-",
                                                dir=pathlib.Path(args.runner).parent)
        fixtures = []
        for carry in (0, 1):
            for value in values:
                for amount in amounts:
                    text = template.replace(
                        "cpsr 0x10", f"cpsr {0x20000010 if carry else 0x10:#x}")
                    text = text.replace("reg 0 0", f"reg 0 {value:#x}")
                    text = text.replace("reg 1 0", f"reg 1 {amount:#x}")
                    path = pathlib.Path(temporary.name) / f"case-{carry}-{value:x}-{amount}.fixture"
                    path.write_text(text)
                    fixtures.append(str(path))
    elif args.signextend:
        template = pathlib.Path(args.fixture).read_text()
        temporary = tempfile.TemporaryDirectory(prefix="aot-signextend-",
                                                dir=pathlib.Path(args.runner).parent)
        fixtures = []
        for value in (0, 1, 0x7f, 0x80, 0xff):
            path = pathlib.Path(temporary.name) / f"case-{value:x}.fixture"
            path.write_text(template.replace("byte 0x1800 0", f"byte 0x1800 {value:#x}"))
            fixtures.append(str(path))
    for fixture in fixtures:
        expected = run([args.jit, fixture])
        actual = run([args.runner, fixture])
        if expected != actual:
            sys.stderr.write(f"Fixture: {fixture}\nJIT reference:\n" + expected.decode())
            sys.stderr.write("AOT runner:\n" + actual.decode())
            return 1
        if args.exclusive:
            values = dict(line.split("=", 1) for line in actual.decode().splitlines())
            assert values["r1"] == "44332211"
            assert values["r2"] == "00000000"
            assert values["r4"] == "00000001"
            assert values["r6"] == "deadbeef"
            assert values["r7"] == "00000001"
            assert values["r10"] == "cafebabe"
            assert values["memory"][0x1800 * 2:0x1804 * 2] == "bebafeca"
    symbols = subprocess.run(["nm", args.runner], check=True, text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
    if "Dynarmic" in symbols:
        raise AssertionError("AOT runner contains a Dynarmic symbol")
    if temporary:
        temporary.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

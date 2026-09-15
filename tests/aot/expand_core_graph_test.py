#!/usr/bin/env python3
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/aot"))
import expand_core_graph as graph  # noqa: E402
import core_smoke  # noqa: E402

INPUT_SHA = "a" * 64
CORE_SHA = "b" * 64


def valid_report(**changes):
    report = {
        "schema_version": 1,
        "timed_out": False,
        "returncode": 1,
        "outcome": "expected-missing-block",
        "aot_failure_reported": True,
        "aot_exit": 6,
        "aot_pc": "0x00104618",
        "aot_detail": "0x00104618",
        "aot_cpsr": "0x20000010",
        "aot_fpscr": "0x03000000",
        "aot_run_count": 5,
        "aot_block_callbacks": 318332,
        "first_run_exit": 2,
        "identity_verified": True,
        "frame_limit_reached": False,
        "video_frames": 0,
        "retro_run_calls": 1,
    }
    report.update(changes)
    return report


class DescriptorTest(unittest.TestCase):
    def test_normalizes_runtime_flags(self):
        descriptor = graph.descriptor_from_report(valid_report(), 0x1000000)
        self.assertEqual(descriptor.argument(), "0x104618,0x0,0x3000000")

    def test_accepts_aligned_thumb_descriptor(self):
        descriptor = graph.descriptor_from_report(
            valid_report(aot_pc="0x002fd2ec", aot_detail="0x002fd2ec",
                         aot_cpsr="0x60000030"), 0x1000000)
        self.assertEqual(descriptor.argument(), "0x2fd2ec,0x20,0x3000000")

    def test_rejects_malformed_hex(self):
        with self.assertRaisesRegex(graph.ReportError, "aot_pc"):
            graph.descriptor_from_report(valid_report(aot_pc="-1"), 0x1000000)

    def test_rejects_signal_exit(self):
        with self.assertRaisesRegex(graph.ReportError, "returncode"):
            graph.descriptor_from_report(valid_report(returncode=-9), 0x1000000)

    def test_rejects_unverified_identity(self):
        with self.assertRaisesRegex(graph.ReportError, "identity_verified"):
            graph.descriptor_from_report(valid_report(identity_verified=False), 0x1000000)

    def test_rejects_timeout(self):
        with self.assertRaisesRegex(graph.ReportError, "timed_out"):
            graph.descriptor_from_report(valid_report(timed_out=True), 0x1000000)

    def test_rejects_mismatched_detail(self):
        with self.assertRaisesRegex(graph.ReportError, "detail"):
            graph.descriptor_from_report(valid_report(aot_detail="0x0010461c"), 0x1000000)

    def test_rejects_it_state(self):
        with self.assertRaisesRegex(graph.ReportError, "IT state"):
            graph.descriptor_from_report(valid_report(aot_cpsr="0x00000430"), 0x1000000)

    def test_rejects_unaligned_arm_pc(self):
        with self.assertRaisesRegex(graph.ReportError, "aligned"):
            graph.descriptor_from_report(
                valid_report(aot_pc="0x0010461a", aot_detail="0x0010461a"), 0x1000000)

    def test_rejects_pc_outside_code(self):
        with self.assertRaisesRegex(graph.ReportError, "outside"):
            graph.descriptor_from_report(
                valid_report(aot_pc="0x000ffffc", aot_detail="0x000ffffc"), 0x1000000)

    def test_rejects_code_shorter_than_instruction(self):
        with self.assertRaisesRegex(graph.ReportError, "outside"):
            graph.descriptor_from_report(
                valid_report(aot_pc="0x00100000", aot_detail="0x00100000"), 3)


class DecisionTest(unittest.TestCase):
    def test_adds_new_descriptor(self):
        action, descriptor = graph.decide_next(valid_report(), set(), None, 0x1000000)
        self.assertEqual(action, "add-descriptor")
        self.assertEqual(descriptor.pc, 0x104618)

    def test_stops_on_same_gap(self):
        descriptor = graph.descriptor_from_report(valid_report(), 0x1000000)
        action, _ = graph.decide_next(valid_report(), {descriptor}, descriptor, 0x1000000)
        self.assertEqual(action, "repeated-gap")

    def test_stops_on_existing_normalized_descriptor(self):
        descriptor = graph.Descriptor(0x104618, 0, 0x03000000)
        action, _ = graph.decide_next(valid_report(), {descriptor}, None, 0x1000000)
        self.assertEqual(action, "duplicate-descriptor")


class HotTelemetryTest(unittest.TestCase):
    def telemetry(self, **changes):
        item = {
            "input_sha256": INPUT_SHA,
            "core_sha256": CORE_SHA,
            "core_id": 0,
            "count": 1,
            "overflow": False,
            "entries": [{"pc": "0x00104618", "cpsr_mode": "0x0",
                         "fpscr_mode": "0x03000000"}],
        }
        item.update(changes)
        return {"core_sha256": CORE_SHA,
                "aot_hot_telemetry_parse_error": False,
                "aot_expected_core_ids": [0],
                "aot_hot_descriptor_sets": [item]}

    def test_accepts_bound_set_with_matching_provenance(self):
        result = graph.hot_descriptors_from_report(
            self.telemetry(), 0x1000000, INPUT_SHA, CORE_SHA)
        self.assertEqual({item.pc for item in result}, {0x104618})

    def test_rejects_wrong_core_hash(self):
        with self.assertRaisesRegex(graph.ReportError, "inconsistent"):
            graph.hot_descriptors_from_report(
                self.telemetry(core_sha256="c" * 64), 0x1000000, INPUT_SHA, CORE_SHA)

    def test_rejects_overflow(self):
        with self.assertRaisesRegex(graph.ReportError, "inconsistent"):
            graph.hot_descriptors_from_report(
                self.telemetry(overflow=True), 0x1000000, INPUT_SHA, CORE_SHA)

    def test_rejects_invalid_parse_marker(self):
        report = self.telemetry()
        report["aot_hot_telemetry_parse_error"] = True
        with self.assertRaisesRegex(graph.ReportError, "parsed"):
            graph.hot_descriptors_from_report(report, 0x1000000, INPUT_SHA, CORE_SHA)

    def test_capacity_is_fail_closed(self):
        known = {graph.Descriptor(index * 4 + 0x100000, 0, 0) for index in range(1024)}
        hot = {graph.Descriptor(0x200000, 0, 0)}
        with self.assertRaisesRegex(graph.CapacityError, "exceeds 1024"):
            graph.mandatory_additions(known, hot, graph.Descriptor(0x200004, 0, 0))

    def test_pending_contains_every_uncompiled_addition(self):
        known = {graph.Descriptor(0x100000, 0, 0)}
        hot = {graph.Descriptor(0x100004, 0, 0), graph.Descriptor(0x100008, 0, 0)}
        additions = graph.mandatory_additions(
            known, hot, graph.Descriptor(0x10000c, 0, 0))
        self.assertEqual(graph.pending_descriptors(additions, 0), additions)


class HotTelemetryParserTest(unittest.TestCase):
    SHA = "a" * 64

    @staticmethod
    def banner(count=2):
        return f"[1] Core <Info> x: Experimental ARM_Aot active: {count} guest cores"

    @classmethod
    def hot(cls, core_id, entries="", count=0):
        return (f"[1] Core.ARM11 <Info> x: AOT hot descriptors: input_sha256={cls.SHA} "
                f"core={core_id} count={count} overflow=0 entries={entries}")

    def test_accepts_all_core_ids_including_empty_sets(self):
        stderr = "\n".join((self.banner(), self.hot(0), self.hot(1)))
        sets, parse_error, expected = core_smoke.parse_hot_telemetry(stderr, CORE_SHA)
        self.assertFalse(parse_error)
        self.assertEqual(expected, [0, 1])
        self.assertEqual([item["core_id"] for item in sets], [0, 1])

    def test_rejects_missing_core_dump(self):
        stderr = "\n".join((self.banner(), self.hot(0)))
        _, parse_error, _ = core_smoke.parse_hot_telemetry(stderr, CORE_SHA)
        self.assertTrue(parse_error)

    def test_rejects_malformed_second_marker_line(self):
        stderr = "\n".join((self.banner(), self.hot(0), self.hot(1) + " trailing"))
        sets, parse_error, _ = core_smoke.parse_hot_telemetry(stderr, CORE_SHA)
        self.assertTrue(parse_error)
        self.assertEqual([item["core_id"] for item in sets], [0])


if __name__ == "__main__":
    unittest.main()

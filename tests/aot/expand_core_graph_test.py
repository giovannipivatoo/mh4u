#!/usr/bin/env python3
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/aot"))
import expand_core_graph as graph  # noqa: E402


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


if __name__ == "__main__":
    unittest.main()

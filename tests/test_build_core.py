import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location('build_core', Path(__file__).resolve().parents[1] / 'tools/build_core.py')
build_core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_core)


class PatchApplicationTests(unittest.TestCase):
    def test_existing_export_gets_pinned_build_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / 'source'
            source.mkdir()
            (source / 'CMakeLists.txt').write_text('project(test)\n')
            (root / '.local').mkdir()
            (root / '.local/core-provenance.json').write_text(
                '{"commit": "' + build_core.COMMIT + '"}\n')
            with mock.patch.object(build_core, 'ROOT', root), mock.patch.object(
                    build_core, 'SOURCE', source):
                build_core.prepare_source()
            self.assertEqual((source / 'GIT-COMMIT').read_text(), build_core.COMMIT + '\n')
            self.assertEqual((source / 'GIT-TAG').read_text(), build_core.TAG + '\n')

    def test_insertion_only_patch_is_not_duplicated(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / 'sample.txt'
            source.write_text('before\nafter\n')
            patch = root / 'change.patch'
            patch.write_text('--- a/sample.txt\n+++ b/sample.txt\n@@ -1,2 +1,3 @@\n before\n+inserted\n after\n')
            build_core.apply_source_patch(root, patch)
            build_core.apply_source_patch(root, patch)
            self.assertEqual(source.read_text(), 'before\ninserted\nafter\n')

    def test_first_application_and_repeat(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / 'sample.txt'
            source.write_text('before\n')
            patch = root / 'change.patch'
            patch.write_text('--- a/sample.txt\n+++ b/sample.txt\n@@ -1 +1 @@\n-before\n+after\n')
            build_core.apply_source_patch(root, patch)
            self.assertEqual(source.read_text(), 'after\n')
            build_core.apply_source_patch(root, patch)
            self.assertEqual(source.read_text(), 'after\n')

    def test_unrecognized_source_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'sample.txt').write_text('different\n')
            patch = root / 'change.patch'
            patch.write_text('--- a/sample.txt\n+++ b/sample.txt\n@@ -1 +1 @@\n-before\n+after\n')
            with self.assertRaises(RuntimeError):
                build_core.apply_source_patch(root, patch)
            self.assertEqual((root / 'sample.txt').read_text(), 'different\n')


if __name__ == '__main__':
    unittest.main()

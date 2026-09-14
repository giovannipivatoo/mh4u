import fcntl
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
spec = importlib.util.spec_from_file_location('mh4u', ROOT / 'tools/mh4u.py')
mh4u = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mh4u)


class InstallProfileMigrationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=ROOT / '.local')
        self.base = Path(self.temporary.name)
        self.source = self.base / 'source'
        self.target = self.base / 'target'
        self.source_raw = self.source / 'Azahar' / mh4u.SAVE_SUFFIX
        self.target_raw = self.target / 'Azahar' / mh4u.SAVE_SUFFIX
        self.source_raw.mkdir(parents=True)
        (self.source_raw / 'system').write_bytes(b's' * 512)
        (self.source_raw / 'user1').write_bytes(b'u' * 81408)
        extra = self.source / 'Azahar/load/textures/pack file'
        extra.parent.mkdir(parents=True)
        extra.write_bytes(b'source texture')
        installed_texture = self.target / 'Azahar/load/textures/pack file'
        installed_texture.parent.mkdir(parents=True)
        installed_texture.write_bytes(b'installed texture')
        installed_nand = self.target / 'Azahar/nand/private system file'
        installed_nand.parent.mkdir(parents=True)
        installed_nand.write_bytes(b'installed nand')
        for state in (self.source, self.target):
            (state / 'save-import').mkdir(parents=True, exist_ok=True)
            (state / 'save-import/session.lock').touch()

    def tearDown(self):
        self.temporary.cleanup()

    def test_empty_target_migrates_and_backs_up_old_azahar(self):
        self.target_raw.mkdir(parents=True)
        (self.target_raw / 'system').write_bytes(b'o' * 512)
        old = self.target / 'Azahar/sdmc/old installed file'
        old.write_bytes(b'old')
        source_before = mh4u._profile_manifest(self.source / 'Azahar/sdmc')
        result = mh4u.migrate_install_profile(self.source, self.target)
        self.assertTrue(result['migrated'])
        self.assertEqual(result['scope'], 'sdmc savedata and extdata')
        self.assertEqual(mh4u._profile_manifest(self.source / 'Azahar/sdmc'), source_before)
        self.assertEqual(mh4u._profile_manifest(self.target / 'Azahar/sdmc'), source_before)
        backup = Path(result['backup'])
        self.assertEqual((backup / 'old installed file').read_bytes(), b'old')
        self.assertEqual((backup / mh4u.SDMC_SAVE_SUFFIX / 'system').read_bytes(), b'o' * 512)
        self.assertEqual((self.target / 'Azahar/load/textures/pack file').read_bytes(), b'installed texture')
        self.assertEqual((self.target / 'Azahar/nand/private system file').read_bytes(), b'installed nand')
        self.assertFalse(any((self.target / 'savestates').glob('*')) if (self.target / 'savestates').exists() else False)

    def test_populated_target_is_preserved(self):
        self.target_raw.mkdir(parents=True)
        user = self.target_raw / 'user2'
        user.write_bytes(b'keep')
        before = mh4u._profile_manifest(self.target / 'Azahar')
        result = mh4u.migrate_install_profile(self.source, self.target)
        self.assertFalse(result['migrated'])
        self.assertEqual(mh4u._profile_manifest(self.target / 'Azahar'), before)

    def test_lock_rejection(self):
        lock_path = self.source / 'save-import/session.lock'
        with lock_path.open('a+b') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(RuntimeError, 'Another MH4U Runtime session'):
                mh4u.migrate_install_profile(self.source, self.target)

    def test_lock_symlink_is_rejected(self):
        lock = self.source / 'save-import/session.lock'
        lock.unlink()
        lock.symlink_to(self.source_raw / 'system')
        with self.assertRaises(OSError):
            mh4u.migrate_install_profile(self.source, self.target)

    def test_symlink_fails_closed(self):
        link = self.source / 'Azahar/sdmc/link'
        link.symlink_to(self.source_raw / 'system')
        with self.assertRaisesRegex((RuntimeError, ValueError), 'symbolic links'):
            mh4u.migrate_install_profile(self.source, self.target)
        self.assertFalse((self.target / 'Azahar/sdmc').exists())

    def test_source_change_fails_closed(self):
        before = mh4u._profile_manifest(self.source / 'Azahar/sdmc')
        changed = dict(before)
        changed[next(iter(changed))] = '0' * 64
        with mock.patch.object(mh4u, '_profile_manifest', side_effect=[before, changed]):
            with self.assertRaisesRegex((RuntimeError, ValueError), 'changed during migration'):
                mh4u.migrate_install_profile(self.source, self.target)
        self.assertFalse((self.target / 'Azahar/sdmc').exists())

    def test_absent_source_is_a_noop(self):
        absent = self.base / 'absent'
        result = mh4u.migrate_install_profile(absent, self.target)
        self.assertFalse(result['migrated'])
        self.assertFalse(absent.exists())

    def test_fully_absent_target_migrates(self):
        target = self.base / 'fully-absent-target'
        result = mh4u.migrate_install_profile(self.source, target)
        self.assertTrue(result['migrated'])
        self.assertEqual(result['backup'], '')
        self.assertEqual(mh4u._profile_manifest(target / 'Azahar/sdmc'),
                         mh4u._profile_manifest(self.source / 'Azahar/sdmc'))

    def test_source_change_at_activation_rolls_target_back(self):
        before = mh4u._profile_manifest(self.source / 'Azahar/sdmc')
        changed = dict(before)
        changed[next(iter(changed))] = 'f' * 64
        manifests = [before, before, before, changed]
        with mock.patch.object(mh4u, '_profile_manifest', side_effect=manifests):
            with self.assertRaisesRegex((RuntimeError, ValueError), 'changed during activation'):
                mh4u.migrate_install_profile(self.source, self.target)
        self.assertFalse((self.target / 'Azahar/sdmc').exists())

    def test_post_swap_sync_failure_preserves_old_target(self):
        self.target_raw.mkdir(parents=True)
        (self.target_raw / 'system').write_bytes(b'o' * 512)
        old = self.target / 'Azahar/sdmc/old installed file'
        old.write_bytes(b'old')
        original_sync = mh4u._sync_directory

        def fail_after_swap(path):
            if Path(path) == self.target / 'Azahar' and (self.target_raw / 'user1').exists():
                raise OSError('injected post-swap sync failure')
            return original_sync(path)

        with mock.patch.object(mh4u, '_sync_directory', side_effect=fail_after_swap):
            with self.assertRaisesRegex(OSError, 'injected post-swap'):
                mh4u.migrate_install_profile(self.source, self.target)
        self.assertEqual(old.read_bytes(), b'old')
        self.assertEqual((self.target_raw / 'system').read_bytes(), b'o' * 512)


if __name__ == '__main__':
    unittest.main()

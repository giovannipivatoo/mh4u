"""The title launcher must reject redirected or modified local payloads."""
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import mh4u


class LauncherBoundaryTests(unittest.TestCase):
    def test_manifest_payload_bounds_and_integrity(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            game = root / 'game'
            game.mkdir()
            data = b'synthetic game input, no proprietary content'
            payload = game / 'payload'
            payload.write_bytes(data)
            record = {'path': 'payload', 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
            with patch.object(mh4u, 'GAME', game):
                self.assertEqual(mh4u.local_artifact(record), payload.resolve())
                payload.write_bytes(b'X' + data[1:])
                with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                    mh4u.local_artifact(record)
                payload.write_bytes(b'')
                with self.assertRaisesRegex(ValueError, 'size mismatch'):
                    mh4u.local_artifact(record)
                (root / 'outside').write_bytes(data)
                with self.assertRaisesRegex(ValueError, 'escapes'):
                    mh4u.local_artifact({**record, 'path': '../outside'})
                (game / 'link').symlink_to(root / 'outside')
                with self.assertRaisesRegex(ValueError, 'escapes'):
                    mh4u.local_artifact({**record, 'path': 'link'})


if __name__ == '__main__':
    unittest.main()

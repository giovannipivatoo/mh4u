"""Native app entry must reject forged title headers before loading a core."""
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

HOST = Path(__file__).resolve().parents[1] / 'build/mh4u-runtime'


@unittest.skipUnless(HOST.exists(), 'native host has not been built')
class NativeBoundaryTests(unittest.TestCase):
    def test_header_only_payload_is_rejected_before_core_load(self):
        with tempfile.TemporaryDirectory() as folder:
            game = Path(folder) / 'forged.cxi'
            header = bytearray(512)
            header[0x100:0x104] = b'NCCH'
            struct.pack_into('<Q', header, 0x118, 0x0004000000126100)
            header[0x150:0x15a] = b'CTR-P-BFGP'
            header[0x18f] = 4
            game.write_bytes(header)
            result = subprocess.run([str(HOST), '--core', str(Path(folder) / 'missing.dylib'),
                                     '--game', str(game), '--headless', '--frames', '1'],
                                    capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Game identity mismatch', result.stderr)
            self.assertNotIn('Cannot load core', result.stderr)


if __name__ == '__main__':
    unittest.main()

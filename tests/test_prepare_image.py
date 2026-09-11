"""Synthetic containers only: no game bytes or keys in the test suite."""
import hashlib
import io
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from prepare_image import bounds, decompress_blz, extract_romfs, inspect_image, verify_ivfc


def synthetic_image():
    image = bytearray(0x6000)
    image[0x100:0x104] = b"NCSD"
    struct.pack_into("<I", image, 0x104, len(image) // 512)
    struct.pack_into("<II", image, 0x120, 0x2000 // 512, 0x4000 // 512)
    h = memoryview(image)[0x2000:0x2200]
    h[0x100:0x104] = b"NCCH"
    struct.pack_into("<I", h, 0x104, 0x4000 // 512)
    struct.pack_into("<Q", h, 0x118, 0x0004000000126100)
    h[0x150:0x15A] = b"CTR-P-BFGP"
    struct.pack_into("<I", h, 0x180, 0x400)
    h[0x18F] = 4
    ex = memoryview(image)[0x2200:0x2A00]
    ex[:8] = b"testgame"
    for i, offset in enumerate((0x10, 0x20, 0x30)):
        struct.pack_into("<III", ex, offset, 0x100000 + i * 4096, 1, 16)
    ex[0x250:0x258] = b"fs:USER\0"
    h[0x160:0x180] = hashlib.sha256(ex[:0x400]).digest()
    struct.pack_into("<III", h, 0x1A0, 0xA00 // 512, 0x600 // 512, 1)
    struct.pack_into("<III", h, 0x1B0, 0x1000 // 512, 0x1000 // 512, 1)
    eh = memoryview(image)[0x2A00:0x2C00]
    eh[:8] = b".code\0\0\0"
    struct.pack_into("<II", eh, 8, 0, 16)
    eh[0x1E0:0x200] = hashlib.sha256(image[0x2C00:0x2C10]).digest()
    h[0x1C0:0x1E0] = hashlib.sha256(eh).digest()
    h[0x1E0:0x200] = hashlib.sha256(image[0x3000:0x3200]).digest()
    return image


class ImageValidationTests(unittest.TestCase):
    def test_blz_literals_references_and_refusals(self):
        compressed = b"\0\x60\0\xF0ABC\x18" + struct.pack("<II", 0x08000010, 14)
        self.assertEqual(decompress_blz(compressed, 30), b"ABC" * 10)
        for bad, size in ((b"x", 30), (compressed[:-1], 30), (compressed, 31),
                          (b"\0\0\x80" + struct.pack("<II", 0x0800000B, 1), 12)):
            with self.subTest(data=bad), self.assertRaises(ValueError):
                decompress_blz(bad, size)

    def test_ivfc_all_levels_and_corruption(self):
        data = bytearray(0x4000)
        data[:4] = b"IVFC"
        struct.pack_into("<II", data, 4, 0x10000, 32)
        for i in range(3):
            struct.pack_into("<QQI", data, 12 + i * 24, i * 4096, 32, 12)
        struct.pack_into("<I", data, 0x54, 0x5C)
        data[0x1000:0x1020] = b"X" * 32
        data[0x3000:0x3020] = hashlib.sha256(data[0x1000:0x2000]).digest()
        data[0x2000:0x2020] = hashlib.sha256(data[0x3000:0x4000]).digest()
        data[0x60:0x80] = hashlib.sha256(data[0x2000:0x3000]).digest()
        result = verify_ivfc(io.BytesIO(data), 0, len(data))
        self.assertEqual([level["blocks"] for level in result["levels"]], [1, 1, 1])
        for position, message in ((0x60, "level 0"), (0x2000, "level 0"), (0x3000, "level 1"), (0x1000, "level 2")):
            bad = data.copy()
            bad[position] ^= 1
            with self.subTest(position=position), self.assertRaisesRegex(ValueError, message):
                verify_ivfc(io.BytesIO(bad), 0, len(bad))
        with self.assertRaisesRegex(ValueError, "outside"):
            verify_ivfc(io.BytesIO(data), 0, len(data) - 1)

    def test_romfs_and_path_cycle_bounds_refusals(self):
        data = bytearray(0x74)
        struct.pack_into("<10I", data, 0, 0x28, 0x28, 4, 0x2C, 24, 0x44, 4, 0x48, 36, 0x70)
        struct.pack_into("<6I", data, 0x2C, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0)
        struct.pack_into("<IIQQII", data, 0x48, 0, 0xFFFFFFFF, 0, 4, 0xFFFFFFFF, 4)
        data[0x68:0x6C] = "ok".encode("utf-16-le")
        data[0x70:] = b"test"
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "valid"
            inventory = extract_romfs(io.BytesIO(data), 0, len(data), target)
            self.assertEqual(inventory, [{"path": "ok", "size": 4, "sha256": hashlib.sha256(b"test").hexdigest()}])
            self.assertEqual((target / "ok").read_bytes(), b"test")
            mutations = [(0x68, "..".encode("utf-16-le"), "Unsafe"),
                         (0x68, "/x".encode("utf-16-le"), "Unsafe"),
                         (0x68, "a\\".encode("utf-16-le"), "Unsafe"),
                         (0x4C, struct.pack("<I", 0), "cycle"),
                         (0x50, struct.pack("<Q", 10000), "outside"),
                         (0x64, struct.pack("<I", 10000), "metadata")]
            for i, (offset, content, message) in enumerate(mutations):
                bad = data.copy()
                bad[offset:offset + len(content)] = content
                with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                    extract_romfs(io.BytesIO(bad), 0, len(bad), Path(temp) / f"bad{i}")

    def test_valid_and_boundary_refusals(self):
        image = synthetic_image()
        result = inspect_image(io.BytesIO(image), len(image))
        self.assertEqual(result["service_acl"], ["fs:USER"])
        self.assertEqual(result["code_size"], 3 * 4096)
        changes = [
            (0x104, struct.pack("<I", 1), "size mismatch"),
            (0x120, struct.pack("<I", 0xFFFFFFFF), "outside"),
            (0x218F, b"\0", "Encrypted"),
            (0x218E, b"\xFF", "block size"),
            (0x21A0, struct.pack("<I", 0xFFFFFFFF), "outside"),
            (0x21B0, struct.pack("<I", 5), "Overlapping"),
            (0x2200, b"X", "ExHeader SHA-256"),
            (0x2C00, b"X", ".code SHA-256"),
        ]
        for offset, data, message in changes:
            with self.subTest(message=message):
                bad = image.copy()
                bad[offset:offset + len(data)] = data
                with self.assertRaisesRegex(ValueError, message):
                    inspect_image(io.BytesIO(bad), len(bad))
        with self.assertRaisesRegex(ValueError, "Truncated"):
            inspect_image(io.BytesIO(b"NCSD"), 4)
        for offset, size, limit in ((-1, 1, 10), (1, 0, 10), (2**64, 1, 10)):
            with self.assertRaises(ValueError):
                bounds(offset, size, limit, "test")


if __name__ == "__main__":
    unittest.main()

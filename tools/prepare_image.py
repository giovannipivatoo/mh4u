#!/usr/bin/env python3
"""Validate the user's decrypted MH4U EUR image; extract partition 0 locally.

No console keys, firmware, downloads, decryption, or external extractor.
All generated game material stays in .local/game, outside version control.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TITLE_ID = "0004000000126100"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def u32(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


def bounds(offset, size, limit, name):
    require(offset >= 0 and size > 0 and offset <= limit and size <= limit - offset,
            f"{name} is empty or outside its container")


def read_at(stream, offset, size):
    stream.seek(offset)
    data = stream.read(size)
    require(len(data) == size, "Truncated image")
    return data


def hash_region(stream, offset, size):
    stream.seek(offset)
    digest = hashlib.sha256()
    while size:
        data = stream.read(min(size, 1024 * 1024))
        require(bool(data), "Truncated image while hashing")
        digest.update(data)
        size -= len(data)
    return digest.hexdigest()


def file_hash(path):
    with path.open("rb") as stream:
        return hash_region(stream, 0, path.stat().st_size)


def check_hash(stream, offset, size, expected, name):
    actual = hash_region(stream, offset, size)
    require(actual == expected.hex(), f"{name} SHA-256 mismatch")
    return actual


def inspect_image(stream, file_size):
    """Read bounded headers and game ExeFS; reject encryption before extraction."""
    ncsd = read_at(stream, 0, 0x200)
    require(ncsd[0x100:0x104] == b"NCSD", "Expected a .3ds NCSD image")
    require(ncsd[0x18E] == 0, "Unsupported NCSD media block size")
    require(u32(ncsd, 0x104) * 0x200 == file_size, "NCSD image size mismatch")
    start, length = struct.unpack_from("<II", ncsd, 0x120)
    start, length = start * 0x200, length * 0x200
    bounds(start, length, file_size, "Partition 0")
    require(start >= 0x200, "Partition 0 overlaps NCSD header")
    h = read_at(stream, start, 0x200)
    require(h[0x100:0x104] == b"NCCH", "Partition 0 is not NCCH")
    require(h[0x18F] & 4, "Encrypted image: a user-provided decrypted image is required; no keys are fetched")
    require(h[0x18E] == 0, "Unsupported NCCH media block size")
    content_size = u32(h, 0x104) * 0x200
    bounds(0, content_size, length, "NCCH")
    title_id = f"{struct.unpack_from('<Q', h, 0x118)[0]:016x}"
    require(title_id == TITLE_ID and h[0x150:0x15A] == b"CTR-P-BFGP", "Expected MH4U EUR partition 0")
    require(u32(h, 0x180) == 0x400, "Unsupported ExHeader size")
    bounds(0x200, 0x800, content_size, "ExHeader")
    exheader = read_at(stream, start + 0x200, 0x800)
    exheader_hash = check_hash(stream, start + 0x200, 0x400, h[0x160:0x180], "ExHeader")
    regions = {}
    occupied = [(0, 0xA00, "NCCH and ExHeader")]
    for name, off in (("logo", 0x198), ("plain", 0x190), ("exefs", 0x1A0), ("romfs", 0x1B0)):
        pos, size = struct.unpack_from("<II", h, off)
        pos, size = pos * 0x200, size * 0x200
        if not size and name in ("logo", "plain"):
            continue
        bounds(pos, size, content_size, name)
        require(all(pos >= end or pos + size <= begin for begin, end, _ in occupied), f"Overlapping {name}")
        occupied.append((pos, pos + size, name))
        regions[name] = {"offset": start + pos, "size": size}
    for name, length_off, hash_off in (("exefs", 0x1A8, 0x1C0), ("romfs", 0x1B8, 0x1E0)):
        size = u32(h, length_off) * 0x200
        bounds(0, size, regions[name]["size"], name + " hash region")
        regions[name]["header_sha256"] = check_hash(stream, regions[name]["offset"], size, h[hash_off:hash_off + 32], name)
    ep = regions["exefs"]["offset"]
    eh = read_at(stream, ep, 0x200)
    files, ranges = {}, []
    for i in range(10):
        entry = eh[i * 16:(i + 1) * 16]
        if not entry[:8].strip(b"\0"):
            continue
        name = entry[:8].split(b"\0", 1)[0].decode("ascii")
        require(name not in files and name not in (".", "..") and "/" not in name and "\\" not in name, "Unsafe or duplicate ExeFS name")
        pos, size = struct.unpack_from("<II", entry, 8)
        pos += 0x200
        bounds(pos, size, regions["exefs"]["size"], "ExeFS " + name)
        require(all(pos >= end or pos + size <= begin for begin, end in ranges), "Overlapping ExeFS files")
        ranges.append((pos, pos + size))
        files[name] = {"stored_size": size, "stored_sha256": check_hash(stream, ep + pos, size, eh[0x1E0 - i * 32:0x200 - i * 32], name)}
    require(".code" in files, "Missing ExeFS .code")
    segments = {}
    code_offset = 0
    for name, offset in (("text", 0x10), ("ro", 0x20), ("data", 0x30)):
        address, pages, size = struct.unpack_from("<III", exheader, offset)
        require(0 < size <= pages * 4096 and address + pages * 4096 <= 2**32, "Invalid code segment")
        segments[name] = {"address": address, "size": size, "pages": pages, "code_offset": code_offset}
        code_offset += pages * 4096
    return {
        "schema_version": 1, "title_id": title_id, "product_code": "CTR-P-BFGP",
        "name": exheader[:8].rstrip(b"\0").decode("ascii"),
        "partition": {"index": 0, "offset": start, "size": length, "no_crypto": True},
        "regions": regions, "exheader_sha256": exheader_hash,
        "exheader_full_sha256": hashlib.sha256(exheader).hexdigest(), "exefs_files": files,
        "code_compressed": bool(exheader[0xD] & 1), "code_size": code_offset,
        "segments": segments, "stack_size": u32(exheader, 0x1C), "bss_size": u32(exheader, 0x3C),
        "service_acl": [exheader[i:i + 8].split(b"\0", 1)[0].decode("ascii") for i in range(0x250, 0x350, 8) if exheader[i]],
        "validation": {"exheader_hash": True, "exefs_header_hash": True, "exefs_file_hashes": True,
                       "romfs_header_hash": True, "romfs_ivfc_tree": False, "rsa_signatures": False},
    }


def decompress_blz(data, expected_size):
    """Backward LZSS as used by ExeFS; offsets follow Azahar's NCCH loader."""
    require(len(data) >= 8, "Truncated BLZ footer")
    footer, extra = struct.unpack_from("<II", data, len(data) - 8)
    header_size, compressed_size = footer >> 24, footer & 0xFFFFFF
    require(8 <= header_size <= compressed_size <= len(data), "Invalid BLZ footer bounds")
    require(len(data) + extra == expected_size <= 128 * 1024 * 1024, "Invalid BLZ output size")
    cursor, stop, out = len(data) - header_size, len(data) - compressed_size, expected_size
    result = bytearray(data) + bytearray(extra)
    while cursor > stop:
        cursor -= 1
        flags = data[cursor]
        for bit in range(7, -1, -1):
            if cursor == stop:
                break
            if flags & (1 << bit):
                require(cursor - stop >= 2, "Truncated BLZ reference")
                cursor -= 2
                token = struct.unpack_from("<H", data, cursor)[0]
                count, distance = (token >> 12) + 3, (token & 0xFFF) + 3
                require(out - count >= stop and out - 1 + distance < len(result), "BLZ reference outside output")
                for _ in range(count):
                    out -= 1
                    result[out] = result[out + distance]
            else:
                require(out > stop, "BLZ literal outside output")
                cursor -= 1
                out -= 1
                result[out] = data[cursor]
    require(out == stop, "BLZ did not fill output")
    return result


def verify_ivfc(stream, offset, size):
    """Verify every padded SHA-256 block, rooted in the NCCH-checked master hashes.

    Physical layout: Project_CTR ctrtool/src/IvfcProcess.cpp, v1.3.0.
    Only CTR RomFS (three 4 KiB auxiliary levels) is supported.
    """
    bounds(0, 0x60, size, "IVFC header")
    h = read_at(stream, offset, 0x60)
    require(h[:4] == b"IVFC" and u32(h, 4) == 0x10000 and u32(h, 0x54) == 0x5C, "Invalid IVFC header")
    master_size = u32(h, 8)
    levels = [struct.unpack_from("<QQI", h, 0xC + i * 0x18) for i in range(3)]
    require(all(exponent == 12 for _, _, exponent in levels), "Unsupported IVFC block size")
    align = lambda n: (n + 4095) & ~4095
    require(levels[0][0] == 0 and levels[1][0] == align(levels[0][1]) and
            levels[2][0] == levels[1][0] + align(levels[1][1]), "Invalid IVFC logical offsets")
    positions = [0, 0, align(0x60 + master_size)]
    positions[0] = align(positions[2] + levels[2][1])
    positions[1] = align(positions[0] + levels[0][1])
    bounds(0x60, master_size, size, "IVFC master hashes")
    results = []
    for i, (_, length, _) in enumerate(levels):
        bounds(positions[i], align(length), size, "IVFC level")
        count = align(length) // 4096
        parent_position = positions[i - 1] if i else 0x60
        parent_size = levels[i - 1][1] if i else master_size
        require(count * 32 == parent_size, "IVFC hash count mismatch")
        hashes = read_at(stream, offset + parent_position, parent_size)
        stream.seek(offset + positions[i])
        for first in range(0, count, 256):
            blocks = stream.read(min(256, count - first) * 4096)
            require(len(blocks) == min(256, count - first) * 4096, "Truncated IVFC blocks")
            for n in range(len(blocks) // 4096):
                digest = hashlib.sha256(blocks[n * 4096:(n + 1) * 4096]).digest()
                require(digest == hashes[(first + n) * 32:(first + n + 1) * 32], f"IVFC level {i} block {first + n} hash mismatch")
        results.append({"level": i, "blocks": count, "size": length, "offset": positions[i]})
    return {"levels": results, "data_offset": offset + positions[2], "data_size": levels[2][1]}


def safe_name(raw):
    require(len(raw) % 2 == 0, "Invalid RomFS UTF-16 name")
    name = raw.decode("utf-16-le")
    require(name and name not in (".", "..") and not any(c in name for c in "/\\\0:"), "Unsafe RomFS path")
    return name


def extract_romfs(stream, offset, size, destination):
    bounds(0, 0x28, size, "RomFS header")
    h = read_at(stream, offset, 0x28)
    require(u32(h, 0) == 0x28, "Invalid RomFS header")
    tables = []
    end = 0x28
    for at in (4, 12, 20, 28):
        pos, length = struct.unpack_from("<II", h, at)
        bounds(pos, length, size, "RomFS metadata")
        require(pos >= end, "Overlapping RomFS metadata")
        end = pos + length
        tables.append((pos, length))
    data_offset = u32(h, 36)
    require(end <= data_offset <= size, "Invalid RomFS data offset")
    directories = read_at(stream, offset + tables[1][0], tables[1][1])
    files = read_at(stream, offset + tables[3][0], tables[3][1])
    destination.mkdir()
    seen_dirs, seen_files, inventory = set(), set(), []
    pending = [(0, destination, None)]
    while pending:
        entry, path, parent = pending.pop()
        require(entry not in seen_dirs, "RomFS directory cycle")
        seen_dirs.add(entry)
        bounds(entry, 24, len(directories), "RomFS directory entry")
        ancestor, sibling, child, file_entry, _, name_size = struct.unpack_from("<6I", directories, entry)
        require(entry % 4 == 0 and name_size <= len(directories) - entry - 24, "RomFS directory name bounds")
        if parent is None:
            require(entry == 0 and name_size == 0 and sibling == 0xFFFFFFFF, "Invalid RomFS root")
        else:
            require(ancestor == parent, "RomFS directory parent mismatch")
            if sibling != 0xFFFFFFFF:
                pending.append((sibling, path, parent))
            path = path / safe_name(directories[entry + 24:entry + 24 + name_size])
            path.mkdir()  # Existing names, including case-fold collisions, fail closed.
        if child != 0xFFFFFFFF:
            pending.append((child, path, entry))
        while file_entry != 0xFFFFFFFF:
            require(file_entry not in seen_files, "RomFS file cycle")
            seen_files.add(file_entry)
            bounds(file_entry, 32, len(files), "RomFS file entry")
            ancestor, next_file, content_offset, length, _, name_size = struct.unpack_from("<IIQQII", files, file_entry)
            require(file_entry % 4 == 0 and ancestor == entry and name_size <= len(files) - file_entry - 32, "Invalid RomFS file metadata")
            name = safe_name(files[file_entry + 32:file_entry + 32 + name_size])
            require(content_offset <= size - data_offset and length <= size - data_offset - content_offset, "RomFS file outside data")
            target = path / name
            digest = hashlib.sha256()
            stream.seek(offset + data_offset + content_offset)
            remaining = length
            with target.open("xb") as output:
                while remaining:
                    chunk = stream.read(min(remaining, 1024 * 1024))
                    require(bool(chunk), "Truncated RomFS file")
                    output.write(chunk)
                    digest.update(chunk)
                    remaining -= len(chunk)
            inventory.append({"path": target.relative_to(destination).as_posix(), "size": length, "sha256": digest.hexdigest()})
            file_entry = next_file
    return sorted(inventory, key=lambda item: item["path"])


def extract_main(main, stage, manifest):
    """Extract an already validated, decrypted partition; no crypto code exists here."""
    with main.open("rb") as stream:
        h = read_at(stream, 0, 0x200)
        require(h[0x100:0x104] == b"NCCH" and h[0x18F] & 4, "Encrypted or invalid main partition")
        exheader = read_at(stream, 0x200, 0x800)
        require(hashlib.sha256(exheader).hexdigest() == manifest["exheader_full_sha256"], "ExHeader changed")
        (stage / "exheader.bin").write_bytes(exheader)
        ep, es = u32(h, 0x1A0) * 512, u32(h, 0x1A4) * 512
        bounds(ep, es, main.stat().st_size, "ExeFS")
        eh = read_at(stream, ep, 0x200)
        require(hashlib.sha256(eh).digest() == h[0x1C0:0x1E0], "ExeFS header changed")
        (stage / "exefs").mkdir()
        for i in range(10):
            entry = eh[i * 16:(i + 1) * 16]
            if not entry[:8].strip(b"\0"):
                continue
            name = entry[:8].split(b"\0", 1)[0].decode("ascii")
            require(name in (".code", "banner", "icon"), "Unexpected MH4U ExeFS file")
            pos, length = struct.unpack_from("<II", entry, 8)
            bounds(0x200 + pos, length, es, "ExeFS file")
            data = read_at(stream, ep + 0x200 + pos, length)
            require(hashlib.sha256(data).digest() == eh[0x1E0 - i * 32:0x200 - i * 32], "ExeFS file changed")
            if name == ".code" and manifest["code_compressed"]:
                data = decompress_blz(data, manifest["code_size"])
            with (stage / "exefs" / (name.lstrip(".") + ".bin")).open("xb") as output:
                output.write(data)
        rp, rs = u32(h, 0x1B0) * 512, u32(h, 0x1B4) * 512
        bounds(rp, rs, main.stat().st_size, "RomFS")
        hash_size = u32(h, 0x1B8) * 512
        bounds(0, hash_size, rs, "RomFS hash region")
        check_hash(stream, rp, hash_size, h[0x1E0:0x200], "RomFS header")
        ivfc = verify_ivfc(stream, rp, rs)
        require(0x60 + u32(read_at(stream, rp, 0x60), 8) <= hash_size, "IVFC master hashes not anchored in NCCH")
        inventory = extract_romfs(stream, ivfc["data_offset"], ivfc["data_size"], stage / "romfs")
    manifest["ivfc"] = ivfc
    manifest["validation"]["romfs_ivfc_tree"] = True
    return inventory


def prepare(image):
    image = image.resolve()
    require(image.is_relative_to(ROOT), "Image must already be inside this workspace")
    output = ROOT / ".local/game"
    require(not output.exists(), f"{output} already exists; preserve it or choose an explicit fresh workspace")
    with image.open("rb") as stream:
        before = image.stat()
        manifest = inspect_image(stream, before.st_size)
        manifest["source"] = {"path": str(image.relative_to(ROOT)), "size": before.st_size,
                              "sha256": hash_region(stream, 0, before.st_size)}
    manifest["extractor"] = {"name": "prepare_image.py Python standard library", "version": 1,
                             "decryption_supported": False}
    (ROOT / ".local").mkdir(exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix="game-staging-", dir=ROOT / ".local"))
    try:
        main = stage / "main.cxi"
        remaining = manifest["partition"]["size"]
        digest = hashlib.sha256()
        with image.open("rb") as source, main.open("wb") as target:
            source.seek(manifest["partition"]["offset"])
            while remaining:
                chunk = source.read(min(remaining, 1024 * 1024))
                require(bool(chunk), "Truncated partition while copying")
                target.write(chunk)
                digest.update(chunk)
                remaining -= len(chunk)
        manifest["cxi"] = {"path": "main.cxi", "size": main.stat().st_size, "sha256": digest.hexdigest()}
        print("Verifying IVFC and extracting game partition 0…", flush=True)
        inventory = extract_main(main, stage, manifest)
        code = stage / "exefs/code.bin"
        require(code.stat().st_size == manifest["code_size"], "Decompressed code size disagrees with ExHeader")
        manifest["code"] = {"path": "exefs/code.bin", "size": code.stat().st_size, "sha256": file_hash(code)}
        require(file_hash(stage / "exheader.bin") == manifest["exheader_full_sha256"], "Extracted ExHeader differs")
        require(bool(inventory), "RomFS extraction is empty")
        index = stage / "romfs-index.json"
        index.write_text(json.dumps(inventory, indent=2) + "\n")
        manifest["romfs"] = {"path": "romfs", "file_count": len(inventory), "total_bytes": sum(f["size"] for f in inventory),
                             "index_path": index.name, "index_sha256": file_hash(index)}
        after = image.stat()
        require((before.st_size, before.st_mtime_ns, before.st_ino) == (after.st_size, after.st_mtime_ns, after.st_ino), "Source image changed during extraction")
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        stage.rename(output)
    except BaseException:
        shutil.rmtree(stage)
        raise
    print(f"Ready: {output / 'manifest.json'}")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", nargs="?", type=Path)
    args = parser.parse_args()
    images = [args.image] if args.image else sorted(ROOT.glob("*.3ds"))
    require(len(images) == 1, "Expected exactly one workspace .3ds image")
    prepare(images[0])

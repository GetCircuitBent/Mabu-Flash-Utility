#!/usr/bin/env python3
"""Locate a file inside a /system partition dump (ext4 inode walk).

The /system analogue of scripts/locate_vendor_policy.py — same technique,
generalized to an arbitrary path and made multi-extent aware (bootanimation.zip
is much bigger than the sepolicy file locate_vendor_policy.py was built for,
so a single-extent assumption isn't safe here).

Usage: python find_system_file.py <system-dump.img> <path/inside/system> [system_start_lba_hex]
Example: python find_system_file.py system-head.img media/bootanimation.zip 0x18C000

Default /system start LBA is 0x18C000 (unit 2022010501476, confirmed via
`cat /sys/class/block/mmcblk1p11/start` over ADB, 2026-07-02). Re-derive per
unit — this has already been observed to drift (kendrick90/Mabu's notes used
0x18A000 for a different unit).
"""
import struct
import sys

SYSTEM_LBA = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0x18C000
img = open(sys.argv[1], "rb").read()
target_path = sys.argv[2].strip("/").split("/")

sb = img[1024:1024 + 1024]
assert struct.unpack_from("<H", sb, 0x38)[0] == 0xEF53, "not ext4 (bad magic)"
log_bs = struct.unpack_from("<I", sb, 0x18)[0]
BLK = 1024 << log_bs
inodes_per_grp = struct.unpack_from("<I", sb, 0x28)[0]
inode_size = struct.unpack_from("<H", sb, 0x58)[0] or 128
feat_incompat = struct.unpack_from("<I", sb, 0x60)[0]
feat_ro = struct.unpack_from("<I", sb, 0x64)[0]
desc_size = struct.unpack_from("<H", sb, 0xFE)[0] if (feat_incompat & 0x40) else 32
if desc_size == 0:
    desc_size = 32
META_CSUM = bool(feat_ro & 0x400)
gdt_block = 2 if BLK == 1024 else 1
print(f"block_size={BLK} inode_size={inode_size} inodes/grp={inodes_per_grp} "
      f"desc_size={desc_size} metadata_csum={'ON' if META_CSUM else 'OFF'}")


def inode_loc(num):
    g = (num - 1) // inodes_per_grp
    idx = (num - 1) % inodes_per_grp
    gd = img[gdt_block * BLK + g * desc_size: gdt_block * BLK + g * desc_size + desc_size]
    it_lo = struct.unpack_from("<I", gd, 0x08)[0]
    it_hi = struct.unpack_from("<I", gd, 0x28)[0] if desc_size > 32 else 0
    it_block = (it_hi << 32) | it_lo
    return it_block * BLK + idx * inode_size


def read_inode(num):
    b = inode_loc(num)
    if b + inode_size > len(img):
        return None, b
    return img[b:b + inode_size], b


def extents(ino):
    flags = struct.unpack_from("<I", ino, 0x20)[0]
    ib = ino[0x28:0x28 + 60]
    if not (flags & 0x80000):
        return None
    magic, n, _, depth, _ = struct.unpack_from("<HHHHI", ib, 0)
    if magic != 0xF30A or depth != 0:
        return None  # deep extent trees not handled — rare for a single file this size
    out = []
    for k in range(n):
        eb, el, shi, slo = struct.unpack_from("<IHHI", ib, 12 + k * 12)
        out.append((eb, el, (shi << 32) | slo))
    return out


def listdir(num):
    ino, _ = read_inode(num)
    if ino is None:
        return None
    out = []
    for _, ln, pb in (extents(ino) or []):
        for b in range(ln):
            start = (pb + b) * BLK
            if start + BLK > len(img):
                return None  # dump doesn't cover this directory's data block
            blk = img[start:start + BLK]
            pos = 0
            while pos + 8 <= len(blk):
                i, rl, nl, ft = struct.unpack_from("<IHBB", blk, pos)
                if rl == 0:
                    break
                if i and 0 < nl <= rl - 8:
                    out.append((i, blk[pos + 8:pos + 8 + nl].decode("latin1", "replace")))
                pos += rl
    return out


def child(parent, name):
    entries = listdir(parent)
    if entries is None:
        return None, "dump doesn't cover this directory's data — need a bigger/targeted dump"
    for i, n in entries:
        if n == name:
            return i, None
    return None, f"'{name}' not found among {[n for _, n in entries]}"


ino_no = 2  # root
for part in target_path:
    ino_no, err = child(ino_no, part)
    if ino_no is None:
        print(f"NOT FOUND at component '{part}': {err}")
        sys.exit(1)
print(f"inode = {ino_no}")

ino, ino_byte = read_inode(ino_no)
if ino is None:
    print("inode table entry outside dump — need a dump that covers this inode's block group")
    sys.exit(1)

size = struct.unpack_from("<I", ino, 0x04)[0]
print(f"i_size = {size} bytes")
ino_abs = SYSTEM_LBA * 512 + ino_byte
print(f"INODE_LBA = {ino_abs // 512} (0x{ino_abs // 512:X})   INODE_OFFSET = {ino_abs % 512}")

exts = extents(ino) or []
total_blocks = sum(el for _, el, _ in exts)
print(f"extents = {exts}  (total {total_blocks} blocks, {total_blocks * BLK} bytes allocated)")
for eb, el, pb in exts:
    abs_lba = (SYSTEM_LBA * 512 + pb * BLK) // 512
    nsect = el * (BLK // 512)
    print(f"  FILE_LBA = {abs_lba} (0x{abs_lba:X})   NSECT = {nsect}   (end LBA {abs_lba + nsect - 1})")

if len(exts) == 1:
    print("\nSingle extent -> same-block-count overwrite is safe if replacement fits in these blocks.")
else:
    print(f"\n{len(exts)} extents -> write each extent separately, in order, from the replacement")
    print("file's matching byte ranges. Do NOT treat this as one contiguous run.")

print("\nRoute decision:", "OK to hand-write extents (metadata_csum OFF)" if not META_CSUM
      else "metadata_csum ON -> verify csum handling before writing, or use the full-image reflash path")

#!/usr/bin/env python3
"""Plan a same-inode replacement of /system/media/bootanimation.zip.

Reads a /system partition head-dump (raw ext4), locates the file by directory
walk (reusing the same ext4 logic as find_system_file.py), and emits a WRITE
PLAN plus the exact byte payloads to flash via `rkdeveloptool wl`. It NEVER
touches the device -- it only reads the dump and writes plan files to a scratch
dir. The PowerShell -Branded phase executes the plan (with a plan-only preview
and post-write verify).

Safety checks (any failure -> non-zero exit, no plan written):
  exit 2  metadata_csum ON  -> i_size hand-edit unsafe; use full-image reflash.
  exit 3  located inode's i_size != expected stock size -> not the stock file
          (already branded? different build?) -- refuse rather than guess.
  exit 4  new zip bigger than the file's allocated extents -> won't fit.
  exit 5  not found / dump doesn't cover the needed metadata.

Usage:
  python stage_bootanim.py <system-dump.img> <new-boot.zip> <system_lba_hex> \
         <scratch_dir> <inode_number> [expected_stock_size]
  <inode_number> from on-device: stat -c %i /system/media/bootanimation.zip
  (using the inode directly skips the directory walk, so the dump only needs to
   cover the superblock + group descriptors + this inode -- not the dir blocks.)

Writes into <scratch_dir>: plan.json, inode-<lba>.bin (patched inode sector),
content-<n>.bin (per-extent payload, sector-padded).
"""
import json
import os
import struct
import sys

if len(sys.argv) < 6:
    print(__doc__)
    sys.exit(1)

DUMP = sys.argv[1]
NEWZIP = sys.argv[2]
SYSTEM_LBA = int(sys.argv[3], 16)
SCRATCH = sys.argv[4]
INODE_NO = int(sys.argv[5])                                      # from on-device: stat -c %i
EXPECT_SIZE = int(sys.argv[6]) if len(sys.argv) > 6 else 1870133  # stock bootanimation.zip

TARGET = "media/bootanimation.zip"
SECT = 512

img = open(DUMP, "rb").read()
newzip = open(NEWZIP, "rb").read()
os.makedirs(SCRATCH, exist_ok=True)

sb = img[1024:1024 + 1024]
if struct.unpack_from("<H", sb, 0x38)[0] != 0xEF53:
    print("ERROR: not ext4 (bad superblock magic) -- wrong dump/offset")
    sys.exit(5)
log_bs = struct.unpack_from("<I", sb, 0x18)[0]
BLK = 1024 << log_bs
inodes_per_grp = struct.unpack_from("<I", sb, 0x28)[0]
inode_size = struct.unpack_from("<H", sb, 0x58)[0] or 128
feat_incompat = struct.unpack_from("<I", sb, 0x60)[0]
feat_ro = struct.unpack_from("<I", sb, 0x64)[0]
desc_size = struct.unpack_from("<H", sb, 0xFE)[0] if (feat_incompat & 0x40) else 32
desc_size = desc_size or 32
META_CSUM = bool(feat_ro & 0x400)
gdt_block = 2 if BLK == 1024 else 1


def inode_byte(num):
    g = (num - 1) // inodes_per_grp
    idx = (num - 1) % inodes_per_grp
    gd = img[gdt_block * BLK + g * desc_size: gdt_block * BLK + g * desc_size + desc_size]
    it_lo = struct.unpack_from("<I", gd, 0x08)[0]
    it_hi = struct.unpack_from("<I", gd, 0x28)[0] if desc_size > 32 else 0
    return ((it_hi << 32) | it_lo) * BLK + idx * inode_size


def read_inode(num):
    b = inode_byte(num)
    return (img[b:b + inode_size] if b + inode_size <= len(img) else None), b


def extents(ino):
    flags = struct.unpack_from("<I", ino, 0x20)[0]
    ib = ino[0x28:0x28 + 60]
    if not (flags & 0x80000):
        return None
    magic, n, _, depth, _ = struct.unpack_from("<HHHHI", ib, 0)
    if magic != 0xF30A or depth != 0:
        return None
    out = []
    for k in range(n):
        eb, el, shi, slo = struct.unpack_from("<IHHI", ib, 12 + k * 12)
        out.append((el, (shi << 32) | slo))  # (len_blocks, phys_block)
    return out


def listdir(num):
    ino, _ = read_inode(num)
    if ino is None:
        return None
    out = []
    for ln, pb in (extents(ino) or []):
        for b in range(ln):
            start = (pb + b) * BLK
            if start + BLK > len(img):
                return None
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
        return None
    for i, n in entries:
        if n == name:
            return i
    return None


# --- inode supplied directly (from on-device `stat -c %i`) -- NO directory walk,
#     so we do NOT depend on root/media directory-data blocks being in the dump.
#     Only the superblock + group descriptors + this inode need to be covered, and
#     a low inode (e.g. 823) sits in block group 0's inode table near the fs start.
ino_no = INODE_NO
ino, ino_b = read_inode(ino_no)
if ino is None:
    print("ERROR: inode outside dump.")
    sys.exit(5)

i_size = struct.unpack_from("<I", ino, 0x04)[0]
exts = extents(ino) or []
alloc = sum(el for el, _ in exts) * BLK
print(f"located inode={ino_no} i_size={i_size} extents={len(exts)} alloc={alloc} "
      f"metadata_csum={'ON' if META_CSUM else 'OFF'}")

if META_CSUM:
    print("ERROR(2): metadata_csum ON -- i_size hand-edit would invalidate the inode "
          "checksum. Use the full-image reflash path, not this phase.")
    sys.exit(2)
if i_size != EXPECT_SIZE:
    print(f"ERROR(3): located i_size={i_size} != expected stock {EXPECT_SIZE}. "
          "This is not the stock bootanimation.zip (already branded? different build?). "
          "Refusing to write.")
    sys.exit(3)
if len(newzip) > alloc:
    print(f"ERROR(4): new zip {len(newzip)} B > allocated {alloc} B. Won't fit.")
    sys.exit(4)

# --- plan the inode i_size patch (low 32 bits at inode+0x04; <4GB so i_size_high stays 0) ---
field_abs = SYSTEM_LBA * SECT + ino_b + 0x04          # device byte of i_size low
inode_writes = []
# patch may touch 1 or 2 sectors if it straddles a boundary (rare)
for sec in sorted({(field_abs + k) // SECT for k in range(4)}):
    dump_off = sec * SECT - SYSTEM_LBA * SECT
    secbuf = bytearray(img[dump_off:dump_off + SECT])
    if len(secbuf) != SECT:
        print("ERROR(5): inode sector not covered by dump.")
        sys.exit(5)
    for k in range(4):
        babs = field_abs + k
        if sec * SECT <= babs < sec * SECT + SECT:
            secbuf[babs - sec * SECT] = (len(newzip) >> (8 * k)) & 0xFF
    fn = os.path.join(SCRATCH, f"inode-{sec}.bin")
    open(fn, "wb").write(secbuf)
    inode_writes.append({"lba": sec, "file": os.path.abspath(fn)})

# --- plan the content writes: fill extents in order until new content is exhausted ---
content_writes = []
off = 0
for idx, (el, pb) in enumerate(exts):
    if off >= len(newzip):
        break
    dev_lba = (SYSTEM_LBA * SECT + pb * BLK) // SECT
    cap = el * BLK
    take = min(cap, len(newzip) - off)
    chunk = newzip[off:off + take]
    if len(chunk) % SECT:                              # pad final partial sector
        chunk = chunk + b"\x00" * (SECT - len(chunk) % SECT)
    fn = os.path.join(SCRATCH, f"content-{idx}.bin")
    open(fn, "wb").write(chunk)
    content_writes.append({"lba": dev_lba, "file": os.path.abspath(fn), "nsect": len(chunk) // SECT})
    off += take

plan = {
    "target": TARGET,
    "inode": ino_no,
    "old_size": i_size,
    "new_size": len(newzip),
    "metadata_csum": META_CSUM,
    "first_content_lba": content_writes[0]["lba"],
    "inode_writes": inode_writes,
    "content_writes": content_writes,
}
open(os.path.join(SCRATCH, "plan.json"), "w").write(json.dumps(plan, indent=2))
print(f"PLAN OK: {len(content_writes)} content write(s), {len(inode_writes)} inode sector(s), "
      f"new_size={len(newzip)} (was {i_size}). plan.json written.")

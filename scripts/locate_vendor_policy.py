#!/usr/bin/env python3
"""Locate /vendor/etc/selinux/precompiled_sepolicy in a /vendor partition dump.

Usage: python locate_vendor_policy.py <vendor-dump.img> [vendor_start_lba_hex]
Prints inode #, i_size, data-block absolute eMMC LBAs, inode absolute LBA+offset,
and metadata_csum status. Default vendor start LBA = 0x592000.
"""
import sys, struct

VENDOR_LBA = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0x592000
img = open(sys.argv[1], 'rb').read()

# --- superblock (at partition byte 1024) ---
sb = img[1024:1024+1024]
assert struct.unpack_from('<H', sb, 0x38)[0] == 0xEF53, "not ext4 (bad magic)"
log_bs        = struct.unpack_from('<I', sb, 0x18)[0]
BLK           = 1024 << log_bs
inodes_per_grp= struct.unpack_from('<I', sb, 0x28)[0]
inode_size    = struct.unpack_from('<H', sb, 0x58)[0] or 128
feat_incompat = struct.unpack_from('<I', sb, 0x60)[0]
feat_ro       = struct.unpack_from('<I', sb, 0x64)[0]
desc_size     = struct.unpack_from('<H', sb, 0xFE)[0] if (feat_incompat & 0x40) else 32
if desc_size == 0: desc_size = 32
META_CSUM     = bool(feat_ro & 0x400)
gdt_block     = 2 if BLK == 1024 else 1
print(f"block_size={BLK} inode_size={inode_size} inodes/grp={inodes_per_grp} "
      f"desc_size={desc_size} metadata_csum={'ON' if META_CSUM else 'OFF'}")

def inode_loc(num):
    g   = (num - 1) // inodes_per_grp
    idx = (num - 1) %  inodes_per_grp
    gd  = img[gdt_block*BLK + g*desc_size : gdt_block*BLK + g*desc_size + desc_size]
    it_lo = struct.unpack_from('<I', gd, 0x08)[0]
    it_hi = struct.unpack_from('<I', gd, 0x28)[0] if desc_size > 32 else 0
    it_block = (it_hi << 32) | it_lo
    byte = it_block*BLK + idx*inode_size
    return byte

def read_inode(num):
    b = inode_loc(num)
    return img[b:b+inode_size], b

def extents(ino):
    flags = struct.unpack_from('<I', ino, 0x20)[0]
    ib = ino[0x28:0x28+60]
    if not (flags & 0x80000): return None
    magic, n, _, depth, _ = struct.unpack_from('<HHHHI', ib, 0)
    if magic != 0xF30A or depth != 0: return None   # deep trees: rare for this file
    out = []
    for k in range(n):
        eb, el, shi, slo = struct.unpack_from('<IHHI', ib, 12 + k*12)
        out.append((eb, el, (shi<<32)|slo))
    return out

def listdir(num):
    ino, _ = read_inode(num)
    out = []
    for _, ln, pb in (extents(ino) or []):
        for b in range(ln):
            blk = img[(pb+b)*BLK:(pb+b)*BLK+BLK]
            pos = 0
            while pos + 8 <= len(blk):
                i, rl, nl, ft = struct.unpack_from('<IHBB', blk, pos)
                if rl == 0: break
                if i and 0 < nl <= rl-8:
                    out.append((i, blk[pos+8:pos+8+nl].decode('latin1','replace')))
                pos += rl
    return out

def child(parent, name):
    for i, n in listdir(parent):
        if n == name: return i
    return None

ino_no = 2  # root
for part in ('etc', 'selinux', 'precompiled_sepolicy'):
    ino_no = child(ino_no, part)
    if ino_no is None:
        print(f"NOT FOUND at component '{part}'"); sys.exit(1)
print(f"inode = {ino_no}")

ino, ino_byte = read_inode(ino_no)
size = struct.unpack_from('<I', ino, 0x04)[0]
print(f"i_size = {size} bytes")
ino_abs = VENDOR_LBA*512 + ino_byte
print(f"INODE_LBA = {ino_abs//512} (0x{ino_abs//512:X})   INODE_OFFSET = {ino_abs%512}")

exts = extents(ino) or []
total_blocks = sum(el for _, el, _ in exts)
print(f"extents = {exts}  (total {total_blocks} blocks, {total_blocks*BLK} bytes allocated)")
for eb, el, pb in exts:
    abs_lba = (VENDOR_LBA*512 + pb*BLK)//512
    nsect   = el*(BLK//512)
    print(f"  FILE_LBA = {abs_lba} (0x{abs_lba:X})   NSECT = {nsect}   "
          f"(end LBA {abs_lba+nsect-1})")
if len(exts) == 1:
    print("\nSingle extent -> Route 1 inputs: FILE_LBA + NSECT above, INODE_LBA/OFFSET above.")
else:
    print("\nMultiple extents -> prefer Route 2 (reflash), or write each extent.")
print("\nRoute decision:", "Route 1 OK (metadata_csum OFF)" if not META_CSUM
      else "Use Route 2 (metadata_csum ON -> don't hand-edit the inode)")

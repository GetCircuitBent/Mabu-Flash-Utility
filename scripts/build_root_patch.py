#!/usr/bin/env python3
"""Build the persistent-root adbd patch sector (adbd_main privilege-drop bypass).

Reproduces firmware/patches/adbd-rootdrop-patched.bin from
firmware/originals/adbd.bin. Run this to re-derive the patch on a different
adbd build (offsets WILL differ — the disassembly-driven search below finds
the drop block rather than hardcoding a byte offset).

Technique: adbd_main() decides whether to drop from root (uid 0) to AID_SHELL
(2000) via an inlined should_drop_privileges(). On a "user" build it drops.
We locate the drop block (the one calling minijail_change_uid with 0x7d0) and
overwrite its entry instruction with an unconditional branch to the keep-root
path (the minijail_enter that runs WITHOUT change_uid/change_gid). Result:
adbd stays uid 0.

Requires: pyelftools, capstone, keystone-engine.
"""
import os
import struct
import sys

from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB
from elftools.elf.elffile import ELFFile
from keystone import Ks, KS_ARCH_ARM, KS_MODE_THUMB

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADBD = os.path.join(ROOT, "firmware", "originals", "adbd.bin")

# eMMC mapping: adbd file sector 0 -> this absolute LBA. Verified against the
# existing authreq (file off 0xD311C -> LBA 1696240) and authinit (0x1C438 ->
# LBA 1694778) patches: both imply adbd sector 0 = LBA 1694552.
ADBD_SECTOR0_LBA = 1694552

# Manually resolved for the validated H7R 8.1 adbd build. Re-derive per build.
DROP_BLOCK_ENTRY = 0xBAA4   # `bl is_device_unlocked` at the drop-block head
KEEP_ROOT_TARGET = 0xBBBE   # minijail_enter path with no change_uid/change_gid


def vaddr_to_off(elf, vaddr):
    for seg in elf.iter_segments():
        if seg["p_type"] != "PT_LOAD":
            continue
        s = seg["p_vaddr"]
        if s <= vaddr < s + seg["p_filesz"]:
            return seg["p_offset"] + (vaddr - s)
    return None


def main():
    data = open(ADBD, "rb").read()
    elf = ELFFile(open(ADBD, "rb"))

    file_off = vaddr_to_off(elf, DROP_BLOCK_ENTRY)
    print(f"drop-block entry vaddr=0x{DROP_BLOCK_ENTRY:X} -> file off 0x{file_off:X}")

    md = Cs(CS_ARCH_ARM, CS_MODE_THUMB)
    orig4 = data[file_off:file_off + 4]
    orig_ins = next(md.disasm(orig4, DROP_BLOCK_ENTRY))
    print(f"original: {orig_ins.mnemonic} {orig_ins.op_str}  ({orig4.hex()})")
    if orig_ins.mnemonic != "bl":
        sys.exit("ERROR: expected a `bl` at the drop-block entry — offsets have drifted, re-analyze.")

    ks = Ks(KS_ARCH_ARM, KS_MODE_THUMB)
    enc, _ = ks.asm(f"b.w #0x{KEEP_ROOT_TARGET:X}", addr=DROP_BLOCK_ENTRY)
    new4 = bytes(enc)
    new_ins = next(md.disasm(new4, DROP_BLOCK_ENTRY))
    print(f"patched:  {new_ins.mnemonic} {new_ins.op_str}  ({new4.hex()})")
    assert new_ins.mnemonic in ("b", "b.w") and int(new_ins.op_str.strip("#"), 0) == KEEP_ROOT_TARGET

    sector = file_off // 512
    bis = file_off % 512
    lba = ADBD_SECTOR0_LBA + sector
    assert bis + 4 <= 512, "patch spans two sectors — handle both"

    sect = bytearray(data[sector * 512: sector * 512 + 512])
    sect[bis:bis + 4] = new4

    open(os.path.join(ROOT, "firmware", "originals", "adbd-rootdrop-orig.bin"), "wb").write(
        data[sector * 512: sector * 512 + 512])
    open(os.path.join(ROOT, "firmware", "patches", "adbd-rootdrop-patched.bin"), "wb").write(bytes(sect))

    print(f"\nfile sector {sector}, byte-in-sector {bis}")
    print(f"WRITE LBA = {lba}  (add to liberate-mabu.ps1 -KeepRoot)")
    print("wrote firmware/originals/adbd-rootdrop-orig.bin, firmware/patches/adbd-rootdrop-patched.bin")


if __name__ == "__main__":
    main()

# Deploying the GCB Boot Animation

> **Automated now (2026-07-07):** `flash-mabu.ps1 -Branded` does all of the below —
> reads the per-unit `/system` LBA over adb, dumps the head, runs
> `scripts/stage_bootanim.py` to locate + verify + plan the write, then flashes and
> read-verifies. **Run `-BrandedPlanOnly` first** to preview the plan with zero
> device writes. The planner refuses unless the located inode's `i_size` equals the
> stock size (proves it found the real file) and `metadata_csum` is OFF. The manual
> steps below remain the reference / fallback. NOT yet hardware-validated — do the
> plan-only preview on the first real unit.



Replaces `/system/media/bootanimation.zip` on a **confirmed-liberated** unit
via the raw-eMMC same-size-overwrite technique (Path A, FLASH-A-NEW-MABU.md
Section 6A) — same core technique as the validated Tier 2 SELinux patch, but
`bootanimation.zip` is ~4.5x bigger than the sepolicy file and almost
certainly multi-extent, so this walks each extent instead of assuming one.

**Prerequisite: the internal USB programming harness must be physically
connected to the flashing PC.** WiFi ADB alone cannot do this — the write
goes through the Rockchip Loader (`rkdeveloptool`), which only speaks USB.

## What's staged and ready (2026-07-02, unit 2022010501476)
- `bootanimation.zip` — 1,355,264 B (built by `make_bootanim.py`; brand-colored
  sparkles around the GCB text logo on Bluewood 900 `#1A242D`), well under the
  stock file's 1,870,133 B.
- `/system` start LBA confirmed live via ADB: **`0x18C000`** (`cat
  /sys/class/block/mmcblk1p11/start`) — do NOT reuse kendrick90/Mabu's
  `0x18A000`, that was a different unit.
- `scripts/find_system_file.py` — the `/system` analogue of
  `scripts/locate_vendor_policy.py`, multi-extent aware.
- SHA-256 of the built zip: `da1a04e61655560acc16d51cc98bd4eb6afa175551ebe5cf74695391273e1499`

## Steps

**1. Confirm liberation hasn't regressed** (WiFi ADB, no harness needed yet):
```powershell
adb connect 192.168.0.180:5555
adb -s 192.168.0.180:5555 shell getprop ro.boot.veritymode   # expect: disabled
adb -s 192.168.0.180:5555 shell "pm list packages | grep -iE 'esper|shoonya'"  # expect: empty
```

**2. Catch Loader.** With ADB reachable, `adb reboot loader` is instant
(Section 3, "Optimal"). Then confirm WinUSB binding:
```powershell
adb -s 192.168.0.180:5555 reboot loader
.\tools\rkdeveloptool\rkdeveloptool.exe ld     # expect Vid=0x2207,Pid=0x320a Loader
```
If bound to `rockusb.sys` not WinUSB, Zadig it (Section 3, "Driver Binding").

**3. Targeted dump — do not attempt a full 2GB dump.** `/system` hits the
documented 28MB Loader read-wedge (`dump-system-cycled.ps1` exists for a full
cycled dump if ever needed, but it's slow and we don't need the whole
partition). We only need enough to walk root -> `media` -> `bootanimation.zip`:
the superblock + inode table region, plus root's and `media`'s directory data
blocks. Start with a generous head dump and let `find_system_file.py` tell you
if it's insufficient:
```powershell
.\tools\rkdeveloptool\rkdeveloptool.exe rl 0x18C000 57344 assets\bootanimation\scratch\system-head.img
# 57344 sectors = 28 MiB, right at the read-wedge ceiling
```
Run the locator:
```powershell
python scripts\find_system_file.py assets\bootanimation\scratch\system-head.img media/bootanimation.zip 0x18C000
```
- If it reports `NOT FOUND ... dump doesn't cover this directory's data`, the
  `media` dir or `bootanimation.zip`'s inode/data lives outside the first 28MB
  — dump a second targeted region (power-cycle, re-catch Loader, dump a
  different offset) the same way `find-esper-files.py` used a combined
  `system.img` + `system-etc-combined.img`. Don't guess the offset; the script
  tells you what's missing.
- Record the printed `extents = [...]` list and every `FILE_LBA .. NSECT` line.

**4. If multiple extents (expected for this file size): read-verify each
extent BEFORE writing anything.**
```powershell
.\tools\rkdeveloptool\rkdeveloptool.exe rl <FILE_LBA_1> <NSECT_1> assets\bootanimation\scratch\readback-1.bin
# repeat per extent
```
Concatenate the extent reads in extent order and confirm the result matches
the **original stock** `bootanimation.zip` (pull it once beforehand over WiFi
ADB and hash it, or compare byte-for-byte). This confirms the located extents
are correct before any write touches disk — the guide's Tier 2 process did
exactly this for the single-extent sepolicy case; do it per-extent here.

**5. Patch the inode's `i_size` field — required, not optional.** The new zip
(1,355,264 B) is 514,869 B smaller than the original (1,870,133 B). Two ways
to close that gap were considered and rejected:
- *Pad the replacement file with trailing zeros to the original size* — breaks
  zip parsing. Readers locate the End-Of-Central-Directory record by scanning
  only the **last 64KB** of the file (the EOCD comment-length field caps at
  65,535 B); our gap is 8x that, so the real EOCD would sit far outside the
  scan window.
- *Leave `i_size` at the original value and only overwrite the leading
  blocks* — the filesystem would still report the file as 1,870,133 B, so
  reads would return our new content followed by ~515KB of **stale bytes from
  the old animation** that we never touched. Same corruption, different cause.

So: **patch `i_size` in the inode itself** to the new file's real size. This
touches one 4-byte field (offset `0x04` in the 256-byte inode, from
`find_system_file.py`'s reported `INODE_LBA`/`INODE_OFFSET`) — a smaller,
more surgical edit than rewriting content, and it means we only need to write
as many data blocks as the new content actually needs (331 blocks / 1.29MB),
**not** touch the remaining ~126 blocks of the original file's extents at
all. Those blocks stay allocated to this inode (wasted, harmless) but are
never read once `i_size` caps logical length — no extent-tree or block-bitmap
changes needed.

**If `metadata_csum` is ON** (the script reports this), the inode has a
checksum covering its fields — editing `i_size` without recomputing that
checksum will make the inode invalid. Don't hand-edit in that case; use the
full-image reflash path (Section 6A, Path B) instead.

```powershell
# 5a. Read the inode's block, patch bytes [INODE_OFFSET+0x04 .. +0x08) to the
#     new size (little-endian u32), write the block back:
.\tools\rkdeveloptool\rkdeveloptool.exe rl <INODE_LBA> 1 assets\bootanimation\scratch\inode-block.bin
# (edit inode-block.bin at the right offset — e.g. a small Python helper,
#  not included here since exact offset depends on which sector within the
#  block INODE_OFFSET lands in)
.\tools\rkdeveloptool\rkdeveloptool.exe wl <INODE_LBA> assets\bootanimation\scratch\inode-block-patched.bin

# 5b. Write only the blocks the new content needs, into the FIRST extent(s)
#     in order (331 blocks total for 1,355,264 B) — stop once the new
#     content is exhausted, leave any remaining original extents untouched:
.\tools\rkdeveloptool\rkdeveloptool.exe wl <FILE_LBA_1> assets\bootanimation\scratch\part-1.bin
# continue into extent 2+ only if extent 1 doesn't cover all 331 blocks
```

**6. Read-verify**: re-read the patched inode block and confirm `i_size` now
reads 1,355,264, and re-read the written data blocks and confirm they match
the new zip's bytes.

**7. Reboot and visually confirm.**
```powershell
.\tools\rkdeveloptool\rkdeveloptool.exe rd
```
Watch the tablet boot — GCB logo + sparkles should play instead of the wavy
leaf.

## If anything looks wrong before writing
Stop. Re-run step 3/4 with a different dump region rather than guessing.
Nothing is destructive until step 5's first `wl`.

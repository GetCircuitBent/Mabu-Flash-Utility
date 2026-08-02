# Mabu Flash Guide: Permanent Direct Serial Access (Delete the Motor Bridge)

> **Goal of this guide:** make the Mabu app able to open `/dev/ttyS1` (the motor
> board) **directly**, by adding one rule to the device's SELinux policy via a
> one-time Rockchip Loader session. After this, the TCP "motor bridge" and the
> in-app ADB bridge can be **deleted entirely**; the app talks to the motors
> the same way the original factory app did.
>
> **Audience:** an operator (or agent) with the **internal USB harness connected**
> and the device catchable in Rockchip Loader. It is written cold-start; it does
> not assume you read any other doc, but it reuses the proven tooling in
> `scripts/` and `firmware/`.
>
> Companion docs: [`MABU_MOTOR_GUIDE.md`](../MABU_MOTOR_GUIDE.md) (protocol/motors),
> [`guides/MABU_BUILD_GUIDE.md`](MABU_BUILD_GUIDE.md) (app build/deploy),
> [`README.md`](../README.md) (liberation procedure), [`selinux/`](../selinux/) (the rule).

---

## 0. Plain-Language Summary (Read This First)

Think of the motor wire `/dev/ttyS1` as a **door**. The normal lock is wide open,
but there's a **security guard called SELinux** who checks ID badges:

- Apps you install get an **"untrusted_app"** badge. The guard's rulebook has **no
  line** allowing that badge through the motor door → the app is **denied**.
- The **`adb` shell** has a **"shell"** badge, which the rulebook **does** allow.

That mismatch is the *entire reason the motor bridge exists*: the bridge is a
shell-badge helper that stands at the door and relays the app's motor commands
through. It works, but it's flaky (must be restarted every boot, drops, jams if
two run at once).

**This guide adds one line to the guard's rulebook** so the app's own badge is
allowed through the door:

```
allow untrusted_app serial_device:chr_file { open read write getattr ioctl };
```

We can't add that line while Android is running (it needs root, which this unit
doesn't have). But we **can** edit the rulebook file directly on the flash chip
using the same Rockchip Loader tool that was used to liberate the device. One
harness session, one file changed, and the bridge is gone forever.

**Why this is safe-ish:** it does **not** touch `boot.img` (the known brick zone:
see §8), it only changes one file on the `/vendor` partition, and we keep the
original bytes so it can be reverted in one command (§7).

---

## 1. The Exact Problem, Technically

- Device: **Rockchip RK3288**, board `HRA7_RK3288W_V1.2_2021.10.15`, Android
  **8.1.0** (`user` build, `release-keys`), security patch 2018-09-05.
- `/dev/ttyS1` carries SELinux label `u:object_r:serial_device:s0`.
- The app process runs in domain `u:r:untrusted_app:s0` (confirmed by the recorded
  denial below). Stock policy has **no** `allow untrusted_app serial_device` rule.
- Recorded denial (from `selinux/README.md`):
  ```
  avc: denied { getattr } for path="/dev/ttyS1"
    scontext=u:r:untrusted_app:s0:c512,c768
    tcontext=u:object_r:serial_device:s0
    tclass=chr_file permissive=0          <-- permissive=0 means ENFORCING
  ```
- **Important correction to older notes:** SELinux on this unit is **ENFORCING**,
  not permissive. The liberation set `androidboot.selinux=permissive` in the
  kernel command line, but on a `user` build Android's `init` **ignores** that and
  forces enforcing at boot. (The `androidboot.veritymode=disabled` half of that
  same patch *did* take effect, which is why `/system` and `/vendor` can be
  edited offline. Only the SELinux half was overridden.)
- The **active** binary policy at runtime is **`/vendor/etc/selinux/precompiled_sepolicy`**
  (confirmed in `notes/HANDOFF.md`, session 2026-05-25, patching the `/system`
  text policy files had *no* effect; the precompiled binary on `/vendor` is what
  the kernel loads). **That file is our target.**

**Why editing the file works at boot:** on Android 8.1 split-policy, `init` uses
`/vendor/etc/selinux/precompiled_sepolicy` directly **if** the hash file
`/vendor/etc/selinux/plat_sepolicy_and_mapping.sha256` still matches the
`/system` plat CIL inputs. We are **not** changing any `/system` CIL files, so
that hash still matches and our patched binary loads as-is. (Worst case, if init
ever recompiled from CIL instead, our patch would simply be **ignored**; the
device still boots normally. It is not a brick path. See §8.)

---

## 2. Constants and Facts You'll Need

| Thing | Value |
|---|---|
| SoC / board | RK3288 / `HRA7_RK3288W_V1.2_2021.10.15` |
| Loader USB ID | **VID 0x2207 / PID 0x320A** (appears ~10 s on every power-on; any `rkdeveloptool` command latches it) |
| `/vendor` partition start LBA | **`0x592000`** (decimal 5,840,896) |
| `/vendor` partition size | `0x80000` sectors = **256 MB** |
| Target file | `/vendor/etc/selinux/precompiled_sepolicy` |
| Policy format | kernel binary policydb, **version 30**, MLS, confirmed patchable |
| The rule to add | `allow untrusted_app serial_device:chr_file { open read write getattr ioctl };` |
| App SELinux domain | `untrusted_app` (per the recorded denial) |
| eMMC sector size | 512 bytes |
| ext4 block size | 4096 bytes (confirm from superblock, §B1) |

**OFF-LIMITS:** `boot.img` (boot partition LBA `0x20000`). Repacking it bricks to
recovery: proven twice (`notes/HANDOFF.md` finding #4). This guide never touches it.

---

## 3. Prerequisites / Setup (One-Time, on the PC)

**Two commands, one manual step; then every Mabu is a single command forever.**
Clone the repo and run from its root:

```powershell
gh repo clone GetCircuitBent/Mabu-Flash-Utility
cd Mabu-Flash-Utility
.\scripts\install-tools.ps1
.\scripts\install-android-driver.ps1
```

`install-tools.ps1` handles: rkdeveloptool (hash-pinned download), Zadig, WSL
`sepolicy-inject` build, and setools. Run it once; it's idempotent.

`install-android-driver.ps1` patches the Google Android USB driver INF to recognise
VID 0x2207 / PID 0x0006 (the Mabu in Android mode), then opens Device Manager and
walks you through the one manual click. **This step is required**: without it, USB
ADB won't see the device after liberation and `flash.ps1` will time out
waiting for ADB. After this driver is installed it persists across reboots.

After both scripts succeed:

1. **Bind WinUSB to the Loader (first Mabu only).** Get the device into Loader
   mode (power-cycle and catch the ~10 s window, OR `adb shell reboot loader` if
   ADB is already working), then open Zadig:
   ```powershell
   .\scripts\bind-winusb.ps1   # launches Zadig with instructions
   ```
   In Zadig: **Options → List All Devices** (check), **Options → Ignore Hubs or
   Composite Parents** (uncheck). In the dropdown, find the entry whose USB ID is
   **`2207 320A`**; it will appear as **"Unknown Device"** (no name) because no
   driver is bound yet. Confirm the USB ID matches before clicking **Install
   Driver** (target: WinUSB). Windows remembers this binding; only needed once
   per PC. If ADB is working, the device stays in Loader indefinitely so there is
   no time pressure.

2. **Flash.** Every Mabu, every time, one command:
   ```powershell
   .\scripts\flash.ps1
   ```
   The script detects device state, runs liberation, app install, and the SELinux
   motor patch end-to-end, and stops with a clear message if anything fails.

> **Catching the Loader:** power the unit OFF fully (PWRON held >7 s if needed),
> then power on; within ~10 s run `rkdeveloptool ld`; it should report
> `Vid=0x2207,Pid=0x320a...Loader`. If the device already booted to Android, you
> can re-enter Loader cleanly over WiFi ADB with `adb shell reboot loader`
> (no physical button needed; confirmed in `notes/HANDOFF.md`).

---

## 4. Phase A: Offline Prep (NO Device Attached; Do This First)

This is the safe part. We produce and verify the patched policy on the PC before
the harness ever touches the robot.

### Phase A Status: Already Verified (2026-06-01)

- `selinux/sepolicy.bin` (a copy of the device's policy, 299,979 bytes) is a valid
  **version-30 kernel policydb** (header magic `8c ff 7c f9`, vers `1e`).
- The three names the rule references are all present in that policy:
  `untrusted_app` (×9), `serial_device` (×1), `chr_file` (×1). **The rule will
  inject cleanly: no missing-type risk.**

> ⚠️ `selinux/sepolicy.bin` was pulled on 2026-05-28. Before relying on it for the
> real write, **re-pull the live policy** during the session and diff it (§B1),
> in case firmware drifted. The patch procedure is identical either way.

### A1. Install the Policy Tools in WSL

**`install-tools.ps1` handles this automatically**: it installs `libsepol-dev`,
`build-essential`, `setools` in WSL and compiles `tools/sepolicy-inject.c` into
`/usr/local/bin/sepolicy-inject`. If you ran that script successfully, skip to A2.

Manual fallback (if install-tools.ps1 failed):
```powershell
wsl -d Ubuntu -u root -- apt-get install -y libsepol-dev build-essential setools
wsl -d Ubuntu -u root -- gcc -o /usr/local/bin/sepolicy-inject `
    'tools/sepolicy-inject.c' /usr/lib/x86_64-linux-gnu/libsepol.a
```

Note: libsepol 3.x (Ubuntu 22.04+) no longer exports internal policydb symbols
from the shared library. The compile command links against `libsepol.a` directly.

### A2. Inject the Rule

```bash
# Work in a copy; never edit sepolicy.bin in place.
cp selinux/sepolicy.bin /tmp/sepolicy.orig.bin

# sepolicy-inject is built by install-tools.ps1 and lives at /usr/local/bin/
sepolicy-inject /tmp/sepolicy.orig.bin /tmp/sepolicy.patched.bin
# Output: "Inserted new AV rule." + "Done -> /tmp/sepolicy.patched.bin"
# (If the rule already exists it prints "Rule already exists; ORing in new perms.", also fine.)
```

### A3. Verify the Patch (Must Pass Before You Go near the Device)

```bash
# 1) The rule is now present:
sesearch --allow -s untrusted_app -t serial_device -c chr_file /tmp/sepolicy.patched.bin
#    expected: allow untrusted_app serial_device:chr_file { open read write getattr ioctl };

# 2) Still a valid v30 policy (header unchanged):
xxd -l 20 /tmp/sepolicy.patched.bin     # bytes 16-19 should still be 1e 00 00 00

# 3) Note the new size (used to decide Route 1 vs Route 2):
stat -c '%s' /tmp/sepolicy.patched.bin  # e.g. ~300,0xx bytes (a few bytes larger)
```

Record the **patched size**. Adding one rule typically grows the file by tens of
bytes, well within one 4 KB block of slack; this matters for Route 1.

### A4. Stage the Locator Script

Save the script in [§9 Appendix A](#appendix-a--locate_vendor_policypy) as
`scripts/locate_vendor_policy.py`. You will run it during the session on a dump of
`/vendor` to find the file's exact location. (Dry-run it offline against any ext4
image you have to confirm it executes.)

---

## 5. Phase B: Harness Session (the Actual Write)

> Connect the harness, catch the Loader (§3). Then:

### B1. Re-Pull the Live Policy + Confirm Partition Basics

Dump a chunk of `/vendor` big enough to contain its ext4 metadata and the
`etc/selinux` directory + the policy file. The auto-cycled dumper handles the
Loader read-wedge for you (it dumps in safe batches and re-enters Loader over
WiFi ADB between batches):

```powershell
# Adapt dump-system-cycled.ps1 for /vendor: PartitionStartLBA=0x592000, cap size.
.\scripts\dump-system-cycled.ps1 -Name vendor-full -PartitionStartLBA 0x592000 `
    -TotalMB 256 -WifiAdb 192.168.0.180:5555 -StartFresh
# Output: firmware\scratch\vendor-full.img  (full /vendor)
```

> You can dump less if you only want Route 1 (you just need metadata + the dir
> blocks + the policy's inode). But dumping the full 256 MB once lets you do
> **either** route and also gives you a clean backup of `/vendor`. Recommended.

Confirm the dump's policy matches expectations:

```bash
# In WSL, mount the dump read-only and compare to our reference:
sudo mkdir -p /mnt/vendor && sudo mount -o loop,ro firmware/scratch/vendor-full.img /mnt/vendor
cmp /mnt/vendor/etc/selinux/precompiled_sepolicy selinux/sepolicy.bin && echo "MATCHES reference"
xxd -l 20 /mnt/vendor/etc/selinux/precompiled_sepolicy   # vers 1e?
sudo umount /mnt/vendor
```

If it does **not** match the reference, re-run Phase A (A2/A3) using the
freshly-pulled file as input instead of `selinux/sepolicy.bin`.

### B2. Locate the File + Capture Originals

```powershell
python scripts\locate_vendor_policy.py firmware\scratch\vendor-full.img
```

It prints, for `/vendor/etc/selinux/precompiled_sepolicy`:
- inode number, current `i_size`
- the data-block extents → **absolute eMMC LBA range** of the file content
- the **absolute LBA + byte offset of the inode itself** (for the i_size patch)
- whether **`metadata_csum`** is enabled (this decides the route)

**Capture the originals before writing anything** (so §7 restore is trivial):

```powershell
# Replace <FILE_LBA> / <NSECT> / <INODE_LBA> with the script's output.
.\tools\rkdeveloptool\rkdeveloptool.exe rl <FILE_LBA> <NSECT> firmware\scratch\policy.orig.blob
.\tools\rkdeveloptool\rkdeveloptool.exe rl <INODE_LBA> 1   firmware\scratch\inode.orig.sector
```

### Choose Your Route

- **`metadata_csum` = OFF** → **Route 1 (surgical)** is safe and fast (small write).
- **`metadata_csum` = ON**, or you want zero ext4 hand-editing → **Route 2 (reflash)**.

---

### Route 1: Surgical In-Place Write (Recommended When metadata_csum Is OFF)

Only the policy file's data blocks + one 4-byte size field change. The block
**count** is unchanged (a few extra bytes fit in the file's last 4 KB block), so
no bitmaps/extents/`i_blocks` change.

**1. Build a block-padded copy of the patched policy** (pad with zeros up to the
file's allocated block count so the write fills exactly the existing blocks):

```bash
# NSECT from the locator = number of 512B sectors the file occupies (block-aligned).
# Pad /tmp/sepolicy.patched.bin up to NSECT*512 bytes.
python3 - <<'PY'
nsect = <NSECT>                      # from locator
data = open('/tmp/sepolicy.patched.bin','rb').read()
target = nsect*512
assert len(data) <= target, "patched policy bigger than allocated blocks -> use Route 2"
open('/tmp/policy.padded.blob','wb').write(data + b'\x00'*(target-len(data)))
print('blob bytes', target, 'policy bytes', len(data))
PY
```

**2. Write the policy content:**

```powershell
.\tools\rkdeveloptool\rkdeveloptool.exe wl <FILE_LBA> \\wsl$\...\policy.padded.blob
# (copy /tmp/policy.padded.blob out of WSL to a Windows path first)
```

**3. Patch the inode's `i_size`** to the new (real) policy length. The locator
prints `INODE_LBA` and `INODE_OFFSET` (byte offset of the inode within that
sector). `i_size_lo` is at inode offset **+4** (4 bytes, little-endian):

```bash
python3 - <<'PY'
import struct
sect = bytearray(open('inode.orig.sector','rb').read())   # the 512B sector you rl'd
off  = <INODE_OFFSET>                                       # from locator
newsize = <PATCHED_POLICY_BYTES>                            # exact len of sepolicy.patched.bin
struct.pack_into('<I', sect, off+4, newsize)               # i_size_lo
# i_size_high (offset +0x6C) stays 0 for a ~300 KB file.
open('inode.patched.sector','wb').write(sect)
print('set i_size =', newsize)
PY
```
```powershell
.\tools\rkdeveloptool\rkdeveloptool.exe wl <INODE_LBA> inode.patched.sector
```

> If the locator reported `metadata_csum = ON`, do **not** use Route 1 (the inode
> checksum would now be wrong). Use Route 2 instead.

Proceed to **B3**.

---

### Route 2: Whole `/vendor` Reflash (Foolproof; No ext4 Hand-Editing)

You already dumped `firmware\scratch\vendor-full.img` in B1. Just swap the file
inside it (mount handles all metadata + checksums) and flash it back.

```bash
# In WSL: overwrite the file's CONTENT in place (preserves inode, owner, and the
# SELinux context xattr: important so init can still read it).
sudo mount -o loop firmware/scratch/vendor-full.img /mnt/vendor
cat /tmp/sepolicy.patched.bin | sudo tee /mnt/vendor/etc/selinux/precompiled_sepolicy >/dev/null
sync
# sanity check it took:
sesearch --allow -s untrusted_app -t serial_device -c chr_file /mnt/vendor/etc/selinux/precompiled_sepolicy
sudo umount /mnt/vendor
```

Flash the whole partition back (writes do **not** hit the read-wedge, per
`notes/HANDOFF.md`: a single `wl` of 256 MB is normally fine; if it ever stalls,
split into a few `wl` calls at successive LBAs):

```powershell
.\tools\rkdeveloptool\rkdeveloptool.exe wl 0x592000 <windows-path>\vendor-full.img
```

Proceed to **B3**.

---

### B3. Reboot out of Loader

```powershell
.\tools\rkdeveloptool\rkdeveloptool.exe rd
```

Wait ~30–60 s for Android, then reconnect WiFi ADB:
```powershell
& "X:\Claude\android platform-tools\adb.exe" connect 192.168.0.180:5555
```

---

## 6. Phase C: Verify on the Device

```powershell
$adb = "X:\Claude\android platform-tools\adb.exe"
# 1) SELinux still enforcing, label unchanged (we added a rule, we did not relabel):
& $adb -s 192.168.0.180:5555 shell getenforce            # Enforcing
& $adb -s 192.168.0.180:5555 shell ls -Z /dev/ttyS1      # ...serial_device...

# 2) The real test: does an UNTRUSTED_APP open it WITHOUT a denial?
#    Launch the app, then watch logs for a successful native open and NO avc deny.
& $adb -s 192.168.0.180:5555 shell am start -n com.mabu.facetrack/.MainActivity
& $adb -s 192.168.0.180:5555 logcat -d | Select-String -Pattern "MabuSerial","MabuMotors","ttyS1","avc.*serial_device"
```

**Success looks like:** a log line such as `MabuSerial: opened 57600 baud, fd=NN`
(from `serial.c`) and **no** `avc: denied ... serial_device ... untrusted_app`.

**If you still see `avc: denied ... serial_device`:** the patch didn't load. Most
likely init recompiled from CIL (the `/vendor` precompiled file wasn't used). The
device is fine; see §8 contingency. Re-pull the live policy and confirm your
write actually changed the on-disk bytes (mount the partition again and
`sesearch`).

> Per project rules: **do not run any motor-movement test** until the operator confirms
> the hardware is OK and is watching. Phase C only opens the port / checks
> logs; it does not command motors.

---


### C2. Enable Persistent ADB-over-TCP (While USB Is Still Connected)

While you have USB ADB active, lock in wireless ADB so the device never needs a
USB cable again:

```powershell
# Replace <usb-serial> with the serial from 'adb devices'
adb -s <usb-serial> tcpip 5555
# Wait 2 s, then verify wirelessly:
adb connect <device-ip>:5555
adb -s <device-ip>:5555 shell echo "wireless ADB OK"
```

`adb tcpip 5555` writes `persist.adb.tcp.port=5555` to `/data/property/` --
this survives reboots, so wireless ADB comes up on every boot automatically.
**Run this before disconnecting the USB harness for the last time.**

## 7. Restore / Abort (One Command Back to Original)

You captured the originals in B2. To revert:

**Route 1 revert:**
```powershell
.\tools\rkdeveloptool\rkdeveloptool.exe wl <FILE_LBA>  firmware\scratch\policy.orig.blob
.\tools\rkdeveloptool\rkdeveloptool.exe wl <INODE_LBA> firmware\scratch\inode.orig.sector
.\tools\rkdeveloptool\rkdeveloptool.exe rd
```

**Route 2 revert:** re-flash the original `/vendor` image. If you still have the
un-edited dump, flash that; otherwise restore the file inside the image from
`selinux/sepolicy.bin` and re-flash.

**Backstop:** `scripts/restore-boot.ps1` rewrites the original `boot.img` and
clears `misc` if anything ever affects boot (it should not; we never touch boot).

---

## 8. Failure Modes & Why This Isn't a Brick Path

| Symptom | Cause | What it means / fix |
|---|---|---|
| After reboot, app still gets `avc: denied ... serial_device` | init recompiled policy from CIL and ignored our precompiled file | **Not a brick**: device boots normally. The hash check in §1 should prevent this; if it happens, re-verify the on-disk write, or escalate (patch the CIL inputs + their hash, or use Route 2). |
| Boot loops / no Android | policy file truncated or corrupt | Restore originals (§7). This is why we capture originals **before** writing and why Route 1 requires the size to fit existing blocks. |
| `rkdeveloptool` can't see device | Loader window missed, or WinUSB not bound | Power-cycle, re-catch within ~10 s; re-run `bind-winusb.ps1` / Zadig. |
| `wl` reports not-100% | partial write | Re-run the `wl`; never leave a partial policy write; restore + retry. |
| Read wedge during `/vendor` dump | known Loader limit (~28 MB/session) | The cycled dumper handles it; just let it cycle, or power-cycle and resume. |

**Boot.img is never modified**: that's the only thing proven to brick this unit
to recovery. Everything here is confined to one `/vendor` file with originals saved.

---

## 9. Phase D: App Revert (Do AFTER Phase C Verifies; Separate Work)

Once the app can open `/dev/ttyS1` directly, delete the bridge. These are the
edits to make in the **app project** (`X:\Claude\Mabu\MabuFaceTrack`, the working
app, **not** the read-only reference `mabu-git/mabu-android`). `BridgeProblem.md`
marks every line with `// TEMP`:

1. **`MabuMotors.kt`**: replace the `Socket("127.0.0.1", 7777)` / `OutputStream`
   path with the native serial JNI (`serial.c` / `SerialPort.kt` from the
   reference app) opening `/dev/ttyS1` at 57600 8N1 raw. In `serial.c`'s termios
   setup, **also clear `HUPCL`** (`tio.c_cflag &= ~HUPCL;`) so closing the fd does
   not drop DTR and reset the motor board (the hard-won `-hupcl` lesson). Keep the
   port open for the app's lifetime (don't open/close per frame).
2. Delete `AdbShellBridge.kt` and any `BRIDGE_HOST`/`BRIDGE_PORT` constants.
3. Remove the `INTERNET` permission from `AndroidManifest.xml` (no longer needed).
4. On the device, you can now stop and delete `motor-bridge.sh` and remove any
   startup of it. The 5×-power-on cold-boot wake (`MABU_MOTOR_GUIDE.md` §3) still
   applies; keep that in the app's init.

Re-build/deploy per `guides/MABU_BUILD_GUIDE.md`, then (with the operator watching, per
project rules) confirm motors move directly with no bridge running.

---

## Appendix A: `locate_vendor_policy.py`

Self-contained ext4 locator. Parses the superblock (so it works on `/vendor`,
whose ext4 geometry may differ from `/system`), walks
`root → etc → selinux → precompiled_sepolicy`, and prints the file's data-block
LBAs, its inode location, and whether `metadata_csum` is on. Save as
`scripts/locate_vendor_policy.py`.

```python
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
```

---

## Appendix B: Quick Reference: What `rkdeveloptool` Calls Do

| Command | Meaning |
|---|---|
| `rkdeveloptool ld` | List devices; look for `Vid=0x2207,Pid=0x320a...Loader` |
| `rkdeveloptool rl <LBA> <sectors> <out>` | Read `<sectors>` 512-byte sectors from `<LBA>` |
| `rkdeveloptool wl <LBA> <file>` | Write `<file>` starting at sector `<LBA>` (look for `100%`) |
| `rkdeveloptool rd` | Reset/reboot the device out of Loader |

---

*Created 2026-06-01. Phase A (offline) verification done: policy is v30 and the
rule's types are present, so injection is confirmed feasible. Remaining: obtain
`magiskpolicy` in WSL (only tool gap), then execute Phases B–D during a harness
session. This guide adds a new file only; no existing repo files were modified.*

# Flashing a brand-new Mabu out of the box

End-to-end procedure for taking a factory Mabu robot tablet (Catalia Health
H7R, Rockchip RK3288, Android 8.1, locked by Esper MDM) and turning it into a
freely user-controlled device that runs **our own apps** — including the
face-tracking app, which needs motor access that SELinux blocks by default.

> Sources this guide is built from:
> - Local **Mabu liberation toolkit** (`../Mabu/`) — the validated Loader-side
>   flash procedure, scripts, and firmware patches.
> - Local **Mabu-Facetrack** app (`../Mabu/mabu-facetrack/`) — our app, and its
>   `BridgeProblem.md` SELinux write-up.
> - Local **`../Mabu/selinux/`** — the prepared SELinux policy fix.
>
> Nothing in this guide writes to the `Mabu` or `mabu-facetrack` repos. This
> is a fresh document for a new repo.

---

## 0. The one-paragraph version

Catch the Rockchip Loader on power-on, run one PowerShell script that writes 8
raw-eMMC patches (disable dm-verity, neutralize Esper, open ADB) plus a 96 MB
`/data` wipe, boot to plain Android, sideload your launcher + your app. The
**one thing that script does NOT solve is SELinux** — on this `user` build the
kernel `selinux=permissive` flag is ignored and the policy re-enforces at boot,
so your app can't drive the motors. Section 6 is the prepared fix for that.

```powershell
# from the Mabu repo root, Loader caught on the harness:
.\scripts\flash-mabu.ps1 -WipeData -RestoreMabu
```

---

## 1. What you need

### Hardware
- The Mabu unit, opened enough to reach the **30-pin internal header** (these
  units have no external USB port or buttons). USB OTG is broken out on pins
  21/23/25/27 (VCCUSB / OTG_ID / OTG_DM / OTG_DP) — see the pinout in
  `../Mabu/README.md`. **D+/D- polarity is the classic wiring gotcha**; if you
  get "device descriptor request failed," swap OTG_DM/OTG_DP.
- The internal USB programming harness (we have only one — each liberation is a
  one-shot-per-unit opportunity; plan the session).
- **A USB-2 hub between tablet and PC.** This is not optional on the current
  flashing PC — see the Loader-enumeration note below.

### PC / software (already staged on this machine)
- `../Mabu/tools/rkdeveloptool/rkdeveloptool.exe` (+ DLLs) — WinUSB Loader CLI.
- Rockchip **DriverAssistant v5.0** (`rockusb.sys`) and **RKDevTool v2.92** —
  in `../Mabu/tools/rockchip-stock/`.
- **Zadig 2.9** — to bind WinUSB to the Loader interface.
- **adb / platform-tools** (winget `Google.PlatformTools`).
- For the permanent SELinux fix only: WSL/Ubuntu with `setools`,
  `policycoreutils`, and **magiskpolicy** (see Section 6, Tier 2).

### Known PC blocker — Loader won't enumerate on xHCI-only machines
The u-boot Loader USB gadget (VID 2207 **PID 320A**) is **USB-2 only**. The
current flashing PC has only xHCI controllers and no EHCI companion, so Loader
mode often fails to enumerate even though Android (0006) and recovery (0011)
modes work fine on the same cable.

**Fix: put any USB hub (a USB-2 hub is ideal — it provides a Transaction
Translator) between the tablet and the PC.** Alternatively use a PC with native
USB-2 (EHCI) ports. If Loader still won't show, reboot the PC to clear any
wedged USB stack state and remove stale `VID_2207` ghost nodes with `pnputil`.

---

## 2. Understand the two starting states

A factory unit is in one of two states; they need slightly different handling
(both are covered by `flash-mabu.ps1`):

| State | What you see | Treatment |
|---|---|---|
| **A. Active Esper** | Kiosk / Mabu dashboard boots, USB ADB wedges within ~5 s | Patches **+ 96 MB `/data` wipe** (the real DPC, `io.shoonya.shoonyadpc`, lives in `/data/app` and survives the /system patches) |
| **B. Factory-reset Esper** | Normal-ish boot, no kiosk, but Device Owner ref still set | Patches alone are enough; `/data` wipe optional |

When in doubt, use `-WipeData`. 96 MB is the validated sweet spot — larger wipes
(256 MB+) have correlated with a Settings/Dev-Options regression; smaller wipes
don't reliably trigger the `/data` reformat.

---

## 3. Catch the Loader

1. Connect the harness (through the USB-2 hub) to the PC. Tablet powered off.
2. Power on the tablet. During early boot, u-boot exposes **PID 0x320A** for
   ~10 seconds. Any rockusb command in that window latches it into Loader mode
   indefinitely.
3. Bind the driver so the tool can talk to it:
   - First touch with **RKDevTool v2.92** → *Read Flash Info* latches Loader
     (`rockusb.sys` auto-binds PID 320A). It stays put 60 s+.
   - Then **Zadig**: select the 320A interface, replace its driver with
     **WinUSB** (one-time, while Loader is latched) so `rkdeveloptool` can use
     it.
4. Verify from the Mabu repo root:
   ```powershell
   .\tools\rkdeveloptool\rkdeveloptool.exe ld
   # expect: ... Vid=0x2207,Pid=0x320a ... Loader
   ```
   `scripts\latch-loader.ps1` automates the poll-and-latch if you prefer.

> If you can't catch Loader at all, re-read Section 1's enumeration note — on
> this PC that is almost always the USB-2/hub issue, not the harness.

---

## 4. Flash: liberate + provision (one command)

From the **Mabu repo root** (`../Mabu/`), with Loader caught:

```powershell
.\scripts\flash-mabu.ps1 -WipeData -RestoreMabu
```

What it does, in order (`scripts/flash-mabu.ps1` → `scripts/liberate-mabu.ps1`):

1. **8 Loader-side raw-eMMC patches** (`liberate-mabu.ps1`):
   - **Parameter @ LBA 0** — kernel cmdline gets
     `androidboot.veritymode=disabled androidboot.selinux=permissive`, Rockchip
     CRC32 recomputed. **Disables dm-verity** (this is what lets us edit
     `/system`). *(The `selinux=permissive` part does NOT actually take — see
     Section 6.)*
   - **adbd auth bypass ×2** — `auth_required` byte → 0, and `adbd_auth_init` →
     early-return. ADB works with no on-screen approval dialog.
   - **3× Esper APK EOCD nukes** — corrupt the End-of-Central-Directory of
     espersupervisor / esperdpc / esperhelper so PackageManager skips them.
   - **init.esper.rc + set-device-owner.sh zeroed** — kills the boot service
     that re-asserts Device Owner.
2. **Inter-phase reset, then 96 MB `/data` head wipe** (`wipe-data-head.ps1`) —
   corrupts the ext4 superblock so vold reformats `/data` clean on boot,
   removing the in-`/data` Esper DPC. (Done in a separate Loader session; doing
   patches + wipe back-to-back wedges Loader.)
3. **Reset to Android**, wait for ADB (USB or WiFi).
4. **Install F-Droid + Lawnchair**, set Lawnchair as home.
5. **(`-RestoreMabu`)** install `com.catalia.factorymode` + push animation/voice
   assets, grant runtime perms. *(Factory-test app, not the consumer app — the
   consumer Mabu app was never archived.)*

After `/data` wipe, **WiFi credentials are gone**. The script pauses and asks
you to join WiFi on the touch UI before app installs proceed.

**Result:** plain Android 8.1, Lawnchair home, F-Droid, ADB open (USB + WiFi on
port 5555, no auth dialog). Verify:

```powershell
adb connect <tablet-ip>:5555
adb -s <tablet-ip>:5555 shell getprop ro.device_owner   # expect empty
adb -s <tablet-ip>:5555 shell "pm list packages | grep -iE 'esper|shoonya'"  # expect empty
```

> **Transport note:** WiFi ADB (`adb connect <ip>:5555`) is the most reliable
> transport on this build. USB ADB can sit `offline`/`unauthorized` on some
> units due to lingering Esper DPM behavior. Set a static DHCP lease for the
> tablet so the IP is stable.

---

## 5. Install our own apps / OS

You now have a normal Android tablet. Three layers, pick what you need:

- **Just apps:** sideload any APK with `adb install`, or use F-Droid on-device.
- **Aurora Store** (via F-Droid) gives Play-catalog access without Google
  services.
- **Full OS replacement** is out of scope here — the cleaner path on this
  hardware is the "clean firmware flash" model (dump a known-good `/system`
  once, flash it to new units via Loader). dm-verity is already off, so a
  modified `/system` image will mount. See `../Mabu/notes/HANDOFF.md`
  ("Assembly-line strategy") for that pipeline.

### Installing the Facetrack app

```powershell
# build the APK (Android Studio / gradle) from ../Mabu/mabu-facetrack/, then:
adb -s <tablet-ip>:5555 install MabuFaceTrack.apk
adb -s <tablet-ip>:5555 shell pm grant com.mabu.facetrack android.permission.CAMERA
# optional: make it the launcher (its manifest already declares HOME/LAUNCHER)
adb -s <tablet-ip>:5555 shell cmd package set-home-activity com.mabu.facetrack/.MainActivity
```

The app does ML-Kit face detection (model bundled — Mabu has no Play Services)
and drives the 7 motors. **But out of the box it still won't move the robot** —
that's the SELinux issue. Section 6.

---

## 6. The SELinux issue — and the fix (READ THIS)

### What actually goes wrong

The motor board is on `/dev/ttyS1`, labeled `u:object_r:serial_device:s0`. An
app installed normally runs as `u:r:untrusted_app:s0`, and stock AOSP policy has
**no `allow untrusted_app serial_device` rule**. So every `open("/dev/ttyS1")`
from the app fails with EACCES — even though `ls` shows `crwxrwxrwx`. Confirmed
denial (unit 4):

```
avc: denied { getattr } for path="/dev/ttyS1"
  scontext=u:r:untrusted_app:s0:c512,c768
  tcontext=u:object_r:serial_device:s0
  tclass=chr_file permissive=0
```

**Why the liberation patch doesn't already cover this:** the parameter patch
sets `androidboot.selinux=permissive` → `ro.boot.selinux=permissive`, but this
is a **`user` build**, and on user builds Android `init` ignores that flag and
forces SELinux **enforcing** at startup (`ALLOW_PERMISSIVE_SELINUX` is compiled
out). The `permissive=0` in the denial above is the proof: the device is
enforcing at runtime regardless of the kernel cmdline. `setenforce 0` also fails
(no root), and `/system` can't be remounted rw from a non-root adb shell.

So there are exactly two ways to give the app motor access. **Tier 1 works today
with zero policy changes; Tier 2 is the permanent fix to apply while the harness
is still connected.**

---

### Tier 1 — TCP motor bridge (recommended for immediate bring-up)

The `shell` domain (`u:r:shell:s0`) **is** allowed to open `serial_device` —
that's why `adb shell printf ... > /dev/ttyS1` moves motors. So we run a tiny
shell-user daemon that owns the serial port and exposes it on a local TCP port;
the app talks to that port instead of the device. The kernel sees *shell*
touching the motors, so SELinux is satisfied. **The Facetrack app already does
this** (`MabuMotors.kt` connects to `127.0.0.1:7777`).

Bridge script: `../Mabu/mabu-facetrack/bridge/motor-bridge.sh`. Its current
design opens `/dev/ttyS1` once on fd 3 and sets `-hupcl` so disconnects don't
reset the motor board (this fixed the earlier `nc: short write` corruption).

**Start it (once per boot):**
```powershell
adb -s <tablet-ip>:5555 push bridge/motor-bridge.sh /data/local/tmp/
adb -s <tablet-ip>:5555 shell chmod 755 /data/local/tmp/motor-bridge.sh
adb -s <tablet-ip>:5555 shell "busybox dos2unix /data/local/tmp/motor-bridge.sh"
adb -s <tablet-ip>:5555 shell "nohup sh /data/local/tmp/motor-bridge.sh > /data/local/tmp/motor-bridge.log 2>&1 &"
```

Then launch the app — it connects to the bridge and the robot tracks faces.

**Limits of Tier 1:**
- The bridge must be relaunched after every reboot (it lives in
  `/data/local/tmp` and runs in the shell/adb context). For a fixed install,
  auto-start it from a host on the LAN (e.g. a scheduled task that runs
  `adb connect <ip>:5555` then the `nohup` line on boot).
- One client at a time; ~10–50 ms gap on reconnect (the app retries).
- If motors stop responding after many reconnect cycles, **reboot the tablet** —
  that's the only reliable reset for a corrupted TTY/motor-board state.

---

### Tier 2 — Permanent SELinux policy patch (apply while harness is connected)

Add one rule so `untrusted_app` can open the serial device directly — then the
bridge is unnecessary and the app talks to `/dev/ttyS1` natively.

**The rule** (already prepared at `../Mabu/selinux/mabu_serial_access.te`):
```
allow untrusted_app serial_device:chr_file { open read write getattr ioctl };
```

Because `/system` can only be written via the Loader on this device (no root,
no rw remount), the patched policy has to be flashed the same way the liberation
patches are. **Cleanest turnkey path is magiskpolicy** (it parses and
re-serializes the binary policy correctly — don't hand-poke bytes):

1. **Pull the live binary policy** (from a unit already liberated to Tier-1):
   ```bash
   adb -s <ip>:5555 pull /sys/fs/selinux/policy ./sepolicy.bin
   ```
   (The repo also keeps a reference copy at `../Mabu/selinux/sepolicy.bin`.)

2. **Patch it offline** (WSL/Linux):
   ```bash
   magiskpolicy --load sepolicy.bin --save sepolicy.patched \
     "allow untrusted_app serial_device chr_file { open read write getattr ioctl }"
   ```

3. **Flash it back to `/system` via Loader.** Identify which policy file `init`
   loads at boot — on this build runtime uses the **precompiled** policy. Patch
   **both** to be safe:
   - `/system/etc/selinux/precompiled_sepolicy`
   - `/vendor/etc/selinux/precompiled_sepolicy`

   Locate each file's ext4 data blocks (same ext4-inode-walk technique the
   liberation used — see `../Mabu/scripts/find-esper-files.py`), then write the
   patched bytes with `rkdeveloptool wl <LBA> sepolicy.patched`.

   > **Size caveat (important):** adding the rule makes the policy a few bytes
   > larger. A raw sector overwrite is only safe if the patched file still
   > occupies the **same number of 4 KB ext4 blocks** as the original (pad the
   > write with the original trailing bytes / NULs to the block boundary). If it
   > spills into a new block, do **not** raw-overwrite — instead rebuild and
   > flash the whole `/system` image (the "clean firmware flash" path in
   > `HANDOFF.md`), or use the AOSP rebuild path below.

4. **Reboot and verify** the denial is gone:
   ```bash
   adb -s <ip>:5555 shell "dmesg | grep ttyS1"   # no new avc: denied
   ```

**Cleanest alternative (if you have an AOSP tree for this board):** drop
`mabu_serial_access.te` into `system/sepolicy/private/`, run `m sepolicy`, and
flash the resulting `precompiled_sepolicy` — no size/round-trip risk. See
`../Mabu/selinux/README.md` and `apply-patch.sh` (note: `apply-patch.sh`
documents the procedure but stops short of a turnkey binary merge — magiskpolicy
in step 2 above is the turnkey piece it's missing).

**After the permanent fix lands**, revert the app to direct serial (every line
is marked `// TEMP` in `MabuMotors.kt`):
- Replace `Socket(...)`/`OutputStream` with `FileOutputStream("/dev/ttyS1")`.
- Restore the `busybox stty` setup in `open()`.
- Drop the `INTERNET` permission from `AndroidManifest.xml`.
- Remove `BRIDGE_HOST` / `BRIDGE_PORT`.

> **Recommendation:** ship Tier 1 first to confirm the whole stack works
> (camera → face detect → motors), *then* apply Tier 2 on the same harness
> session and re-test. Leaving the bridge fallback in the app as
> belt-and-suspenders is fine — it won't be reached once native serial opens.

---

## 7. Motor calibration (per unit)

Motor mechanical zeros differ per unit and are wiped by the `/data` reformat.
Two options:
- Launch **Mabu Factory Mode** → *Trouble Shooting / Motor Debug* and run its
  calibration wizard (re-derives zeros, writes them fresh).
- Or tune the Facetrack neutrals directly — `MabuMotors.kt` constants
  (`NE_NEUTRAL=25`, `NR_NEUTRAL=42`, `NT_NEUTRAL=45`, `EYELID_NEUTRAL=25`) and
  the `MainActivity.kt` offsets (`Y_OFFSET`, `X_OFFSET`, `ELR_GAIN`).

Protocol reference (don't hand-compute checksums — use the code):
`FA 00 <len> <payload> <fletcher8 s2> <fletcher8 s1>`, motor values 0–100 →
`round(v * 2.55)`. Full table in `../Mabu/mabu-facetrack/BridgeProblem.md` and
`../Mabu/notes/motor-protocol.md`.

---

## 8. Emergency / recovery

- **Bad patch bricks boot:** `..\Mabu\scripts\restore-boot.ps1` writes the
  original `boot.img` back and clears `misc`.
- **Re-lock ADB for deployment on an untrusted network:**
  `..\Mabu\scripts\restore-adb-auth.ps1` (restores the standard "Allow ADB
  debugging?" dialog).
- **Loader read wedge** (only matters if you dump `/system`): Loader wedges
  after ~28 MB of cumulative reads in one session — power-cycle to recover, or
  use `scripts/dump-system-cycled.ps1`.

---

## 9. Quick checklist

- [ ] USB-2 hub in line (Loader enumeration)
- [ ] Loader caught (PID 320A), WinUSB bound via Zadig
- [ ] `flash-mabu.ps1 -WipeData -RestoreMabu` completes
- [ ] Device Owner clear, no esper/shoonya packages
- [ ] WiFi ADB on 5555, static lease set
- [ ] Launcher + apps installed
- [ ] **SELinux: Tier 1 bridge running → app moves motors**
- [ ] **SELinux: Tier 2 policy patch applied (optional, permanent) → revert app to direct serial**
- [ ] Motor calibration done
- [ ] Unit closed up

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

> **Two operations — pick one up front:**
> - **Flash** (default) — overwrite and provision the unit, with **no attempt to
>   save** what was on it. This is the normal path and everything below assumes
>   it. The `/data` wipe is irreversible.
> - **Flash and capture** — first pull the unit's existing software/assets, *then*
>   flash. Use this only when a unit still has Mabu software worth keeping. The
>   capture procedure is **Section 3A** (optional, documented separately and
>   still being finalized — skip it for a plain flash).

```powershell
# FLASH (default): from the Mabu repo root, Loader caught on the harness:
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
  one-shot-per-unit opportunity; plan the session). A direct USB 3 connection
  from the harness to the PC is sufficient — no hub needed.

### PC / software
The complete, categorized list of every software prerequisite — for flashing,
building, deploying, **and** the permanent SELinux fix — with winget install
commands and verify commands, is in **[Appendix A](#appendix-a--complete-prerequisites-flash--build--deploy--selinux)**.
At a glance:
- `../Mabu/tools/rkdeveloptool/rkdeveloptool.exe` (+ DLLs) — WinUSB Loader CLI.
- Rockchip **DriverAssistant v5.0** (`rockusb.sys`) and **RKDevTool v2.92** —
  in `../Mabu/tools/rockchip-stock/`.
- **Zadig 2.9** — to bind WinUSB to the Loader interface.
- **adb / platform-tools** (winget `Google.PlatformTools`).
- **Android Studio** (winget `Google.AndroidStudio`) — to build/deploy the app.
- For the permanent SELinux fix only: WSL/Ubuntu with `setools`,
  `policycoreutils`, and **magiskpolicy** (see Section 6, Tier 2).

### If Loader (PID 320A) won't enumerate
A direct USB 3 connection from the harness to the PC works — that's the
validated setup. If Loader mode (VID 2207 **PID 320A**) won't show even though
Android (0006) / recovery (0011) modes do, the usual culprits are wiring and
timing, not the host port:
- Re-check **D+/D- polarity** on the harness (swap OTG_DM/OTG_DP) — a marginal
  data pair shows as "device descriptor request failed."
- Reboot the PC to clear wedged USB stack state and remove stale `VID_2207`
  ghost nodes with `pnputil`.
- Try a different physical USB port / cable.

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

1. Connect the harness directly to the PC (USB 3 is fine). Tablet powered off.
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

> If you can't catch Loader at all, re-read Section 1's enumeration note —
> usually it's D+/D- polarity or timing on the harness, not the host port.

---

## 3A. (Flash and capture only) Capture the original Mabu software — BEFORE any wipe

> **This section is ONLY for the "flash and capture" path.** For a plain **flash**
> (the default), skip it entirely and go to Section 4.
>
> ⚠️ This procedure is **still being finalized** — treat it as a reference, not a
> turnkey script yet.
>
> When you *do* want to capture: the `/data` wipe is irreversible and destroys
> things we have **never archived** on any unit — the patient-facing **consumer
> Mabu app**, `/sdcard` assets, and per-unit motor calibration. Capturing first
> is the only chance to keep them. There is nothing to capture if
> `pm list packages | grep -i catalia` returns only `factorymode` (already in the
> repo) or is empty.

The catch-22: a stock unit's ADB is unauthorized (Esper suppresses the
approval dialog), so you can't capture until adbd is patched. So **liberate
without wiping first**, capture, *then* wipe.

**Step 1 — apply the patches only (NO wipe).** With Loader caught, from the
Mabu repo root:
```powershell
.\scripts\flash-mabu.ps1 -SkipApps      # = the 8 patches + reset; no /data wipe, no app install
```
(Equivalent: `.\scripts\liberate-mabu.ps1 -Reset`.) This gives unconditional
ADB while leaving `/data` intact.

**Step 2 — get on ADB (prefer WiFi).** Esper can wedge *USB* ADB within ~5 s of
boot; WiFi ADB is the stable transport and the patched adbd listens on 5555:
```powershell
# find the tablet IP (router DHCP table, or: nmap -p 5555 192.168.x.0/24), then:
adb connect <tablet-ip>:5555
adb -s <tablet-ip>:5555 shell echo ok
```

**Step 3 — sanity-check the build BEFORE trusting the byte offsets.** The
liberation LBAs assume the byte-identical H7R 8.1 build. Confirm this unit
matches; if the fingerprint differs, STOP — the hardcoded sector offsets may
not line up and need re-deriving:
```powershell
adb -s <tablet-ip>:5555 shell getprop ro.build.fingerprint
# expect: rockchip/H7R/H7R:8.1.0/OPM6.171019.030.E1/...:user/release-keys
adb -s <tablet-ip>:5555 shell getprop ro.serialno
```

**Step 4 — capture what a non-root shell CAN reach.** Set `$SER` to the unit
serial:
```powershell
$dev = "<tablet-ip>:5555"; $SER = "<serialno>"
$out = "..\Mabu\mabu-archive\unit-$SER"; New-Item -ItemType Directory -Force $out | Out-Null

# 4a. Which catalia/Mabu packages exist + where their APKs live
adb -s $dev shell "pm list packages -f | grep -iE 'catalia|mabu'" | Tee-Object "$out\packages.txt"

# 4b. Pull every catalia APK path printed above (APKs in /data/app are world-readable).
#     Example for one package dir — repeat per path from packages.txt:
#   adb -s $dev pull /data/app/com.catalia.<app>-<hash>/base.apk  "$out\com.catalia.<app>.apk"

# 4c. /sdcard assets (animations, voice, sound.raw) — readable
adb -s $dev pull /sdcard "$out\sdcard"

# 4d. State snapshots
adb -s $dev shell getprop                                  | Tee-Object "$out\getprop.txt"  | Out-Null
adb -s $dev shell "dumpsys package com.catalia.factorymode" | Tee-Object "$out\dumpsys-factorymode.txt" | Out-Null

# 4e. Best-effort tar of catalia data (private /data/data is 0700 — most will be
#     "Permission denied" without root; that's expected. APK dirs still come through.)
adb -s $dev shell "tar cf /sdcard/mabu-$SER.tar /data/app/com.catalia.* 2>/dev/null; ls -la /sdcard/mabu-$SER.tar"
adb -s $dev pull /sdcard/mabu-$SER.tar "$out\mabu-$SER.tar"
```

**Step 5 — verify the capture before proceeding.** Confirm the APKs and tar are
non-empty in `..\Mabu\mabu-archive\unit-$SER\`. If the **consumer** Mabu app
(anything `com.catalia.*` that is NOT `factorymode`) showed up in 4a, that's a
first-ever capture — make sure it pulled.

> **Note on calibration:** per-unit motor zeros live in
> `/data/data/com.catalia.factorymode/` (owner-only, shell can't read) and are
> lost in the wipe. They're re-derived after flashing via Factory Mode's
> calibration wizard (Section 7) — the robot only needs *some* current values,
> not the originals. The only thing genuinely unrecoverable is the consumer
> app if it's Esper-deployed and not in `/data/app`.

Once the capture is verified, continue to Section 4 and re-catch Loader for the
wipe.

---

## 4. Flash: liberate + provision (one command)

> For a plain **flash** (the default), run this directly. Only detour through
> Section 3A first if you explicitly want **flash and capture** on a unit that
> still has Mabu software worth keeping.

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
patches are. **Use magiskpolicy** to parse and re-serialize the binary policy
correctly — don't hand-poke bytes.

> **Where magiskpolicy runs:** magiskpolicy is an Android-native binary, not a
> Linux/glibc one — the staged copies under
> `../tools/magiskpolicy/` (`magiskpolicy-armeabi-v7a` for the 32-bit RK3288,
> Magisk v30.7) run **on the Mabu**, not in WSL. We push it to the device and
> patch the policy *file* there (pure file I/O — no root needed; `--live`
> kernel reload would need root, which we don't have, so we patch the file and
> flash it). The WSL `setools`/`audit2allow` install is for *inspecting* policy
> (`sesearch`, `seinfo`), not for the injection step.

1. **Pull the precompiled policy file** that `init` loads (world-readable):
   ```bash
   adb -s <ip>:5555 pull /vendor/etc/selinux/precompiled_sepolicy ./precompiled_sepolicy
   adb -s <ip>:5555 pull /system/etc/selinux/precompiled_sepolicy ./system_sepolicy   # if present
   ```
   (`../Mabu/selinux/sepolicy.bin` is a reference copy from unit 4.)

2. **Patch on-device with the ARM magiskpolicy** (file-to-file, shell domain):
   ```bash
   adb -s <ip>:5555 push ../tools/magiskpolicy/magiskpolicy-armeabi-v7a /data/local/tmp/magiskpolicy
   adb -s <ip>:5555 shell chmod 755 /data/local/tmp/magiskpolicy
   adb -s <ip>:5555 push ./precompiled_sepolicy /data/local/tmp/sepolicy.in
   adb -s <ip>:5555 shell "/data/local/tmp/magiskpolicy --load /data/local/tmp/sepolicy.in \
     --save /data/local/tmp/sepolicy.out \
     'allow untrusted_app serial_device chr_file { open read write getattr ioctl }'"
   adb -s <ip>:5555 pull /data/local/tmp/sepolicy.out ./precompiled_sepolicy.patched
   ```
   (Alternative: build a host `magiskpolicy` for x86_64 and do step 2 entirely
   in WSL — the on-device path above avoids that compile.)

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

- [ ] Loader caught (PID 320A), WinUSB bound via Zadig
- [ ] `flash-mabu.ps1 -WipeData -RestoreMabu` completes
- [ ] Device Owner clear, no esper/shoonya packages
- [ ] WiFi ADB on 5555, static lease set
- [ ] Launcher + apps installed
- [ ] **SELinux: Tier 1 bridge running → app moves motors**
- [ ] **SELinux: Tier 2 policy patch applied (optional, permanent) → revert app to direct serial**
- [ ] Motor calibration done
- [ ] Unit closed up

---

## Appendix A — Complete prerequisites (flash + build + deploy + SELinux)

Everything needed end-to-end, grouped by what it's for. Items marked **bundled**
ship inside the `../Mabu/` repo (no install). Items marked **winget** install
from an elevated PowerShell. Hardware can't be installed — verify physically.

### A.1 Hardware
| Item | Why | Notes |
|---|---|---|
| Mabu unit, opened to the 30-pin header | Target device | No external USB/buttons |
| Internal USB programming harness | Only USB path to the board | One-shot per unit; we have one. Direct USB 3 to the PC works — no hub needed |
| Stable DC power to the tablet | Avoid mid-flash power loss | — |

### A.2 Flashing toolchain (Loader-side)
| Tool | Source | Verify |
|---|---|---|
| `rkdeveloptool.exe` (+ libusb DLLs) | **bundled** `../Mabu/tools/rkdeveloptool/` | `rkdeveloptool ld` |
| Rockchip **DriverAssistant v5.0** (installs `rockusb.sys`) | **bundled** `../Mabu/tools/rockchip-stock/DriverAssitant_v5.0/` | `pnputil /enum-drivers | findstr rockusb` |
| **RKDevTool v2.92** (GUI, latches Loader) | **bundled** `../Mabu/tools/rockchip-stock/RKDevTool_Release_v2.92/` | launches |
| **Zadig** (bind WinUSB to PID 320A) | **winget** `akeo.ie.Zadig` | app opens |
| **adb / platform-tools** | **winget** `Google.PlatformTools` | `adb version` |

> The Rockchip `android_winusb.inf` (adb driver for PID 0006/0011) is staged in
> the driver store alongside `rockusb.sys`. Verify: `pnputil /enum-drivers | findstr android_winusb`.

### A.3 Android build + deploy toolchain
| Tool | Source | Verify | Notes |
|---|---|---|---|
| **Android Studio** | **winget** `Google.AndroidStudio` | launches | Bundles a JDK (JBR) + SDK Manager + Gradle. **First launch downloads the SDK** (platform-tools, `platforms;android-34`, `build-tools`). |
| **JDK 17** (only if building from CLI without Studio) | **winget** `Microsoft.OpenJDK.17` | `java -version` | Or point `JAVA_HOME` at Studio's JBR (`...\Android Studio\jbr`). |
| **Android SDK** (platform + build-tools + platform-tools) | via Studio first-run, or `sdkmanager` | `adb version`; `sdkmanager --list` | platform-tools provides the same `adb` used for flashing. |
| **Git** | **winget** `Git.Git` | `git --version` | For the guide/app repos. Already present. |
| Gradle wrapper (`gradlew.bat`) | **bundled** in `../Mabu/mabu-facetrack/` | `.\gradlew tasks` | Uses the JDK above; no separate Gradle install needed. |

Build + deploy the app from CLI (once SDK is in place):
```powershell
cd "..\Mabu\mabu-facetrack"
.\gradlew assembleDebug
adb -s <tablet-ip>:5555 install -r app\build\outputs\apk\debug\app-debug.apk
```
(Node.js is **not** required — the app is Kotlin/Gradle. Node was installed for
unrelated tooling.)

### A.4 Permanent SELinux fix toolchain (Tier 2 — optional)
Only needed to apply the permanent `allow untrusted_app serial_device` policy
rule. The Tier-1 TCP bridge needs none of this (just adb).

| Tool | Source | Verify |
|---|---|---|
| **WSL** + an Ubuntu distro | **winget** `Microsoft.WSL`, then `wsl --install -d Ubuntu` (reboot required) | `wsl -l -v` shows Ubuntu |
| `setools`, `policycoreutils`, `adb` (in WSL — for *inspecting* policy) | `sudo apt-get install setools policycoreutils adb` | `seinfo --version` |
| **magiskpolicy** (binary-policy patcher — runs **on the Mabu**, ARM) | **staged** `../tools/magiskpolicy/magiskpolicy-armeabi-v7a` (extracted from Magisk v30.7) | `file` shows "ARM ... for Android" |
| Policy rule + reference | **bundled** `assets/selinux/mabu_serial_access.te`, `assets/selinux/apply-patch.sh` | — |

### A.5 One-shot winget install (build + deploy + Git)
Run in an **elevated** PowerShell:
```powershell
winget install -e --id Google.AndroidStudio  --accept-package-agreements --accept-source-agreements
winget install -e --id Google.PlatformTools  --accept-package-agreements --accept-source-agreements
winget install -e --id akeo.ie.Zadig         --accept-package-agreements --accept-source-agreements
winget install -e --id Git.Git               --accept-package-agreements --accept-source-agreements
# Optional CLI-only JDK (skip if using Android Studio's bundled JBR):
winget install -e --id Microsoft.OpenJDK.17  --accept-package-agreements --accept-source-agreements
# Optional, for the permanent SELinux fix:
winget install -e --id Microsoft.WSL         --accept-package-agreements --accept-source-agreements
# then (reboot may be required):  wsl --install -d Ubuntu
```
After Android Studio installs, **launch it once** and let the Setup Wizard
download the SDK, or install components headlessly with `sdkmanager`.

### A.6 Status on the current flashing PC (2026-06-13)
| Capability | Ready? |
|---|---|
| Flash a new Mabu (A.2) | ✅ all installed; direct USB 3 connection validated |
| Deploy a prebuilt APK (adb) | ✅ |
| **Build** the Android app (A.3) | ✅ Android Studio 2026.1 + bundled JDK 21 installed — **launch once to download the SDK** |
| Permanent SELinux fix (A.4) | ✅ WSL Ubuntu 26.04 + setools/policycoreutils/adb installed; `magiskpolicy` (ARM) staged at `../tools/magiskpolicy/`. (Tier-1 bridge needs none of this.) |

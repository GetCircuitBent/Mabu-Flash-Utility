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
raw-eMMC patches (disable dm-verity, neutralize Esper, open ADB), optionally
wipes `/data`, boots to plain Android, installs F-Droid + Lawnchair + Mabu
factory mode, **patches the SELinux vendor policy** so the facetrack app can
drive the motors natively, then runs a 12-check self-test and prints pass/fail.
One command handles the full unit.

> **Two operations — pick one up front:**
> - **Flash** (default) — overwrite and provision the unit, with **no attempt to
>   save** what was on it. This is the normal path and everything below assumes
>   it. The `/data` wipe is irreversible.
> - **Flash and capture** — first pull the unit's existing software/assets, *then*
>   flash. Use this only when a unit still has Mabu software worth keeping. The
>   capture procedure is **Section 3A** (optional, documented separately and
>   still being finalized — skip it for a plain flash).

```powershell
# FLASH (default): from the repo root, with a booted adb-reachable unit.
.\scripts\flash-mabu.ps1 -RestoreMabu
```

> **State auto-detect:** the script probes the unit over adb and classifies it:
> - **State A** (active Esper DPC in `/data`) → patches + 96 MB `/data` wipe
> - **State B** (factory-reset Esper, no live DPC) → patches only, no wipe
> - **Liberated** (already patched — `init.esper.rc` zeroed, no Esper control) →
>   skip Loader entirely, go straight to app install + SELinux fix. Safe to re-run
>   after an interrupted provisioning phase.
> - **Unknown** (can't probe) → wipes as a safe default
>
> Force with `-WipeData` or `-NoWipe`. If Loader was pre-caught (no Android to
> probe), state is Unknown and the script wipes.

### Script flags

| Flag | Effect |
|---|---|
| `-RestoreMabu` | Install Mabu factory mode APK + push animation/voice assets |
| `-WipeData` | Force `/data` wipe regardless of detected state |
| `-NoWipe` | Force patch-only (skip wipe) regardless of detected state |
| `-SkipApps` | Loader patches only — no app install, no SELinux fix, no self-test |
| `-SkipSELinux` | Skip the SELinux policy fix phase |
| `-WifiIp <ip>` | WiFi hint for first adb connect attempt (auto-discovered at runtime) |

### What the script does, in order

1. **Detect state** (A / B / Liberated / Unknown)
2. **Enter Loader** and apply 8 liberation patches *(skipped for Liberated)*
3. **Wipe `/data` head** (96 MB) if State A or forced *(skipped for B / Liberated)*
4. **Reset** to Android
5. **Install apps** — F-Droid, Lawnchair (set as home)
6. **Restore Mabu** — factory mode APK + assets *(if `-RestoreMabu`)*
7. **SELinux fix** — on-device `magiskpolicy` patch → Loader write to `0x5A8AB8` *(skippable with `-SkipSELinux`)*
8. **Self-test** — 12 checks: liberation, apps, SELinux policy SHA, AVC denial check, WiFi adb

---

## 1. What you need

### Hardware
- The Mabu unit, opened enough to reach the **30-pin internal header** (these
  units have no external USB port or buttons). USB OTG is on pins 3/5/7/9
  (OTG_DP / OTG_DM / OTG_ID / VCCUSB). **D+/D- polarity is the classic wiring
  gotcha**; if you get "device descriptor request failed," swap OTG_DM/OTG_DP.

  **30-pin header pinout — 2 mm pitch, 2x15 dual-row.**
  Red stripe (pin 1) is at the GND/USB end, opposite the DCIN/power end.
  Pin 1 verified with meter (both pins 1 and 2 are GND).

  | Col A  | Pin |   | Pin | Col B  |
  |--------|-----|---|-----|--------|
  | GND    |  1  |   |  2  | GND    |
  | OTG_DP |  3  |   |  4  | ADKEY  |
  | OTG_DM |  5  |   |  6  | GND    |
  | OTG_ID |  7  |   |  8  | VCC    |
  | VCCUSB |  9  |   | 10  | PDM    |
  | PWRON  | 11  |   | 12  | IN3P   |
  | GND    | 13  |   | 14  | GND    |
  | RX     | 15  |   | 16  | SCL    |
  | TX     | 17  |   | 18  | SDA    |
  | RTS    | 19  |   | 20  | CTS    |
  | GND    | 21  |   | 22  | GND    |
  | SPKN   | 23  |   | 24  | SPKP   |
  | GND    | 25  |   | 26  | GND    |
  | GND    | 27  |   | 28  | DCIN   |
  | DCIN   | 29  |   | 30  | DCIN   |

  Functional groups: USB OTG (pins 3/5/7/9 + GND), motor UART (TX/RX/RTS/CTS
  pins 15-20), PMIC I2C (SDA/SCL pins 16/18), audio (SPKN/SPKP pins 23/24,
  PDM pin 10, IN3P pin 12), buttons (PWRON pin 11, ADKEY resistor-ladder pin 4),
  power (DCIN pins 28-30, VCC pin 8).
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
- **First, force Loader by holding ADKEY (pin 4) to GND through power-on** — see
  Section 3's "boot into Loader by holding ADKEY." This is what finally got this
  PC to 320A after only ever seeing Android 0006; the unit was free-booting past
  the Loader window, not failing to enumerate. Try this before chasing wiring.
- Re-check **D+/D- polarity** on the harness (swap OTG_DM/OTG_DP) — a marginal
  data pair shows as "device descriptor request failed."
- Reboot the PC to clear wedged USB stack state and remove stale `VID_2207`
  ghost nodes with `pnputil`.
- Try a different physical USB port / cable.

---

## 2. Understand the two starting states

A factory unit is in one of two states; they need slightly different handling
(both are covered by `flash-mabu.ps1`, which **auto-detects which one** — see
below):

| State | What you see | Treatment | Auto-detected by |
|---|---|---|---|
| **A. Active Esper** | Kiosk / Mabu dashboard boots, USB ADB wedges within ~5 s | Patches **+ 96 MB `/data` wipe** (the real DPC, `io.shoonya.shoonyadpc`, lives in `/data/app` and survives the /system patches) | `pm path io.shoonya.shoonyadpc` returns a package |
| **B. Factory-reset Esper** | Normal-ish boot, no kiosk, but Device Owner ref still set | Patches alone are enough; `/data` wipe skipped | that package is **absent** |

**The script picks for you:** it runs `pm path io.shoonya.shoonyadpc` over adb
before entering Loader and wipes only on State A. (Esper's `/system` apps —
espersupervisor etc. — survive a factory reset, so they're present in *both*
states and can't distinguish them; the `/data`-resident shoonya DPC is the
reliable signal.) Override with `-WipeData` (force wipe) or `-NoWipe` (force
patch-only). **When the state can't be probed — e.g. Loader was already caught,
so there's no Android to query — it defaults to wiping.**

96 MB is the validated wipe sweet spot — larger wipes (256 MB+) have correlated
with a Settings/Dev-Options regression; smaller wipes don't reliably trigger the
`/data` reformat.

> ⚠️ **OPEN ISSUE — units that were Settings-level factory-reset may be
> FDE-encrypted (2026-06-27, unresolved).** One unit that had been through an
> Android *Settings → factory reset* came up with **full-disk encryption**
> (`ro.crypto.type=block`, a populated `metadata` partition `mmcblk1p12`). On
> these, the head-wipe corrupts the *encrypted* userdata but the crypto footer
> survives, so vold gets stuck in `vold.decrypt=trigger_restart_min_framework`:
> `/data` is only a tmpfs, `/sdcard` never mounts, and the full framework (hence
> WiFi setup) never starts. Wiping the `metadata` partition made it **worse**
> (no boot at all — likely metadata-encryption where `/metadata` is needed
> early), and an AOSP-style `misc` BCB `--wipe_data` did **not** trigger a
> recovery wipe (RK bootloader may not honor it). **Not yet solved — do not
> follow those steps blind.** Likely correct path is a real recovery factory
> reset via the on-device recovery menu. See memory note
> `mabuflash-fde-factory-reset-unit` before touching an encrypted unit.

---

## 3. Catch the Loader

There are two ways in. **If you can get an adb shell, use the first — it's
deterministic and instant.**

### Optimal: `adb reboot loader` (when adb is reachable)
Stock Esper units are *often* already adb-authorized — Esper does not always
suppress the auth grant (on the validated unit `adb` showed `device`, not
`unauthorized`). And post-liberation adb is always open. Whenever `adb devices`
shows the tablet, just:
```powershell
adb reboot loader      # drops straight into Rockchip Loader (PID 320A)
```
On the validated unit this landed in Loader in **~1 second** — no power-on
timing race. This is also how you re-enter Loader between phases.

### Fallback: boot into Loader by holding ADKEY (validated on this PC)
If there is no adb at all, **hold ADKEY through power-on to force Loader.** This
is the reliable way in on a unit that otherwise free-boots straight to the
auth-walled Esper Android (PID 0006) — confirmed 2026-06-27 on this flashing PC,
which had never once reached Loader until this sequence:

1. Connect the harness directly to the PC (USB 3 is fine). Tablet powered off.
2. **Short ADKEY (pin 4) to GND** (any of pins 1/2/6/13/14…) and **hold it**.
3. While still holding ADKEY, power the unit on (hold PWRON ~2-3 s if it's a
   buttonless board — a tap may leave it dark). Holding ADKEY diverts the boot
   into the Rockchip **Loader (PID 0x320A)** instead of letting it free-boot to
   Android 0006.
4. Keep ADKEY held until USB enumerates as **Loader 320A** — verify with the
   `rkdeveloptool ld` check below (or watch with `scripts\latch-loader.ps1`).
   Then release. If you instead see PID 0006, the divert was missed: power off
   and retry, holding ADKEY a beat earlier/longer.

> If you let it boot normally, u-boot exposes **PID 0x320A** for only ~10 s
> before continuing to Android; `scripts\latch-loader.ps1` polls and latches it
> the instant it appears (no human timing needed). Holding ADKEY removes that
> race — the unit comes up *in* Loader and stays there.

**Don't dawdle once 320A is up** — a power-cycle or long idle can drop it back to
Android. Run the flash promptly. And since a hand-caught Loader gives the script
no booted Android to probe, it can't auto-detect State A vs B — pass
`-WipeData` or `-NoWipe` explicitly (see Section 4).

### Driver binding (usually already done)
`rkdeveloptool` needs **WinUSB** bound to PID 320A. On a PC that has flashed
before, this **persists** — on the validated PC, 320A came up already
`Service=WinUSB` and `rkdeveloptool ld` worked immediately, no Zadig step.

**The trap (hit 2026-06-27 on this PC's first-ever Loader catch):** when 320A
first appears it binds to Rockchip's **`rockusb.sys`** (`FriendlyName: Rockusb
Device`, `Service=Rockusb`). `rkdeveloptool ld` still *lists* it, but the first
write dies with **`WRITE FAILED: ... creating comm object failed!`** because the
transfer channel needs WinUSB, not rockusb.sys. So `ld` succeeding is **not**
proof you're ready to write.

**`flash-mabu.ps1` now auto-handles this.** Before Phase 2 it checks the driver
service on PID 320A (`Confirm-LoaderWinUsb`); if it's not WinUSB it **launches
Zadig for you**, prints the steps below, pauses, then re-verifies the binding and
that Loader is still visible before continuing. You only do the Zadig clicks:
- **Zadig** → *Options → List All Devices* → pick **Rockusb Device (USB ID 2207
  320A)** → target driver **WinUSB** → **Replace Driver**. Keep the unit powered
  in Loader throughout — don't power-cycle.

This is **one-time per PC *per USB port-path***; once WinUSB is bound it persists
across re-enumerations on **that same port** (including the script's inter-phase
Loader re-catch). Manual alternative if you prefer the GUI route: **RKDevTool
v2.92** → *Read Flash Info* to latch Loader (`rockusb.sys` auto-binds 320A; stays
put 60 s+), then Zadig as above.

> **Gotcha — the WinUSB binding is per port-path, not per device (hit
> 2026-06-27).** If you unplug and replug into a *different* physical USB
> port/hub, 320A enumerates at a new instance path (`...&0&2` → `...&0&9`) and
> Windows binds it back to `rockusb.sys` — so `wl`/`rl` fail again with "creating
> comm object failed!" Fixes: replug into the **same port** you Zadig'd, or
> re-run Zadig for the new port. `flash-mabu.ps1`'s `Confirm-LoaderWinUsb` gate
> catches this automatically; raw `rkdeveloptool` use does not, so keep to one
> port.

Verify from the Mabu repo root:
```powershell
.\tools\rkdeveloptool\rkdeveloptool.exe ld
# expect: ... Vid=0x2207,Pid=0x320a ... Loader
```

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

From the repo root, with a **booted, adb-reachable unit** (so the script can
detect the state and reboot it into Loader itself):

```powershell
.\scripts\flash-mabu.ps1 -RestoreMabu
```

The script auto-detects State A vs B and wipes `/data` only on State A (see
Section 2). Add `-WipeData` to force the wipe or `-NoWipe` to force patch-only.
If you've **already caught Loader** the state can't be probed, so it defaults to
wiping — pass `-WipeData`/`-NoWipe` explicitly in that case.

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
3. **Reset to Android**, wait for ADB to come up, then **join WiFi and switch to
   WiFi adb** for everything that follows (see the transport rule below — USB adb
   on this hardware times out too fast to rely on).
4. **Install F-Droid + Lawnchair**, set Lawnchair as home.
5. **(`-RestoreMabu`)** install `com.catalia.factorymode` + push animation/voice
   assets, grant runtime perms. *(Factory-test app, not the consumer app — the
   consumer Mabu app was never archived.)*

After `/data` wipe, **WiFi credentials are gone**. The script pauses and asks
you to join WiFi on the touch UI before app installs proceed.

> **Gotcha — script aborts at the inter-phase reset with `* daemon not running;
> starting now at tcp:5037`:** that banner is adb starting its background server
> on first use; it goes to **stderr**, and under the script's
> `$ErrorActionPreference = 'Stop'` the `2>&1` capture turns it into a fatal
> `NativeCommandError` that kills the run right after the patch phase (patches are
> already written; nothing is harmed). **Fixed in `flash-mabu.ps1`** — it now
> pre-starts the adb server up front (with errors non-fatal) so no later adb call
> emits the banner. If you see this on an older copy of the script, just re-run
> the same command: the patches are idempotent and the server is now running, so
> the second pass sails through. (Same root cause to watch for in any PS script
> that does `& adb ... 2>&1` under `Stop`.)

> **Gotcha — wipe "FAILED at chunk 0" was a path-quoting bug, NOT a Loader wedge
> (root-caused 2026-06-27).** The old `wipe-data-head.ps1` invoked rkdeveloptool
> via `Start-Process -ArgumentList @('wl',$lba,$Zeros)`, which does **not** quote
> arguments — so a repo path containing a space (`...\Claude Projects\...`)
> reached rkdeveloptool as extra args → `Parameter of [WL] command is invalid` →
> the script reported a "chunk 0 wedge" even though no write was attempted.
> (`Start-Process -PassThru` *also* misreported `ExitCode` as nonzero on writes
> that actually completed at 100%.) **Fixed:** the wipe now runs rkdeveloptool
> through a `System.Diagnostics.Process` with a properly-quoted argument string,
> a real exit code, and the WaitForExit timeout for genuine wedges. The patches
> use the `&` call operator (which quotes), so they were never affected — only
> the wipe. If you see this on an old copy: re-run, or keep the repo in a
> space-free path. Manual equivalent, Loader caught:
> `.\scripts\wipe-data-head.ps1 -SizeMB 96` then `rkdeveloptool rd`.

> **Gotcha — `/data` base LBA vs the GPT.** `wipe-data-head.ps1` hardcodes the
> userdata start as `0x692400` ("per parameter file"), but on the 2026-06-27 unit
> the kernel GPT reported userdata (`mmcblk1p16`) starting at `0x694400` — 8192
> sectors (4 MB) later. The 96 MB wipe still lands well inside userdata so it
> works, but if a unit won't reformat after a wipe, re-derive the real start from
> the device: `adb shell cat /sys/class/block/mmcblk1p16/start` (value is in
> 512 B sectors), and pass/patch that base.

> **Headless / non-interactive runs:** the WiFi pause above is a `Read-Host`,
> which hangs an unattended shell. To stage it: run
> `.\scripts\flash-mabu.ps1 -WipeData -SkipApps` (does all 8 patches + the
> inter-phase reset + 96 MB wipe, then exits cleanly **before** the pause), then
> drive the app installs yourself over adb. USB adb comes up authorized right
> after the wipe (the adbd auth-bypass patch), but it **times out too fast to rely
> on** — join WiFi and run the installs over WiFi adb (`adb connect <ip>:5555`).
> See the transport rule below.

**Result:** plain Android 8.1, Lawnchair home, F-Droid, ADB open (USB + WiFi on
port 5555, no auth dialog). Verify:

```powershell
adb connect <tablet-ip>:5555
adb -s <tablet-ip>:5555 shell getprop ro.device_owner   # expect empty
adb -s <tablet-ip>:5555 shell "pm list packages | grep -iE 'esper|shoonya'"  # expect empty
```

> **Transport rule (important — learned the hard way): use USB only when it is
> 100% necessary; do everything else over WiFi.** USB is *only* genuinely needed
> for two things:
> - **The Loader flash itself (`rkdeveloptool`)** — rock-solid, and there is no
>   WiFi alternative. Wrote 96 MB + all patches with zero issues. (Loader *reads*
>   wedge after ~28 MB cumulative per session — power-cycle / re-catch to continue.)
> - **Opening adb** — i.e. the auth-bypass patch the flash writes. That is the
>   *only* job USB adb has.
>
> Once adb is open, **switch to WiFi adb (`adb connect <ip>:5555`) for everything
> else** — app installs, shell, verification, and especially pulls. **Android USB
> adb times out too fast to rely on:**
> - **USB pulls (`adb pull`, device→host)** wedge after a cumulative **~80–128 KB
>   per boot**, then the device drops to `offline` and only a **power-cycle**
>   recovers it. Chunking only buys a few before the same cumulative wedge.
> - **USB pushes (`adb install`, `adb push`)** can complete for small payloads but
>   time out / wedge unpredictably under any real load — don't plan around them.
>
> **WiFi adb must be switched on — it does NOT auto-listen on every unit
> (corrected 2026-06-27).** On the original validated unit `adb connect <ip>:5555`
> worked immediately, but on the 2026-06-27 unit adbd was **not** listening on
> 5555, so the connect silently failed. The fix is the standard one: run
> **`adb tcpip 5555`** over USB once to put adbd into TCP mode, then
> `adb connect <ip>:5555`. `flash-mabu.ps1` now does this automatically
> (`Enable-WifiAdb`): over USB it reads the device's real `wlan0` IP
> (`ip addr show wlan0`), runs `tcpip 5555`, sets `persist.adb.tcp.port 5555`
> (survives a reboot that keeps `/data`), and connects. **Don't trust a hardcoded
> static-lease IP** — the `-WifiIp` param is only a hint; the script overwrites it
> with the discovered address (the 2026-06-27 unit DHCP'd `.160`, not the
> `.18` default). Once up, WiFi pulled 293 KB in 0.4 s where USB wedged at 128 KB.
> **Caveat:** the `/data` wipe erases WiFi credentials *and* the persistent tcpip
> flag, so re-join WiFi on the touch UI first (the script pauses for this) and the
> script re-enables tcpip over USB afterward. A static DHCP lease keeps the IP
> stable across runs.

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

### Tier 2 — Permanent SELinux policy patch (VALIDATED; now automated)

> **`flash-mabu.ps1` applies this automatically as Phase 7.** The manual steps
> below are reference only — follow them if you need to re-apply the fix outside
> of a full flash run, or if you're debugging the automated path.
>
> **Known-good hashes (H7R Android 8.1):**
> - Stock policy: `7f26df2d…`
> - Patched policy: `03f180a2…` (same 299,979 B — bit-flip in the AV table)
> - Vendor partition LBA: `0x5A8AB8` (592 sectors, inode 911, confirmed on two units)

Add one rule so `untrusted_app` can open the serial device directly — then the
bridge is unnecessary and the app talks to `/dev/ttyS1` natively.

**The rule** (also at `../Mabu/selinux/mabu_serial_access.te`):
```
allow untrusted_app serial_device:chr_file { open read write getattr ioctl };
```

This was performed end-to-end on units `2022010501038` and `2022010501537`. The exact procedure,
with the gotchas that actually bit, follows. `/system`/`/vendor` are read-only
with no root, so the patched policy is written by raw eMMC overwrite via Loader.

> **Which file?** On this H7R 8.1 build there is **only** one policy file:
> `/vendor/etc/selinux/precompiled_sepolicy` (299,979 B).
> `/system/etc/selinux/precompiled_sepolicy` **does not exist** — don't chase it.

> **Where magiskpolicy runs — on the Mabu, not the host.** magiskpolicy is an
> Android binary. The staged `../tools/magiskpolicy/magiskpolicy-armeabi-v7a`
> (32-bit ARM, for RK3288) runs **on the device** and patches the policy *file*
> (pure file I/O, no root). We tried extracting an **x86_64** magiskpolicy from
> `Magisk.apk` (`lib/x86_64/libmagiskpolicy.so`) to patch on the host — it is
> **also an Android binary** (interpreter `/system/bin/linker64`) and does **not**
> run in WSL glibc. So: patch on-device, period. (WSL `setools` is only for
> *inspecting* policy, not injection.)

**Step 1 — patch the policy on-device** (Loader not needed yet; do this from an
adb shell — WiFi adb if you'll pull it, see below):
```bash
DEV=<ip>:5555
adb -s $DEV push ../tools/magiskpolicy/magiskpolicy-armeabi-v7a /data/local/tmp/magiskpolicy
adb -s $DEV shell chmod 755 /data/local/tmp/magiskpolicy
adb -s $DEV shell "cp /vendor/etc/selinux/precompiled_sepolicy /data/local/tmp/sepolicy.in && \
  /data/local/tmp/magiskpolicy --load /data/local/tmp/sepolicy.in \
    --save /data/local/tmp/sepolicy.out \
    'allow untrusted_app serial_device chr_file { open read write getattr ioctl }' && echo PATCH_OK"
adb -s $DEV shell "ls -l /data/local/tmp/sepolicy.in /data/local/tmp/sepolicy.out; \
  sha256sum /data/local/tmp/sepolicy.in /data/local/tmp/sepolicy.out"
```
On the validated unit the patch was **byte-for-byte the same size** (299,979 B
in and out) — magiskpolicy only flipped permission bits in the existing
access-vector table. **Same size ⇒ same 74 ext4 blocks ⇒ a raw overwrite is
block-safe** (the Size caveat below never triggered). Confirm `in ≠ out` by hash
so you know the rule was actually added.

**Step 2 — pull the patched policy to the host (use WiFi adb).** A 293 KB `adb
pull` over **USB wedges** (~80–128 KB inbound ceiling per boot — see the
transport note in Section 4). Over WiFi it's instant:
```bash
adb -s $DEV pull /data/local/tmp/sepolicy.out  ../Mabu/firmware/scratch/sepolicy.patched
adb -s $DEV pull /data/local/tmp/sepolicy.in   ../Mabu/firmware/scratch/sepolicy.orig
```

**Step 3 — locate the file's eMMC blocks** with the ext4 inode-walk
`../Mabu/scripts/find-vendor-file.py` (new; the vendor analogue of
`find-esper-files.py`). Reboot to Loader (`adb reboot loader`), dump the vendor
head, and walk to the file:
```powershell
# vendor partition starts at LBA 0x592000. Dump ~24 MB (under the 28 MB
# read-wedge) — enough for the metadata/inodes:
.\tools\rkdeveloptool\rkdeveloptool.exe rl 0x592000 49152 firmware\scratch\vendor-head.img
python scripts\find-vendor-file.py firmware\scratch\vendor-head.img 0x592000 etc selinux precompiled_sepolicy
```
On the validated build the walk resolved root → `etc`(203) → `selinux`(907) →
`precompiled_sepolicy` = **inode 911**, a **single contiguous 74-block extent at
abs LBA `0x5A8AB8`** (592 sectors). *(The selinux directory's own block sat past
24 MB; the script tells you that LBA so you can dump just that one block to read
its dirents. The LBA can differ per build — re-derive it, don't hardcode
`0x5A8AB8` blindly.)*

**Step 4 — verify the location, write, verify the write** (Loader USB is
reliable):
```powershell
# read back the located bytes; the first 299979 must equal sepolicy.orig:
.\tools\rkdeveloptool\rkdeveloptool.exe rl 0x5A8AB8 586 firmware\scratch\readback.bin
#   -> sha256(readback[0..299978]) == sha256(sepolicy.orig)   [confirms location]
# write the patched policy:
.\tools\rkdeveloptool\rkdeveloptool.exe wl 0x5A8AB8 firmware\scratch\sepolicy.patched
# read back and confirm it now equals sepolicy.patched:
.\tools\rkdeveloptool\rkdeveloptool.exe rl 0x5A8AB8 586 firmware\scratch\verify.bin
#   -> sha256(verify[0..299978]) == sha256(sepolicy.patched)  [confirms write]
.\tools\rkdeveloptool\rkdeveloptool.exe rd        # reboot to Android
```

**Step 5 — verify after reboot** (WiFi adb):
```bash
adb connect <ip>:5555
adb -s <ip>:5555 shell "sha256sum /vendor/etc/selinux/precompiled_sepolicy"  # == patched hash
adb -s <ip>:5555 shell "getenforce"                                          # Enforcing
adb -s <ip>:5555 shell "ls -lZ /dev/ttyS1"                                   # ...serial_device:s0
```
On the validated unit all three checked out (patched hash **persisted**,
Enforcing, correct label). Note `/sys/fs/selinux/policy` is root-only, so you
**cannot** hash the live loaded policy as shell — the definitive functional
proof is an `untrusted_app` actually opening `/dev/ttyS1` (run the Facetrack app,
Section 5/7, and confirm motors move with the Tier-1 bridge **off**).

   > **Size caveat (didn't trigger here, but watch for it on other builds):** if
   > magiskpolicy's output is *larger* than the original and spills into an
   > extra 4 KB ext4 block, a raw overwrite would corrupt the next file. Only
   > raw-overwrite when out-size ≤ original block count. Otherwise rebuild and
   > flash the whole `/vendor` (or `/system`) image, or use the AOSP path below.

**Cleanest alternative (if you have an AOSP tree for this board):** drop
`mabu_serial_access.te` into `system/sepolicy/private/`, run `m sepolicy`, and
flash the resulting `precompiled_sepolicy` — no locate/size/round-trip risk. See
`../Mabu/selinux/README.md`.

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

- [ ] Loader caught (PID 320A) — `adb reboot loader` if adb is up, else hold ADKEY (pin 4)→GND through power-on
- [ ] **PID 320A bound to WinUSB** (not `rockusb.sys`) — `flash-mabu.ps1` auto-launches Zadig if not; one-time per PC, then persists. `ld` listing the Loader is *not* proof: a `rockusb.sys` binding writes-fail with "creating comm object failed"
- [ ] `flash-mabu.ps1 -RestoreMabu` completes — confirm the "Detected State X" / "Wipe policy" line matches the unit (force with `-WipeData`/`-NoWipe` if needed; re-run wipe if it "FAILED at chunk 0")
- [ ] Device Owner clear, no esper/shoonya packages
- [ ] Re-joined WiFi, WiFi ADB on 5555, static lease set (the working transport for all on-device adb — USB only for the Loader flash + opening adb)
- [ ] Launcher + apps installed
- [ ] **SELinux: Tier 1 bridge running → app moves motors**
- [ ] **SELinux: Tier 2 policy patch applied (optional, permanent)** — magiskpolicy on-device → `find-vendor-file.py` → Loader `wl` → verify persisted + Enforcing → revert app to direct serial
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
rule. The Tier-1 TCP bridge needs none of this (just adb). The validated Tier-2
path is **adb (WiFi) + on-device ARM magiskpolicy + `find-vendor-file.py` +
`rkdeveloptool` + Python** — WSL is **not** actually required for the injection.

| Tool | Source | Verify |
|---|---|---|
| **adb** (WiFi, on 5555) | platform-tools (A.2) | `adb connect <ip>:5555` |
| **magiskpolicy** (binary-policy patcher — runs **on the Mabu**, ARM) | **staged** `../tools/magiskpolicy/magiskpolicy-armeabi-v7a` (Magisk v30.7) | `file` shows "ARM ... for Android" |
| **`find-vendor-file.py`** (ext4 inode-walk → file LBA) | **bundled** `../Mabu/scripts/find-vendor-file.py` | needs **Python 3** on host |
| `rkdeveloptool` (dump + `wl` the policy) | **bundled** (A.2) | `rkdeveloptool ld` |
| Policy rule + reference | **bundled** `assets/selinux/mabu_serial_access.te` | — |
| WSL + `setools`/`policycoreutils` | **winget** `Microsoft.WSL` + `apt` | `seinfo --version` — **inspection only, optional** |

> **Dead end, documented so you don't repeat it:** the **x86_64** magiskpolicy in
> `Magisk.apk` (`lib/x86_64/libmagiskpolicy.so`) is an **Android** binary
> (interpreter `/system/bin/linker64`), so it will **not** run in WSL to patch
> the policy host-side. Patch on the Mabu with the ARM build instead.

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

### A.6 Status on the current flashing PC (updated 2026-06-14)
| Capability | Ready? |
|---|---|
| Flash a new Mabu (A.2) | ✅ **validated end-to-end** on unit `2022010501038` over direct USB 3 (no hub) |
| Deploy a prebuilt APK (adb) | ✅ (USB push or WiFi) |
| **Build** the Android app (A.3) | ✅ Android Studio 2026.1 + bundled JDK 21 installed — **launch once to download the SDK** |
| Permanent SELinux fix (A.4) | ✅ **Tier 2 validated** — patched policy written to `/vendor` precompiled_sepolicy via Loader, persisted + Enforcing after reboot. `magiskpolicy` (ARM) + `find-vendor-file.py` + Python are what's actually used. |

> **Validated-flash facts (unit 2022010501038, H7R 8.1 `OPM6.171019.030.E1`):**
> State-A active Esper; `adb reboot loader` worked on stock; full liberate +
> 96 MB wipe + F-Droid/Lawnchair/factorymode + Tier-2 SELinux all succeeded.
> `/vendor` policy file LBA `0x5A8AB8`. WiFi adb (5555) was essential for pulling
> the policy (USB pulls wedge ~128 KB).

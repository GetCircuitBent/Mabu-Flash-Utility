# Root a fresh Mabu without bricking it — step-by-step

Goal: take a **fresh, working** RK3288 Mabu and end with **persistent uid-0 adb**
(`-KeepRoot`) on a unit that boots cleanly and holds the home screen — without
repeating the bootloop / brick dead-ends.

Read [`ROOT-PATCH.md`](ROOT-PATCH.md) for what the patch does and its security /
SELinux scope. Read [`KEEPROOT-BOOTLOOP-BLOCKED.md`](KEEPROOT-BOOTLOOP-BLOCKED.md)
for the history this checklist is designed to avoid.

## The two things that actually break units (and how we avoid them)
1. **The factory burn-in app `com.cghs.stresstest`** auto-launches after a
   `/data` wipe and reboots the device in a loop. It is NOT caused by the root
   patch. Avoidance: don't wipe unless you must; if you do, expect the loop and
   disable the app on first boot (Phase 1c).
2. **adbd build drift.** The rootdrop patch is a precomputed 512-byte sector that
   assumes a specific `adbd` build. On a different build it corrupts adbd.
   Avoidance: **`verify-root-patch.ps1` gates every `-KeepRoot` flash** (and
   `flash-mabu.ps1 -KeepRoot` now runs the same check automatically).

Both are now enforced by the tooling — see "What changed in the tooling" below.

---

## Preconditions
- Run everything from the repo root: `D:\Claude Projects\MabuFlash\Mabu-Flash-Guide\.claude\worktrees\system-mods`.
- Tablet in the harness, USB **data** cable to a known-good port on this PC.
- `adb`, `rkdeveloptool`, Zadig available (all under `tools/` / winget).

## Phase 0 — get the unit talking
1. Power on normally; confirm Android adb:  `adb devices`  → one `device`.
   (If a second tablet is attached, note its serial and pass `-Dev` explicitly
   everywhere so you never act on the wrong one.)
2. Confirm you can reach Loader when needed: hold **ADKEY** through power-on,
   then `rkdeveloptool ld` should show `Pid=0x320a ... Loader`. First time on
   this PC it binds `rockusb.sys`; `flash-mabu.ps1` auto-launches Zadig to rebind
   320A → WinUSB (writes fail until it's WinUSB). WinUSB binding is per USB
   **port-path** — stay on the same port.

## Phase 1 — liberate + provision to a clean, non-looping boot
Do this FIRST, without root, so you know the unit is healthy before adding root.

- **State B (factory-reset Esper)** — no `/data` wipe needed:
  ```
  .\scripts\flash-mabu.ps1 -NoWipe
  ```
- **State A (active Esper)** — needs the `/data` wipe to drop the live DPC:
  ```
  .\scripts\flash-mabu.ps1 -WipeData
  ```
  (The script auto-detects A vs B from a booted unit; the explicit flag just
  removes ambiguity. It will no longer *silently* wipe on an undetermined state.)

### 1c — if it bootloops after a wipe
Symptom: reaches the boot animation, glitches, reboots (~every 40 s). That's
`com.cghs.stresstest`. During a loop cycle adb briefly enumerates; disable it:
```
adb -s <serial> wait-for-device
adb -s <serial> shell "am force-stop com.cghs.stresstest; pm disable-user --user 0 com.cghs.stresstest"
adb -s <serial> shell "pm list packages -d | grep cghs"   # confirm: package:com.cghs.stresstest
```
`pm disable-user` persists in `/data`, so once it lands the loop stops and the
unit holds the desktop. (A polling helper that hammers this across loop windows
lived in the scratchpad this session — recreate if the window is too tight to
catch by hand.)

**Do not proceed to root until the unit boots clean and holds the home screen.**

## Phase 2 — verify the root patch fits THIS unit (no-go gate)
With the unit booted:
```
.\scripts\verify-root-patch.ps1 -Dev <serial-or-ip:5555>
```
- **GO** (exit 0): live `adbd` sector 29 is byte-identical to the reference — the
  2-byte patch will apply cleanly.
- **NO-GO** (exit 1): this unit ships a different `adbd` build. **Stop.** Rebuild
  the patch against this unit, then re-verify:
  ```
  adb -s <dev> pull /system/bin/adbd firmware/originals/adbd.bin
  python scripts\build_root_patch.py      # asserts the drop-block entry is a `bl`
  .\scripts\verify-root-patch.ps1 -Dev <dev>   # expect GO now
  ```

## Phase 3 — apply root
`flash-mabu.ps1 -KeepRoot` re-runs the Phase-2 check itself and refuses to flash
on a mismatch or from a cold Loader. It never implies a wipe.

`flash-mabu.ps1 -KeepRoot` auto-detects the state and does the right thing:
- **Already-liberated** unit → verifies, re-enters Loader, re-applies the
  liberation patches (idempotent) + rootdrop, **no wipe**, then Phase 7:
  ```
  .\scripts\flash-mabu.ps1 -KeepRoot
  ```
- **Fresh not-yet-liberated** unit → liberates + roots in one go (State B example):
  ```
  .\scripts\flash-mabu.ps1 -NoWipe -KeepRoot
  ```
- Manual equivalent, if you'd rather do it by hand (any liberated unit):
  ```
  .\scripts\verify-root-patch.ps1 -Dev <dev>   # GO/NO-GO (booted)
  .\scripts\liberate-mabu.ps1 -KeepRoot        # in Loader; re-applies patches + rootdrop, no /data touch
  rkdeveloptool rd
  ```

`-KeepRoot` also asks `flash-mabu.ps1` Phase 7 to add a **permissive `shell`
domain** to sepolicy (needed for WiFi `/system` writes). That step has a size
guard and will STOP with instructions if the policy grows (see ROOT-PATCH.md
"SELinux caveat" + size guard) — that's expected, not a failure.

## Phase 4 — verify root + a sustained boot
```
adb connect <ip>:5555
adb -s <ip>:5555 shell id            # expect uid=0(root) gid=0(root)
adb -s <ip>:5555 shell getenforce    # Enforcing (expected)
```
Let it sit ~5 min and confirm it does NOT reboot. If `permissive shell` was
applied, `mount -o remount,rw /system` should now succeed over WiFi; without it,
that still hits the SELinux wall (expected).

## If something goes wrong — non-destructive revert
The rootdrop patch is a single sector; reverting does NOT touch `/data`:
```
# catch Loader, then:
rkdeveloptool wl 1694581 firmware\originals\adbd-rootdrop-orig.bin   # sha e5488942...
rkdeveloptool rl 1694581 1 firmware\scratch\adbd-readback.bin        # verify readback == e5488942...
rkdeveloptool rd
```
Liberation + adb auth-bypass stay intact (different LBAs). The device boots
normally, just without persistent root.

---

## What changed in the tooling (this session)
- `flash-mabu.ps1`:
  - `-KeepRoot` **never implies a `/data` wipe** (was: could inherit an auto/Unknown wipe).
  - Undetermined Esper state now **aborts and asks for `-WipeData`/`-NoWipe`**
    instead of silently wiping (a wrong wipe destroys data and can trigger the
    burn-in loop).
  - `-KeepRoot` runs a **brick guard** (`Confirm-RootPatchApplies`): pulls the
    live `adbd` and refuses to flash if sector 29 doesn't match the reference, or
    if started from a cold Loader (can't verify), or on an already-liberated unit
    (points here for the standalone route).
- New `scripts/verify-root-patch.ps1`: standalone read-only GO/NO-GO check.

## Known limitations / not yet done
- **Phase 7 gating.** The permissive-shell SELinux write still runs after the
  app-provisioning phase; a provisioning transport failure can still abort before
  it. If Phase 7 gets skipped, apply it on its own with the unit booted
  (`Apply-SELinuxFix` path / manual `magiskpolicy` per ROOT-PATCH.md).
- **State A + `-KeepRoot` in one run** is intentionally *not* auto-wiped — you get
  a warning that liberation may be incomplete. Prefer the two-phase route
  (liberate with a wipe first, then root) for active-Esper units.
- None of this session's changes are hardware-tested yet — validate on the fresh
  unit and update this doc with what actually happened.

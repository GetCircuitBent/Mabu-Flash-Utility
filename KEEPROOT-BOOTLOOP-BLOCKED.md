# `-KeepRoot` BOOTLOOP — ROOT CAUSE FOUND (not the patch)

## CORRECTION (2026-07-02, later session) — the patch is NOT the cause
Deeper diagnosis DISPROVED the "the rootdrop patch bootloops" conclusion below.
The real cause is a **factory burn-in app**, not the adbd patch:

- **`com.cghs.stresstest`** (system-uid stress/burn-in test) auto-launches at
  boot, drives the UI (endless `am_restart_activity` into Settings screens), and
  **reboots the device** via its `StressTest`/`rebootFlag` receiver
  (`RecoveryReceiver` reads `/mnt/external_sd/Recovery_state`). Caught live in
  `firmware/scratch/bootloop-capture.txt`: `Start proc ...com.cghs.stresstest`,
  then `D/StressTest: onReceive rebootFlag`, then every system service dies at
  once (a clean userspace reboot). No kernel panic (pstore/last_kmsg empty).
- **The rootdrop patch is provably CORRECT for this build.** Pulled the LIVE
  `/system/bin/adbd`: it matches `firmware/originals/adbd.bin` byte-for-byte
  except the 3 known auth-patch bytes (0x1c438/0x1c439/0xd311c). Disassembly
  (capstone) confirms `0xBAA4` is `bl` and `b.w 0xBBBE` lands on the genuine
  keep-root path — the code ALREADY branches there via `bne.w #0xbbbe` at
  `0xBAA0`, with identical register state. So forcing keep-root is sound.

**Fix / plan to actually root it (resume here):**
1. Boot the unit; catch an adb window (they recur ~every 40s, ~20s long during
   the loop — or just when it happens to reach home).
2. `pm disable-user --user 0 com.cghs.stresstest` (persists in /data; also
   `am force-stop` it first). Disable `com.catalia.factorymode` defensively
   (re-enableable — it's the wanted motor-diagnostics app, so re-enable later).
3. With the reboot source gone, the already-applied uid-0 rootdrop patch boots
   and stays up → `adb shell id` should read `uid=0(root)`.
4. Then apply the permissive-shell sepolicy (Phase 7) for WiFi /system writes.

**Current unit state at session close (2026-07-02):** rootdrop patch IS applied
(re-flashed + verified sha `7da6ee29…`). Device last booted to Android. Stress
test NOT yet disabled (host USB adb enumeration was too flaky to land the
`pm disable`). Tooling installed: capstone/keystone/pyelftools in the active
python; `firmware/scratch/` holds `adbd-live.bin`, `bootloop-capture.txt`, the
disassembly, and screencap. Watchers/scripts left in `/tmp` (`killstress2.sh`
etc.).

---
## ORIGINAL (SUPERSEDED) conclusion — kept for history
**The rest of liberation (parameter/verity, adbd auth-bypass, Esper EOCD nukes,
init.esper.rc zero) is fine and unchanged.** The section below hypothesized the
patch itself bootloops (build-offset mismatch); that hypothesis is WRONG per the
correction above — the live-vs-original binary diff proved the offset is right.

## What happened
1. Flashed `flash-mabu.ps1 -KeepRoot`. All 9 Loader writes reported `OK`,
   including `adbd-rootdrop-patched.bin` @ LBA 1,694,581. Device booted into a
   **boot loop**.
2. Recovered, then flashed `-KeepRoot` a second time (device already in Loader).
   Again all 9 writes `OK`; **boot loop again**. Two-for-two → the rootdrop
   patch is the cause, not a transient.

Neither run ever produced a confirmed `uid=0` reading — the device was never
reachable post-flash long enough to verify root (USB adb + WiFi adb both flaky
this session; see "Connectivity" below).

## Recovery (single-sector revert — NON-destructive, /data untouched)
Catch Loader and restore the original adbd sector:
```
rkdeveloptool wl 1694581 firmware/originals/adbd-rootdrop-orig.bin   # sha e5488942...
rkdeveloptool rl 1694581 1 <readback>   # verify readback sha == e5488942...
rkdeveloptool rd
```
This returns adbd to its exact pre-patch bytes. Liberation + adb auth-bypass
stay intact (different LBAs: 1,696,240 / 1,694,778). Device boots normally,
just without persistent root. `/data` is never touched by this.

## Leading hypothesis (MUST verify before any re-flash)
The patch bytes/offset in `firmware/patches/adbd-rootdrop-patched.bin` were
precomputed by `scripts/build_root_patch.py` against a *specific* `adbd.bin`.
If the **on-device** `/system/bin/adbd` build differs, the LBA-1,694,581
byte-164 edit (vaddr `0xBAA4` / file-off `0x3AA4`) lands on the WRONG
instruction, corrupting adbd. `build_root_patch.py` asserts the entry is a `bl`
only against the adbd it is fed — it cannot know the on-device build drifted.

**Correct process next time (do this before re-enabling `-KeepRoot`):**
1. Boot the unit healthy (post-revert), pull the LIVE binary:
   `adb pull /system/bin/adbd ./adbd-live.bin`
2. Re-run `scripts/build_root_patch.py` against `adbd-live.bin` and confirm the
   disassembly finds the drop block at the expected vaddr and the entry is a
   `bl`. Compare the regenerated patched sector to the committed
   `adbd-rootdrop-patched.bin` — if they differ, the committed patch was built
   against the wrong adbd (that is the bug).
3. Only flash `-KeepRoot` after the patch is confirmed to match the live adbd,
   ideally validating on a sacrificial/backed-up unit first.

## Second bug found in `flash-mabu.ps1` (wipe-on-Unknown)
When the device is **already in Loader** at script start, state is classified
`Unknown`, and the wipe policy falls through to the safe-default **`/data wipe:
ON`**. On the second run this triggered — we only avoided a wipe because the
inter-phase reboot-to-Android failed (`No adb after inter-phase reset`) and the
script exited *before* the wipe write. A `-KeepRoot`-only run must **never**
imply a `/data` wipe. Fix needed: `-KeepRoot` (and/or `Unknown` state on an
otherwise-liberated unit) should force `doWipe = $false`, not default to wipe.

(An earlier in-session edit that made `-KeepRoot` apply the rootdrop patch on an
already-`Liberated` unit AND forced no-wipe was **reverted** at the operator's
request — the flash utility is back to its committed baseline. Re-do that fix
properly alongside the wipe-on-Unknown guard when this work resumes.)

## Also unresolved: permissive-shell (Phase 7) never applied
Both runs bailed at the post-reset provisioning transport step, **before**
Phase 7 (`Apply-SELinuxFix -PermissiveShell`). On-device sepolicy is still
`03f180a2` (motor-rule only). Consequence: even a *working* uid-0 adbd would
NOT unlock WiFi `/system` writes — the enforcing `shell` domain still blocks
`mount -o remount,rw /system` (see ROOT-PATCH.md "SELinux caveat"). The full
"WiFi root `/system` push" deliverable needs BOTH halves, and the
permissive-shell half is itself a Loader (USB) write. Phase 7 should not be
gated behind successful app-provisioning — a provisioning flake should not
skip the SELinux policy write.

## Connectivity notes (this session)
- USB adb / Loader enumeration was intermittent — Windows repeatedly saw no
  `VID_2207`/`VID_18D1` node at all. Suspect harness data-line seating. Re-seat
  the internal harness; confirm a Rockchip node enumerates on power-on before
  relying on a Loader catch.
- Quarantine LAN = the wired side (`192.168.0.x`, profile "Network 2", no
  internet). Unit leased `.100`/`.101` earlier but had `5555` closed — the
  patched adbd does not auto-listen on 5555 unless `persist.adb.tcp.port` took;
  WiFi client isolation on the quarantine AP is also possible.

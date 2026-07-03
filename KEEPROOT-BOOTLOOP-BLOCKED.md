# `-KeepRoot` BOOTLOOP — BLOCKED, do not re-flash until diagnosed

**Status (2026-07-02): the `-KeepRoot` adbd uid-0 rootdrop patch bootloops unit
2022010501476. Reproduced TWICE on two independent flashes. Do NOT flash
`-KeepRoot` again until the root cause below is confirmed and fixed.**

The rest of liberation (parameter/verity, adbd auth-bypass, Esper EOCD nukes,
init.esper.rc zero) is fine and unchanged. Only the persistent-root patch is
implicated.

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

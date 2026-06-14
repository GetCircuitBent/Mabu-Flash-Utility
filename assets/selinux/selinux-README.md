# SELinux — serial port access for the Mabu app

## The problem

`/dev/ttyS1` (the motor board serial port) is labeled `u:object_r:serial_device:s0`.
The Mabu face-tracking app runs as `u:r:untrusted_app:s0`. Stock AOSP policy
does not grant `untrusted_app` access to `serial_device`, so all `open()` calls
fail with EACCES even though the file shows `crwxrwxrwx` in `ls`.

Verified AVC denial from unit 4:
```
avc: denied { getattr } for path="/dev/ttyS1"
  scontext=u:r:untrusted_app:s0:c512,c768
  tcontext=u:object_r:serial_device:s0
  tclass=chr_file permissive=0
```

Note: `ro.boot.selinux=permissive` is set by the liberation parameter patch,
but Android init switches to enforcing mode during startup. The boot property
does NOT persist at runtime.

## Tier 1 — TCP motor bridge (no USB required)

`motor-bridge.sh` (in `../bridge/`) runs on the Mabu as the **shell** user —
`u:r:shell:s0`, which IS allowed to open `serial_device`. It opens `/dev/ttyS1`
once and re-exposes it on a local TCP port, `127.0.0.1:7777`. The app
(`MabuMotors.kt`, constants `BRIDGE_HOST=127.0.0.1` / `BRIDGE_PORT=7777`)
connects to that port instead of opening the device itself, so the kernel only
ever sees *shell* touching the motors and SELinux is satisfied.

Start it once per boot (see the bridge header and the main guide §6 Tier 1):
```
adb push motor-bridge.sh /data/local/tmp/
adb shell chmod 755 /data/local/tmp/motor-bridge.sh
adb shell "busybox dos2unix /data/local/tmp/motor-bridge.sh"
adb shell "nohup sh /data/local/tmp/motor-bridge.sh > /data/local/tmp/motor-bridge.log 2>&1 &"
```

## Tier 2 — Permanent SELinux policy patch (Loader required)

Add the rule in `mabu_serial_access.te` to the device SELinux policy:

```
allow untrusted_app serial_device:chr_file { open read write getattr ioctl };
```

This device is **not rooted** and `/system` cannot be remounted rw from a
non-root adb shell, so the patched policy is written back the same way the
liberation patches are: **via the Rockchip Loader**. There is no live `adb push
to /system` path here.

### Option A — magiskpolicy (turnkey, on-device patch) — recommended
The clean way to edit a binary Android policy. Push the ARM `magiskpolicy` to
the Mabu, patch the policy *file* (pure file I/O, no root), pull it back, then
flash it to `/system/etc/selinux/precompiled_sepolicy` (and the `/vendor` copy)
via Loader. Full step-by-step in the main guide **§6 Tier 2**.

### Option B — AOSP build (cleanest, if you have the tree)
1. Copy `mabu_serial_access.te` into `system/sepolicy/private/` (or your
   device-specific sepolicy dir)
2. `m sepolicy`
3. Flash the resulting `precompiled_sepolicy` to `/system/etc/selinux/` via Loader

### Note on `apply-patch.sh`
`apply-patch.sh` is a **reference** for the WSL inspection tooling; it stops
short of a turnkey binary merge and its closing `mount -o rw,remount /system`
steps assume a rooted/AOSP device — they do **not** apply to this non-root unit.
Use the magiskpolicy flow (Option A) for the actual injection.

### After applying the permanent fix
Revert the app to direct serial (every bridge line in `MabuMotors.kt` is marked
`// TEMP`) — or leave the bridge in as a belt-and-suspenders fallback; it won't
be reached once native `/dev/ttyS1` opens successfully.

## Files

| File | Purpose |
|---|---|
| `mabu_serial_access.te` | The single policy rule needed |
| `apply-patch.sh` | WSL script for patching (USB required) |
| `sepolicy.bin` | Binary policy pulled from unit 4 on 2026-05-28 (reference) |

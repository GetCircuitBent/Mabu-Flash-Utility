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

## Temporary workaround (no USB required)

`AdbShellBridge.kt` in the app connects to the local adbd daemon
(`127.0.0.1:5555`) over TCP and routes motor commands through a persistent
shell session. The shell runs as `u:r:shell:s0` which IS allowed to write
`serial_device`. Since the liberation patched adbd to remove authentication,
no key exchange is needed.

The app tries native serial first, falls back to ADB automatically.

## Permanent fix (requires USB access to write /system)

Add the rule in `mabu_serial_access.te` to the device SELinux policy:

```
allow untrusted_app serial_device:chr_file { open read write getattr ioctl };
```

### Option A — AOSP build (cleanest)
1. Copy `mabu_serial_access.te` into `system/sepolicy/private/` (or your
   device-specific sepolicy dir)
2. `m sepolicy`
3. Flash `out/.../precompiled_sepolicy` to `/system/etc/selinux/`

### Option B — Patch running policy (WSL, USB required)
Run `apply-patch.sh` — see comments inside for full procedure.

### After applying the permanent fix
Remove the `AdbShellBridge` fallback from `MabuMotors.open()` (or leave it
in as a belt-and-suspenders fallback — it won't be reached if native serial
opens successfully).

## Files

| File | Purpose |
|---|---|
| `mabu_serial_access.te` | The single policy rule needed |
| `apply-patch.sh` | WSL script for patching (USB required) |
| `sepolicy.bin` | Binary policy pulled from unit 4 on 2026-05-28 (reference) |

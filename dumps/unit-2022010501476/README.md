# Liberated Mabu Dump — Unit 2022010501476

`/system` and `/vendor` pulled over **WiFi ADB** (not the Loader — the raw-eMMC
USB dump wedges on long reads; see `notes/HANDOFF.md` in kendrick90/Mabu for
that dead end) from a **confirmed-liberated** unit, 2026-07-02.

## Liberation Confirmed
```
ro.boot.veritymode = disabled
ro.boot.selinux     = permissive
ro.device_owner     = false
pm list packages | grep -iE 'esper|shoonya'   -> (empty)
ro.serialno          = 2022010501476
ro.build.fingerprint  = rockchip/H7R/H7R:8.1.0/OPM6.171019.030.E1/203133:user/release-keys
```

## Contents
| File | Size | Files | SHA-256 |
|---|---|---|---|
| `system-clean.tar` | 697,530,880 B | 1618 | `11bd841e33702c21ff048917e2ff824ae353097489dab09186ad782d5e3aaf3a` |
| `vendor-clean.tar` | 113,608,192 B | 887 | `fc6ff227e8a116881cb3427b20033b98e1a5d1827b900894b5ad88dba750562b` |

Both hashes verified against the on-device copy (`adb shell sha256sum`) before
and after transfer. Tracked via **Git LFS** (`dumps/**/*.tar`).

## How These Were Built (and why not plain `tar -C / system`)
A naive `tar -cf ... system` on-device writes a malformed header for every
file it can't open (root-only files like `/system/build.prop`), corrupting
the archive for downstream extraction after the first bad entry. Fix: build
a file list of only readable regular files first, then `tar -cf out -T
filelist`:
```bash
find system -type f 2>/dev/null | while read f; do [ -r "$f" ] && echo "$f"; done > filelist.txt
tar -cf out.tar -T filelist.txt
```
`/system`: 1624 total files, 1618 readable (6 root-only, e.g. `build.prop`,
skipped). `/vendor`: 891 total, 887 readable.

## Regenerating / Extracting
```bash
tar -xf system-clean.tar -C extracted   # -> extracted/system/...
tar -xf vendor-clean.tar -C extracted   # -> extracted/vendor/...
```
`extracted/` is gitignored (regenerate locally; don't commit the unpacked
tree). Verified to extract cleanly with zero errors (2026-07-02).

## Known Gaps
The 6 unreadable `/system` files and 4 unreadable `/vendor` files (all
root-only, e.g. `build.prop`) are **not** in this dump. None of them are
`/system/media/bootanimation.zip` (`sha256 a2c144b14b470735b619724076d957344286f383c921055f04c6fb968fb7af21`,
1,870,133 B — confirmed present and hash-matched against the device).

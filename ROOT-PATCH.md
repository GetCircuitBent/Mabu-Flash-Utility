# Persistent-Root adbd Patch (`-KeepRoot`)

> **BLOCKED (2026-07-02): this patch bootloops unit 2022010501476 — reproduced
> twice. Do NOT flash `-KeepRoot` until diagnosed. See
> [`KEEPROOT-BOOTLOOP-BLOCKED.md`](KEEPROOT-BOOTLOOP-BLOCKED.md).**


Makes `/system/bin/adbd` stay **uid 0** instead of dropping to `AID_SHELL`
(2000) at startup, so `adb root` is effectively always on and future changes
can (partly — see the SELinux caveat) be done over WiFi ADB instead of the
Loader harness. Opt-in: `liberate-mabu.ps1 -KeepRoot` /
`flash-mabu.ps1` (wire the flag through if you want it in the full flow).

## What it patches
On a "user" build, `adbd_main()` calls an inlined `should_drop_privileges()`
that always resolves to "drop," then runs a minijail sequence
(`minijail_change_gid(2000)` / `minijail_change_uid(2000)` /
`minijail_enter`). There is also a **keep-root** path in the same function:
`minijail_enter` with *no* uid/gid change (used on debuggable/unlocked
builds).

The patch overwrites the drop-block's entry instruction so every path that
would drop instead branches straight to the keep-root path:

| | vaddr | file off | eMMC LBA | bytes |
|---|---|---|---|---|
| before | `0xBAA4` | `0x3AA4` | 1,694,581 (byte 164) | `00 f0 56 fb` (`bl is_device_unlocked`) |
| after  | `0xBAA4` | `0x3AA4` | 1,694,581 (byte 164) | `00 f0 8b b8` (`b.w 0xBBBE`) |

Two bytes change (the `00 f0` BL/B.W prefix is shared). `0xBBBE` is the
keep-root `minijail_enter`. Both drop entry paths — the `is_device_unlocked
!= 1` branch at `0xB974` and the `should_drop` fall-through at `0xBAA0` —
target `0xBAA4`, so a single instruction covers both.

Verified by round-trip disassembly (capstone) after assembly (keystone); the
patched region decodes to `b #0xbbbe` in full instruction context.

## Artifacts (reproducible)
- `firmware/originals/adbd-rootdrop-orig.bin` — original 512-byte sector 29
- `firmware/patches/adbd-rootdrop-patched.bin` — patched sector
  (sha256 `7da6ee29f642f6ece530dc074965fc3f0ac7e703d48fd4b844051d08883c94cc`)
- `scripts/build_root_patch.py` — rebuilds both from `adbd.bin`; on a
  different adbd build the byte offset drifts, so re-run this (it disassembles
  to find the drop block, and asserts the entry is a `bl` before patching).

The LBA (1,694,581) is derived the same way the existing adbd auth patches
are: adbd file sector 0 sits at eMMC LBA 1,694,552 (cross-checked against the
authreq LBA 1,696,240 and authinit LBA 1,694,778). No overlap with those.

## SECURITY scope — read before enabling
- With this patch, **anyone who can reach ADB on port 5555 gets uid-0 ADB**,
  not just a shell. That is a step up from the existing auth-bypass patch
  (which already gives *shell*-level ADB with no dialog to anyone on the
  network).
- Intended for the **closed Mabu-hotspot deployment**: Mabu runs its own AP
  and only the host device joins it, so the population that can reach ADB is
  whoever can join that AP. The whole security boundary then rests on the
  **hotspot's WPA2/WPA3 password** — make sure it's a real password, not an
  open network or an on-screen default. Note WiFi RF reaches beyond walls;
  "we control the network config" doesn't fully control the radio footprint.
- Do **not** ship this on a unit that joins a shared/again LAN alongside other
  people's devices.

## SELinux caveat — this alone does NOT unlock arbitrary /system writes over WiFi
SELinux on this build is **enforcing** (`ro.secure=1`, `ro.build.type=user`;
the parameter file's `androidboot.selinux=permissive` is ignored on user
builds — that's the whole reason the Tier 2 sepolicy patch exists). uid 0 is
DAC root, but MAC still applies:
- adbd runs in the `adbd` domain; the shell it spawns transitions to the
  `shell` domain **regardless of uid**. So `-KeepRoot` gives you *uid 0 in the
  shell domain*, not an unconfined root.
- The `shell` domain on a locked user build typically **cannot**
  `mount -o remount,rw /system` (needs `mount` + write on `system_file`,
  which the policy doesn't grant). So writing `/system` files over WiFi still
  hits the SELinux wall even with uid 0.

**What uid-0 adbd *does* get you** (real, useful): read any app's private
`/data/data/*`, read/write root-owned files where the shell domain's policy
already allows, run tools that only needed DAC root, and skip the
shell-vs-root friction for `/data`, props, etc.

**This is now paired into `-KeepRoot`.** When you flash with `-KeepRoot`,
`flash-mabu.ps1` Phase 7 adds `permissive shell` to the sepolicy alongside the
motor rule (same on-device `magiskpolicy` mechanism), so the shell domain is
unconfined and uid-0 adbd can remount + write `/system` over WiFi. So the full
pair (`-KeepRoot` = adbd uid-0 patch **+** permissive shell) is what actually
delivers "WiFi /system writes."

**Size guard — the reason this isn't a fully hands-off step.** The motor rule
was a same-size bit-flip (299,979 B), so the raw Loader overwrite (`wl` at the
policy's data blocks) was block-safe with no inode change. `permissive shell`
may *grow* the binary policy. Phase 7 measures `sepolicy.out` on-device and
picks one of two paths, decisively, based on that measurement — no partial
"does it still fit the allocated blocks" case:
- **same size** → surgical write, as before (no WSL needed);
- **any size change at all** → automatic fallback to a full `/vendor` reflash:
  dumps the 256 MB `/vendor` partition over WiFi ADB (`dump-system-cycled.ps1`),
  loop-mounts it in WSL2 + Ubuntu, swaps in the patched policy file, then
  reflashes the whole partition via Loader. This sidesteps the inode `i_size`
  problem entirely — a full-partition reflash carries its own filesystem
  metadata, so there's nothing to hand-patch.

The reflash fallback requires WSL2 + Ubuntu (`scripts\install-tools.ps1`
installs it). If it isn't available, Phase 7 warns and leaves the unit
unmodified rather than writing a truncated policy — it will not guess.
(The `permissive`-ebitmap growth is often zero or a few bytes, so the
same-size fast path frequently applies — but it's measured live, not assumed.)

Until the pair is flashed, `/system` changes (like the boot animation) still
go through the Loader harness path in `assets/bootanimation/DEPLOY.md`.

## Verify after flashing
```powershell
adb connect <ip>:5555
adb -s <ip>:5555 shell id            # expect uid=0(root) gid=0(root)
adb -s <ip>:5555 shell getenforce    # still Enforcing (expected)
# quick MAC reality check — will FAIL under enforcing shell domain, confirming
# the caveat above; success would mean the domain policy already allows it:
adb -s <ip>:5555 shell "mount -o remount,rw /system" ; echo $?
```

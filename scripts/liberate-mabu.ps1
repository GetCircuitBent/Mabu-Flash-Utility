# liberate-mabu.ps1
#
# One-shot liberation script for Mabu/H7R RK3288 Android 8.1 tablets running
# Esper kiosk. Applies the minimum set of Loader-side patches needed to:
#
#   * Boot Android with dm-verity disabled and SELinux permissive
#     (parameter file kernel cmdline patch)
#   * Make adbd skip authentication so `adb shell` works immediately without
#     a user-tap-through dialog (two byte-level patches inside /system/bin/adbd)
#
# After running this, reset the device. On boot, ADB shell becomes
# unconditionally available. From shell you can pull the original Mabu
# software off /data before any destructive wipe:
#
#   adb shell tar cf /sdcard/mabu-backup.tar /data/data/com.catalia.* /data/app/com.catalia.*
#   adb pull /sdcard/mabu-backup.tar
#
# This does NOT corrupt Esper APKs and does NOT wipe /data. The Esper kiosk
# will still launch on boot, but adbd is open so you can do anything from
# the host. After extracting Mabu data, run the destructive de-Esper steps
# (corrupt APK EOCDs, wipe /data) using the same scripts.
#
# Usage:
#   Boot tablet into Rockchip Loader (PID 0x320A), USB connected, then:
#   .\liberate-mabu.ps1                  # apply patches
#   .\liberate-mabu.ps1 -DryRun          # show what would be done
#   .\liberate-mabu.ps1 -Reset           # also send 'rd' afterwards
#
# Patches applied (LBAs are absolute sectors on the eMMC):
#   1. Parameter file (sector 0)
#        whole 8 KB rewritten with veritymode=disabled, selinux=permissive,
#        Rockchip CRC32 recomputed. Source: firmware/patches/parameter-patched.img
#   2. /system/bin/adbd at file offset 0xD311C (auth_required global)
#        sector LBA 1,696,240, byte 284: 0x01 -> 0x00
#   3. /system/bin/adbd at file offset 0x1C438 (adbd_auth_init prologue)
#        sector LBA 1,694,778, byte 56-57: 0xF0,0xB5 -> 0x70,0x47 (BX LR)
#   4. Esper APK EOCD signatures zeroed (PackageManager skips):
#        espersupervisor.apk at LBA 1,851,238
#        esperdpc.apk        at LBA 1,981,802
#        esperhelper.apk     at LBA 2,063,565
#   5. /system/etc/init/init.esper.rc data block at LBA 2,076,672 zeroed
#        (kills the set-device-owner init service definition)
#   6. /system/bin/set-device-owner.sh data block at LBA 1,691,408 zeroed
#        (defense-in-depth no-op script)
#
# Optional (-KeepRoot):
#   7. /system/bin/adbd adbd_main() privilege-drop bypass
#        adbd_main() at vaddr 0xBAA4 (file off 0x3AA4, LBA 1,694,581 byte 164):
#        the drop-block entry `bl is_device_unlocked` (00 f0 56 fb) is replaced
#        with `b.w 0xBBBE` (00 f0 8b b8), an unconditional jump to the
#        keep-root path (minijail_enter with no change_uid/change_gid). This
#        makes adbd stay uid 0 instead of dropping to AID_SHELL (2000), so
#        `adb root` state is effectively always on. See ROOT-PATCH.md.
#        SECURITY: anyone who can reach ADB (port 5555) then has uid-0 ADB,
#        not just shell. Intended for the closed Mabu-hotspot deployment model
#        where only the host device joins Mabu's own AP. Also: uid 0 is still
#        confined by *enforcing* SELinux (shell domain) — this alone does NOT
#        grant arbitrary /system writes over WiFi; that needs an SELinux
#        relaxation too (see ROOT-PATCH.md "SELinux caveat").

[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $Reset,
    [switch] $KeepRoot,             # opt-in persistent uid-0 adbd patch (see -KeepRoot note above)
    [switch] $AllowKnownBrokenRoot  # override the KNOWN-BROKEN -KeepRoot gate (patch-rework re-testing ONLY)
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Rk   = Join-Path $Root 'tools\rkdeveloptool\rkdeveloptool.exe'

# -KeepRoot safety gate -- the rootdrop patch is KNOWN-BROKEN on the H7R build.
# PROVEN 2026-07-07 (unit 2022010500003): the patched adbd does not come up (no USB
# adb gadget, no TCP listener) -> adb dies, root NOT achieved. The write is correct;
# the patched adbd is non-functional at runtime. Reverting the sector to stock restores
# adb. Rework the patch before use. See ROOT-PATCH.md / mabuflash-keeproot-hardening.
if ($KeepRoot -and -not $AllowKnownBrokenRoot) {
    Write-Host "-KeepRoot rootdrop patch is KNOWN-BROKEN on this H7R build: the patched adbd" -ForegroundColor Red
    Write-Host "does not start (no adb, no root). Proven 2026-07-07 on unit 2022010500003;" -ForegroundColor Red
    Write-Host "reverting the sector to stock restored adb. Rework the patch first." -ForegroundColor Red
    Write-Host "To re-test a REWORKED patch, re-run with -AllowKnownBrokenRoot." -ForegroundColor Red
    exit 1
}

function Test-Loader {
    $out = & $Rk ld 2>&1
    return ($out -match 'Vid=0x2207,Pid=0x320a.*Loader')
}

if (-not (Test-Loader)) {
    Write-Host "Loader (PID 0x320A) not present. Power-cycle the tablet to catch the Loader window." -ForegroundColor Red
    exit 1
}
Write-Host "Loader detected." -ForegroundColor Green

# Inputs that must exist (precomputed patches)
$inputs = @(
    @{ Name='parameter-patched.img';        Lba=0;       File='firmware/patches/parameter-patched.img' },
    @{ Name='adbd-authreq-patched.bin';     Lba=1696240; File='firmware/patches/adbd-authreq-patched.bin' },
    @{ Name='adbd-authinit-patched.bin';    Lba=1694778; File='firmware/patches/adbd-authinit-patched.bin' },
    # Esper APK EOCD nukes (PackageManager skips on next scan)
    @{ Name='espersupervisor-eocd-zero';    Lba=1851238; File='firmware/patches/espersupervisor-apk-eocd-patched.bin' },
    @{ Name='esperdpc-eocd-zero';           Lba=1981802; File='firmware/patches/esperdpc-apk-eocd-patched.bin' },
    @{ Name='esperhelper-eocd-zero';        Lba=2063565; File='firmware/patches/esperhelper-apk-eocd-patched.bin' },
    # Esper init script + set-device-owner.sh zeroed (size in inode stays, content is NUL)
    @{ Name='set-device-owner.sh-zero';     Lba=1691408; File='firmware/patches/zeros-4k.bin' },
    @{ Name='init.esper.rc-zero';           Lba=2076672; File='firmware/patches/zeros-4k.bin' }
)

# Opt-in persistent-root patch (adbd privilege-drop bypass). See -KeepRoot note above.
if ($KeepRoot) {
    $inputs += @{ Name='adbd-rootdrop-patched.bin'; Lba=1694581; File='firmware/patches/adbd-rootdrop-patched.bin' }
    Write-Host "-KeepRoot: persistent uid-0 adbd patch INCLUDED (see ROOT-PATCH.md for scope + SELinux caveat)." -ForegroundColor Yellow
}
foreach ($i in $inputs) {
    $p = Join-Path $Root $i.File
    if (-not (Test-Path $p)) {
        Write-Host "Missing required patch payload: $p" -ForegroundColor Red
        exit 1
    }
}

foreach ($i in $inputs) {
    $p = Join-Path $Root $i.File
    $size = (Get-Item $p).Length
    Write-Host ("[patch] {0,-32} LBA={1,10} (0x{1:X}) size={2:N0} bytes" -f $i.Name, $i.Lba, $size) -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "        (dry-run, not writing)" -ForegroundColor DarkGray
        continue
    }
    $out = & $Rk wl $i.Lba $p 2>&1
    if ($out -notmatch '100%') {
        Write-Host "        WRITE FAILED: $out" -ForegroundColor Red
        exit 1
    }
    Write-Host "        OK" -ForegroundColor Green
}

if ($Reset -and -not $DryRun) {
    Write-Host "Resetting device..." -ForegroundColor Cyan
    & $Rk rd 2>&1 | Out-Host
}

Write-Host ""
Write-Host "Liberation patches applied. Next steps:" -ForegroundColor Green
Write-Host "  1. Reboot the tablet (use -Reset, or 'rkdeveloptool rd' manually)."
Write-Host "  2. Once Android boots, 'adb devices' should show the device as 'device' without any dialog."
Write-Host "  3. Pull Mabu software:"
Write-Host "       adb shell tar cf /sdcard/mabu-backup.tar /data/data/com.catalia.* /data/app/com.catalia.* /data/misc/sounds 2>/dev/null"
Write-Host "       adb pull /sdcard/mabu-backup.tar ./mabu-<serial>-backup.tar"
Write-Host "  4. (Optional) De-Esper this unit: corrupt Esper APK EOCDs and wipe /data"
Write-Host "     using the per-APK *-apk-eocd-patched.bin sectors and zeros-16mb.bin."

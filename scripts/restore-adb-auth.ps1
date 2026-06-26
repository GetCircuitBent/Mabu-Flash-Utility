# restore-adb-auth.ps1
#
# Reverts the two adbd byte patches applied by liberate-mabu.ps1, so the
# tablet returns to standard Android ADB authentication: any host trying
# to connect (USB or WiFi at port 5555) must be approved via the
# "Allow ADB debugging from this computer?" dialog on the touch UI.
#
# Use this when you're done provisioning a unit and about to ship/deploy
# it onto a network you don't fully trust. Without this, anyone on the
# LAN can `adb connect <ip>:5555` and get a shell, because our patches
# disabled the auth check entirely.
#
# Pre-reqs:
#   - Device in Rockchip Loader (PID 0x320A). If currently in Android,
#     get there with `adb -s <serial> shell reboot loader`.
#   - firmware/originals/adbd-authreq-orig.bin and adbd-authinit-orig.bin must
#     exist (they were captured during the unit-2 liberation session).
#
# What's preserved: the parameter patch (verity off + selinux
# permissive), Esper APK EOCD nukes, init.esper.rc / set-device-owner.sh
# zeros, /data state. Only the adbd auth bytes are reverted.
#
# Usage:
#   .\restore-adb-auth.ps1            # write originals
#   .\restore-adb-auth.ps1 -Reset     # also send 'rd' to reboot
#   .\restore-adb-auth.ps1 -DryRun    # show what would be done

[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $Reset
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Rk   = Join-Path $Root 'tools\rkdeveloptool\rkdeveloptool.exe'

$out = & $Rk ld 2>&1
if ($out -notmatch 'Vid=0x2207,Pid=0x320a.*Loader') {
    Write-Host 'Loader not present. Power-cycle the tablet (or run "adb shell reboot loader") first.' -ForegroundColor Red
    exit 1
}
Write-Host 'Loader detected.' -ForegroundColor Green

$inputs = @(
    @{ Name='adbd-authreq-orig';  Lba=1696240; File='firmware/originals/adbd-authreq-orig.bin'  },
    @{ Name='adbd-authinit-orig'; Lba=1694778; File='firmware/originals/adbd-authinit-orig.bin' }
)
foreach ($i in $inputs) {
    $p = Join-Path $Root $i.File
    if (-not (Test-Path $p)) { Write-Host "Missing payload: $p" -ForegroundColor Red; exit 1 }
}

foreach ($i in $inputs) {
    $p = Join-Path $Root $i.File
    Write-Host ("[revert] {0,-22} LBA={1,10} (0x{1:X})" -f $i.Name, $i.Lba) -ForegroundColor Cyan
    if ($DryRun) { Write-Host '         (dry-run)' -ForegroundColor DarkGray; continue }
    $r = & $Rk wl $i.Lba $p 2>&1
    if ($r -notmatch '100%') { Write-Host "         FAILED: $r" -ForegroundColor Red; exit 1 }
    Write-Host '         OK' -ForegroundColor Green
}

if ($Reset -and -not $DryRun) {
    Write-Host 'Resetting device...' -ForegroundColor Cyan
    & $Rk rd 2>&1 | Out-Host
}

Write-Host ''
Write-Host 'adbd auth restored. On next boot:' -ForegroundColor Green
Write-Host '  - First USB or WiFi ADB connection from any host will trigger'
Write-Host '    the "Allow ADB debugging from this computer?" dialog on the'
Write-Host '    tablet touch UI. Tap Allow (or Always allow) once per host.'
Write-Host '  - Existing trusted host keys in /data/misc/adb/adb_keys are honored.'
Write-Host '  - LAN scanners that try to connect will sit at "unauthorized" until'
Write-Host '    someone taps the dialog on the device.'

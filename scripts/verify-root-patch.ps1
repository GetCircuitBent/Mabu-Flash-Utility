# verify-root-patch.ps1
#
# READ-ONLY go/no-go check for the -KeepRoot rootdrop patch. Run it against a
# BOOTED unit (USB serial or WiFi ip:5555) before ever flashing -KeepRoot.
#
# Why: the rootdrop patch overwrites adbd's sector 29 (file offset 0x3A00, 512
# bytes) with a PRECOMPUTED sector that differs from the reference by exactly 2
# bytes (the privilege-drop -> keep-root branch). That write is only safe if the
# target unit's live adbd sector 29 is byte-identical to the reference the patch
# was built from (firmware/originals/adbd-rootdrop-orig.bin, sha e5488942...).
# If the unit ships a different adbd build, the offset drifts and the write
# clobbers unrelated bytes -> corrupt adbd (adb / boot break). This script pulls
# the live adbd and compares, so you find out BEFORE flashing, not after.
#
# It writes nothing to the device and nothing to the repo except a scratch copy
# of the pulled adbd. Exit code 0 = GO, non-zero = NO-GO.
#
# Usage:
#   .\scripts\verify-root-patch.ps1                      # auto-find a booted adb device
#   .\scripts\verify-root-patch.ps1 -Dev 192.168.0.42:5555
#   .\scripts\verify-root-patch.ps1 -Dev <usb-serial>
#   .\scripts\verify-root-patch.ps1 -File some-adbd.bin  # check an already-pulled binary

[CmdletBinding()]
param(
    [string] $Dev,     # adb serial or ip:5555; auto-detected if omitted
    [string] $File     # skip the pull and check this local adbd binary instead
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
# Same candidate order as Find-Adb in the flashers -- keep them in step. This
# used to check only the winget package dir, so on a winget-less PC $ADB was
# silently $null and the start-server call below failed obscurely.
function Find-Adb {
    $repo = Join-Path $Root 'tools\platform-tools\adb.exe'
    if (Test-Path $repo) { return $repo }
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path $sdk) { return $sdk }
    $wgBase = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path $wgBase) {
        $hit = Get-ChildItem "$wgBase\Google.PlatformTools_*\platform-tools\adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}
$ADB  = Find-Adb
$orig = Join-Path $Root 'firmware/originals/adbd-rootdrop-orig.bin'

function Ok($m)   { Write-Host "  [OK]    $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [NO-GO] $m" -ForegroundColor Red }
function Info($m) { Write-Host "  $m" -ForegroundColor Gray }

Write-Host "=== verify-root-patch (read-only) ===" -ForegroundColor Cyan

if (-not (Test-Path $orig)) { Bad "Missing reference $orig"; exit 2 }
$origSector = [System.IO.File]::ReadAllBytes($orig)
if ($origSector.Length -ne 512) { Bad "Reference is $($origSector.Length) bytes, expected 512"; exit 2 }

# --- obtain the adbd binary to check ---
if ($File) {
    if (-not (Test-Path $File)) { Bad "File not found: $File"; exit 2 }
    $live = (Resolve-Path $File).Path
    Info "Checking local file: $live"
} else {
    if (-not $ADB) { Bad 'adb.exe not found (platform-tools).'; exit 2 }
    $ErrorActionPreference = 'Continue'; & $ADB start-server 2>&1 | Out-Null
    if (-not $Dev) {
        $line = @(& $ADB devices 2>&1 | Where-Object { $_ -match '^\S+\s+device$' })
        if ($line.Count -eq 0) { Bad 'No booted adb device found. Pass -Dev <serial|ip:5555> or boot the unit.'; exit 2 }
        $Dev = ($line[0] -split '\s+')[0]
    }
    Info "Device: $Dev"
    $alive = & $ADB -s $Dev shell 'echo OK' 2>&1
    if ($alive -notmatch 'OK') { Bad "adb shell not responding on $Dev."; exit 2 }
    $scratch = Join-Path $Root 'firmware/scratch'
    New-Item -ItemType Directory -Force $scratch | Out-Null
    $live = Join-Path $scratch 'adbd-live.bin'
    Remove-Item $live -ErrorAction SilentlyContinue
    Info 'Pulling /system/bin/adbd ...'
    & $ADB -s $Dev pull /system/bin/adbd $live 2>&1 | Out-Null
    if (-not (Test-Path $live)) { Bad 'Could not pull /system/bin/adbd.'; exit 2 }
}

$bytes = [System.IO.File]::ReadAllBytes($live)
Info "adbd size: $($bytes.Length) bytes"
if ($bytes.Length -lt 0x3C00) { Bad "adbd too small ($($bytes.Length) B) -- unexpected build."; exit 2 }

# --- compare sector 29 (file offset 0x3A00, 512 B) ---
$diff = @()
for ($i = 0; $i -lt 512; $i++) { if ($bytes[0x3A00 + $i] -ne $origSector[$i]) { $diff += (0x3A00 + $i) } }

# The patch site itself: file offset 0x3AA4, expected pre-patch bytes 00 F0 56 FB
# (the `bl is_device_unlocked` the patch rewrites to `b.w 0xBBBE`).
$site = $bytes[0x3AA4..0x3AA7]
$siteHex = ($site | ForEach-Object { $_.ToString('X2') }) -join ' '
Info "patch-site bytes @0x3AA4: $siteHex (reference expects 00 F0 56 FB)"

if ($diff.Count -eq 0) {
    Ok 'Live adbd sector 29 is byte-identical to the reference.'
    Ok 'GO: the rootdrop patch will apply cleanly (2-byte edit only, nothing else clobbered).'
    exit 0
} else {
    Bad "Live adbd sector 29 differs from the reference at $($diff.Count) byte(s) (first at 0x$("{0:X}" -f $diff[0]))."
    Bad 'This unit ships a different adbd build. Flashing the precomputed patch would corrupt adbd.'
    Info 'Rebuild the patch against THIS unit before using -KeepRoot:'
    Info "  1. adb -s $Dev pull /system/bin/adbd firmware/originals/adbd.bin"
    Info '  2. python scripts/build_root_patch.py'
    Info '  3. re-run this check; expect GO, then flash -KeepRoot.'
    exit 1
}

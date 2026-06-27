# wipe-data-head.ps1
#
# Wipes the first N MB of the /data partition by writing zeros from the
# Rockchip Loader. On next boot, vold detects the corrupt filesystem and
# reformats /data fresh -- effectively a factory reset that ALSO clears
# the Device Owner reference (which a normal Settings -> factory reset
# does NOT clear; Esper provisioned with FRP-style persistence).
#
# Sweet spot per session 2 testing: ~96 MB. Smaller wipes may not
# trigger a full reformat; larger wipes (256+ MB on first unit) led to
# a partially-broken /data init where Settings' Developer Options
# crashed. 96 MB worked cleanly on the second unit and left Developer
# Options functional.
#
# Run AFTER liberate-mabu.ps1 -Reset on units that need to lose the
# Esper Device Owner reference (active-kiosk units, or factory-reset
# units where you want a fully clean DPM state).
#
# Usage:
#   .\wipe-data-head.ps1                  # default 96 MB (6 x 16 MB)
#   .\wipe-data-head.ps1 -SizeMB 128      # custom size
#   .\wipe-data-head.ps1 -Reset           # also send 'rd' after

[CmdletBinding()]
param(
    [int]    $SizeMB = 96,
    [switch] $Reset
)

$ErrorActionPreference = 'Stop'
$Root  = Split-Path -Parent $PSScriptRoot
$Rk    = Join-Path $Root 'tools\rkdeveloptool\rkdeveloptool.exe'
$Zeros = Join-Path $Root 'firmware\patches\zeros-16mb.bin'

# /data partition starts at sector 0x692400 per parameter file
$BaseLBA  = 0x692400
$ChunkSec = 32768            # 16 MB per chunk -> matches zeros-16mb.bin
$NChunks  = [Math]::Ceiling($SizeMB / 16)

if (-not (Test-Path $Zeros)) {
    Write-Host "Missing zeros payload: $Zeros" -ForegroundColor Red
    exit 1
}

# Check Loader presence
$out = & $Rk ld 2>&1
if ($out -notmatch 'Vid=0x2207,Pid=0x320a.*Loader') {
    Write-Host "Loader (PID 0x320A) not present. Power-cycle the tablet first." -ForegroundColor Red
    exit 1
}
Write-Host ("Wiping {0} MB of /data starting at LBA 0x{1:X}..." -f ($NChunks*16), $BaseLBA) -ForegroundColor Cyan

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$completed = 0
for ($i = 0; $i -lt $NChunks; $i++) {
    $lba = $BaseLBA + $i * $ChunkSec
    # Run rkdeveloptool via a .NET process, NOT Start-Process. Two reasons:
    #  1. We control the argument string, so the payload path is quoted properly
    #     -- a repo path with a space ("...\Claude Projects\...") otherwise
    #     reaches rkdeveloptool as extra args -> "Parameter of [WL] command is
    #     invalid" (it looked like a chunk-0 "wedge" but the write never ran).
    #  2. Start-Process -PassThru misreports ExitCode here (it returned nonzero
    #     even when the 16 MB write completed at 100%). A real Process gives the
    #     true exit code, and WaitForExit(timeout) still guards a genuine wedge.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $Rk
    $psi.Arguments              = ('wl {0} "{1}"' -f $lba, $Zeros)
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $null = $proc.StandardOutput.ReadToEndAsync()   # drain pipes so it can't block
    $null = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(45000)) {
        Write-Host ("  WEDGED at chunk {0} (LBA 0x{1:X}) after 45s -- killing" -f $i, $lba) -ForegroundColor Red
        try { $proc.Kill() } catch {}
        Get-Process rkdeveloptool -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        break
    }
    if ($proc.ExitCode -ne 0) {
        Write-Host ("  FAILED at chunk {0} (exit {1}) -- Loader probably wedged" -f $i, $proc.ExitCode) -ForegroundColor Red
        break
    }
    $completed = $i + 1
    if ($completed % 4 -eq 0) {
        Write-Host ("       {0} MB done ({1:N1}s)" -f ($completed*16), $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
    }
}
$sw.Stop()
Write-Host ("Wipe done: {0} MB written in {1:N1}s" -f ($completed*16), $sw.Elapsed.TotalSeconds) -ForegroundColor Green

if ($completed -lt 1) {
    Write-Host "No chunks completed. Loader wedged from the start. Power-cycle and retry." -ForegroundColor Yellow
    exit 1
}

# Even a partial wipe (e.g. 32-96 MB) is usually enough for vold to
# detect corruption and trigger a fresh reformat on next boot.

if ($Reset) {
    Write-Host "Resetting device..." -ForegroundColor Cyan
    & $Rk rd 2>&1 | Out-Host
}

Write-Host ""
Write-Host "Next steps after device boots:" -ForegroundColor Green
Write-Host "  1. Wait for Android to come up (will take longer than usual on first boot --"
Write-Host "     vold needs to reformat /data)."
Write-Host "  2. 'adb devices' should show the device as 'device'."
Write-Host "  3. 'adb shell dumpsys device_policy' -- 'Enabled Device Admins' should be empty."
Write-Host "  4. Install a launcher (F-Droid + KISS, or your APK of choice)."

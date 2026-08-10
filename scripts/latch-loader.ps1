# latch-loader.ps1
#
# Polls for the Rockchip Loader (VID 0x2207 PID 0x320A) during the ~10 second
# power-on window and confirms it is latched and ready for rkdeveloptool.
#
# Pre-req: WinUSB must be bound to PID 0x320A (one-time Zadig step).
#          tools/rockchip-stock/RKDevTool_Release_v2.92 -> Read Flash Info
#          latches the Loader; then Zadig -> replace driver with WinUSB.
#          On a PC that has flashed before this persists automatically.
#
# Usage:
#   1. Make sure the tablet is powered OFF.
#   2. Run this script.
#   3. Power the tablet ON -- the script catches Loader automatically.
#
#   .\scripts\latch-loader.ps1
#   .\scripts\latch-loader.ps1 -TimeoutSec 30

[CmdletBinding()]
param(
    [int] $TimeoutSec = 60,
    [int] $PollMs     = 400
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$RK   = Join-Path $Root 'tools\rkdeveloptool\rkdeveloptool.exe'

if (-not (Test-Path $RK)) {
    Write-Host "rkdeveloptool not found at: $RK" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "==== Waiting for Rockchip Loader (PID 0x320A) ====" -ForegroundColor Cyan
Write-Host "  Power the tablet ON now. Loader window is ~10 seconds." -ForegroundColor Yellow
Write-Host ""

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$found    = $false
$dots     = 0

while ((Get-Date) -lt $deadline) {
    $out = & $RK ld 2>&1
    if ($out -match 'Vid=0x2207,Pid=0x320a.*Loader') {
        $found = $true
        break
    }
    Write-Host -NoNewline '.'
    $dots++
    if ($dots % 60 -eq 0) { Write-Host "" }
    Start-Sleep -Milliseconds $PollMs
}

Write-Host ""

if (-not $found) {
    Write-Host ""
    Write-Host "  Loader not seen within ${TimeoutSec}s." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Troubleshooting:" -ForegroundColor Yellow
    Write-Host "    - WinUSB not bound to PID 0x320A: open Zadig, select the Rockchip" -ForegroundColor Yellow
    Write-Host "      device, replace driver with WinUSB. Or open RKDevTool and click" -ForegroundColor Yellow
    Write-Host "      'Read Flash Info' to latch Loader first, then swap in Zadig." -ForegroundColor Yellow
    Write-Host "    - D+/D- polarity wrong on harness: swap OTG_DM / OTG_DP wires." -ForegroundColor Yellow
    Write-Host "    - Try a different USB port or cable." -ForegroundColor Yellow
    Write-Host "    - Reboot the PC to clear stale VID_2207 ghost nodes." -ForegroundColor Yellow
    exit 1
}

Write-Host "  Loader caught!" -ForegroundColor Green
Write-Host ""

# Confirm with flash info
$rfi = & $RK rfi 2>&1
if ($rfi -match 'Flash Size|Sectors|LBA') {
    Write-Host "  Flash info confirmed -- Loader is latched and ready." -ForegroundColor Green
    $rfi | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
} else {
    Write-Host "  Loader detected but flash info returned nothing useful." -ForegroundColor Yellow
    Write-Host "  Try: rkdeveloptool rfi" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Next step:" -ForegroundColor Cyan
Write-Host "    .\scripts\flash-mabu.ps1 -WipeData" -ForegroundColor White
Write-Host ""

# restore-boot.ps1
# Restores the ORIGINAL unmodified boot.img to sector 0x20000 to undo
# a failed patch attempt. Also offers to clear misc partition in case
# the bootloader has stored a failed-boot counter there that keeps
# triggering recovery boot.
#
# Tablet must be in Rockchip Loader (VID 2207 PID 320A) with WinUSB.

$ErrorActionPreference = 'Stop'
$Root        = Split-Path -Parent $PSScriptRoot
$RkExe       = Join-Path $Root 'tools\rkdeveloptool\rkdeveloptool.exe'
$Original    = Join-Path $Root 'firmware\originals\boot.img'

if (-not (Test-Path $RkExe))    { Write-Host "rkdeveloptool not found at $RkExe" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $Original)) { Write-Host "Original boot.img not found at $Original" -ForegroundColor Red; exit 1 }

$size = (Get-Item $Original).Length
Write-Host "=== Original boot.img is $('{0:N0}' -f $size) bytes ===" -ForegroundColor Cyan
Write-Host ""

Write-Host "=== Confirming Loader / MaskROM is responsive ===" -ForegroundColor Cyan
$ld = & $RkExe ld 2>&1
$ld
if (-not ($ld -match 'Vid=0x2207')) {
    Write-Host "No Rockchip device found by rkdeveloptool. Aborting." -ForegroundColor Red
    Write-Host "Press Enter to close..." -ForegroundColor Yellow
    [void](Read-Host); exit 1
}
$rfi = & $RkExe rfi 2>&1
$rfi | Select-Object -First 6
if (-not ($rfi -match 'Flash Info|Flash Size|Sectors')) {
    Write-Host "Device not responsive. Power-cycle and try again." -ForegroundColor Red
    Write-Host "Press Enter to close..." -ForegroundColor Yellow
    [void](Read-Host); exit 1
}

Write-Host ""
Write-Host "=== Writing original boot.img back to sector 0x20000 ===" -ForegroundColor Cyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $RkExe wl 0x20000 $Original 2>&1 | Out-String
$sw.Stop()
Write-Host ("Write took {0:N1}s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green

Write-Host ""
Write-Host "=== Verifying first sector of boot partition ===" -ForegroundColor Cyan
$verifyFile = Join-Path $Root 'firmware\scratch\verify-restore.bin'
if (Test-Path $verifyFile) { Remove-Item $verifyFile -Force }
& $RkExe rl 0x20000 4 $verifyFile 2>&1 | Out-Null
if (Test-Path $verifyFile) {
    $verifyBytes = [System.IO.File]::ReadAllBytes($verifyFile)
    $magic = [System.Text.Encoding]::ASCII.GetString($verifyBytes, 0, 8)
    Write-Host "First 8 bytes: '$magic'"
    # Compare first 4KB to original
    $origBytes = [System.IO.File]::ReadAllBytes($Original)
    $origHead  = $origBytes[0..2047]
    $readHead  = $verifyBytes[0..2047]
    $match = $true
    for ($i = 0; $i -lt 2048; $i++) { if ($origHead[$i] -ne $readHead[$i]) { $match = $false; break } }
    if ($match) {
        Write-Host "First 2 KB matches original boot.img - restore OK" -ForegroundColor Green
    } else {
        Write-Host "First 2 KB does NOT match original. Write may have failed." -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=== Clearing misc partition (in case of stored boot-failure counter) ===" -ForegroundColor Cyan
# Misc is 0x2000 sectors (4 MB) starting at sector 0x6000. Write 32 sectors
# of zeros (16 KB) at the start - that's enough to clear the BCB structure.
$zeroFile = Join-Path $Root 'firmware\scratch\zeros-16k.bin'
$zeros = New-Object byte[] (16 * 1024)
[System.IO.File]::WriteAllBytes($zeroFile, $zeros)
& $RkExe wl 0x6000 $zeroFile 2>&1 | Out-String
Remove-Item $zeroFile -Force
Write-Host "Misc BCB cleared (first 16KB zeroed)" -ForegroundColor Green

Write-Host ""
Write-Host "=== Ready to reset tablet ===" -ForegroundColor Yellow
Write-Host "Tablet should now boot normally to Android (with Esper kiosk - but at least not the recovery loop)." -ForegroundColor White
Write-Host "Press Enter to send reset (or Ctrl-C to abort)..." -ForegroundColor Yellow
[void](Read-Host)

Write-Host ""
Write-Host "=== Sending reset ===" -ForegroundColor Cyan
& $RkExe rd 2>&1
Write-Host "Reset sent. Watch the tablet screen for normal Android boot." -ForegroundColor Green
Write-Host ""
Write-Host "Press Enter to close this window..." -ForegroundColor Yellow
[void](Read-Host)

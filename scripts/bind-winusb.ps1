# bind-winusb.ps1
#
# Helper for the Zadig step: launches Zadig and tells you exactly which
# device to pick and which driver to replace it with. Driver replacement
# is intentionally interactive - Windows treats it as a security-sensitive
# operation, and so do we.
#
# What you'll do in Zadig once it opens:
#   1. Options menu  ->  check "List All Devices".
#   2. Options menu  ->  uncheck "Ignore Hubs or Composite Parents".
#      (so the rockusb interface shows up directly).
#   3. In the dropdown, pick the device whose USB ID is "2207 0006"
#      and whose name is "H7R" (or similar).
#   4. In the right-hand "Driver" box, leave the target as "WinUSB".
#   5. Click "Replace Driver" (or "Install Driver" if no driver is bound).
#   6. Wait ~30 seconds. Windows will re-enumerate.
#
# After it finishes, the device class in Device Manager moves out of
# "Universal Serial Bus devices" and into "libusb-win32 devices" or
# "Universal Serial Bus controllers" with a WinUSB driver.
#
# To revert (if anything ever goes wrong): in Device Manager, right-click
# the device -> Uninstall device -> tick "Delete the driver software" ->
# unplug/replug. Windows will rebind the default driver.

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ToolsDir = Join-Path $RepoRoot 'tools'

function Get-ZadigPath {
    $candidates = @(
        "$env:USERPROFILE\scoop\apps\zadig\current\zadig.exe",
        "$env:USERPROFILE\scoop\shims\zadig.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Akeo.Zadig*\zadig*.exe",
        "$env:ProgramFiles\Zadig\zadig.exe",
        "${env:ProgramFiles(x86)}\Zadig\zadig.exe",
        (Join-Path $ToolsDir 'zadig.exe')
    )
    foreach ($pat in $candidates) {
        $hit = Get-ChildItem -Path $pat -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $cmd = Get-Command zadig -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# Sanity check: is the rockusb device actually enumerated right now?
$rk = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_2207' }
if (-not $rk) {
    Write-Host 'No Rockchip device (VID 0x2207) currently enumerated.' -ForegroundColor Yellow
    Write-Host 'Plug the Mabu USB header into the PC and try again.' -ForegroundColor Yellow
    exit 1
}

Write-Host 'Found rockusb device:' -ForegroundColor Green
$rk | Select-Object FriendlyName, Class, Status, InstanceId | Format-List

$zadig = Get-ZadigPath
if (-not $zadig) {
    Write-Host 'Zadig not found. Run scripts\install-tools.ps1 first.' -ForegroundColor Red
    exit 1
}

Write-Host "Launching Zadig: $zadig" -ForegroundColor Cyan
Write-Host ''
Write-Host 'In Zadig:' -ForegroundColor White
Write-Host '  1. Options -> List All Devices       (check)' -ForegroundColor White
Write-Host '  2. Options -> Ignore Hubs/Composite  (uncheck)' -ForegroundColor White
Write-Host '  3. Pick the device with USB ID 2207 0006 ("H7R")' -ForegroundColor White
Write-Host '  4. Target driver: WinUSB' -ForegroundColor White
Write-Host '  5. Click "Replace Driver" (or "Install Driver")' -ForegroundColor White
Write-Host ''
Write-Host 'When done, close Zadig and run:  scripts\install-tools.ps1' -ForegroundColor White
Write-Host '(or just check Device Manager - the device class should change).' -ForegroundColor White

Start-Process $zadig

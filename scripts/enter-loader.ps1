# enter-loader.ps1
#
# Sends `adb reboot loader` then watches the USB bus for the Rockchip Loader
# (VID_2207 PID_320A) to enumerate. Works over USB or WiFi ADB.
#
# Usage:
#   .\scripts\enter-loader.ps1
#   .\scripts\enter-loader.ps1 -AdbDevice 192.168.0.160:5555
#   .\scripts\enter-loader.ps1 -TimeoutSec 30

[CmdletBinding()]
param(
    [string] $AdbDevice  = '',
    [int]    $TimeoutSec = 30,
    [int]    $PollMs     = 400
)

$ErrorActionPreference = 'Continue'

$Root  = Split-Path -Parent $PSScriptRoot
$RkExe = Join-Path $Root 'tools\rkdeveloptool\rkdeveloptool.exe'
$VID   = '2207'

function Hr($t)   { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function OK($m)   { Write-Host "  [OK]    $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [MISS]  $m" -ForegroundColor Red }
function Note($m) { Write-Host "  [note]  $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Find adb
# ---------------------------------------------------------------------------
$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) {
    $adb = Get-ChildItem "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" -ErrorAction SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName
}
if (-not $adb) {
    Bad 'adb not found on PATH. Install via: winget install Google.PlatformTools'
    exit 1
}

# ---------------------------------------------------------------------------
# Resolve which device to target
# ---------------------------------------------------------------------------
$devList = (& $adb devices | Out-String)
if ($AdbDevice) {
    if ($devList -notmatch [regex]::Escape($AdbDevice)) {
        Bad "Specified device '$AdbDevice' not in adb devices. Run: adb connect $AdbDevice"
        Write-Host $devList -ForegroundColor DarkGray
        exit 1
    }
    $target = $AdbDevice
} else {
    $lines = ($devList -split "`r?`n") | Where-Object { $_ -match '\bdevice\b' -and $_ -notmatch '^List' }
    if ($lines.Count -eq 0) {
        Bad 'No authorized adb device found.'
        Note 'Over WiFi: adb connect <ip>:5555, then re-run.'
        Note 'Over USB:  boot tablet to Android, ensure android_winusb driver is installed.'
        exit 1
    }
    if ($lines.Count -gt 1) {
        Note 'Multiple adb devices found - using the first. Pass -AdbDevice to pick one:'
        $lines | ForEach-Object { Note "  $_" }
    }
    $target = ($lines[0] -split '\s+')[0]
}

OK "adb device: $target"

# ---------------------------------------------------------------------------
# Snapshot baseline BEFORE issuing the reboot so we catch everything after
# ---------------------------------------------------------------------------
Hr 'Snapshotting USB baseline'
$baseline = @{}
foreach ($d in (Get-PnpDevice | Where-Object { $_.InstanceId -match '^USB\\' })) {
    $baseline[$d.InstanceId] = $d.Status
}
Note "$($baseline.Count) USB nodes in baseline (will only print NEW arrivals / ghost->present transitions)."

# ---------------------------------------------------------------------------
# Fire adb reboot loader
# ---------------------------------------------------------------------------
Hr 'Sending: adb reboot loader'
& $adb -s $target reboot loader
$rebootTime = Get-Date
OK "Command sent at $($rebootTime.ToString('HH:mm:ss')). Watching for Loader (PID_320A) for ${TimeoutSec}s..."
Write-Host ''

# ---------------------------------------------------------------------------
# Watch for Loader to enumerate
# ---------------------------------------------------------------------------
$deadline  = $rebootTime.AddSeconds($TimeoutSec)
$reported  = @{}
$sawLoader = $false
$sawOther  = $false

while ((Get-Date) -lt $deadline) {
    foreach ($d in (Get-PnpDevice | Where-Object { $_.InstanceId -match '^USB\\' })) {
        $id  = $d.InstanceId
        $key = "$id|$($d.Status)"

        $isNew    = -not $baseline.ContainsKey($id)
        $wasGhost = ($baseline.ContainsKey($id) -and $baseline[$id] -eq 'Unknown' -and $d.Status -ne 'Unknown')

        if (($isNew -or $wasGhost) -and (-not $reported.ContainsKey($key))) {
            $reported[$key] = $true
            $elapsed = [int]((Get-Date) - $rebootTime).TotalSeconds
            $svc     = (Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue).Data

            if ($id -match "VID_$VID&PID_320A") {
                $sawLoader = $true
                Write-Host ("`n  [+{0}s] LOADER CAUGHT  PID_320A  Status={1}  Service={2}" -f $elapsed, $d.Status, ("$svc").Trim()) -ForegroundColor Green
                Write-Host "           $id" -ForegroundColor DarkGray
            } elseif ($id -match "VID_$VID") {
                $pidHex = if ($id -match 'PID_([0-9A-Fa-f]{4})') { $Matches[1] } else { '????' }
                $sawOther = $true
                Write-Host ("`n  [+{0}s] Rockchip PID_{1}  Status={2}  Service={3}" -f $elapsed, $pidHex, $d.Status, ("$svc").Trim()) -ForegroundColor Yellow
                Write-Host "           $id" -ForegroundColor DarkGray
            } elseif ($id -match 'VID_0000' -or $d.FriendlyName -match 'Unknown USB Device|Descriptor Request Failed' -or $d.Status -eq 'Error') {
                $sawOther = $true
                Write-Host ("`n  [+{0}s] DESCRIPTOR-FAIL  {1}  Status={2}" -f $elapsed, $d.FriendlyName, $d.Status) -ForegroundColor Red
                Write-Host "           $id" -ForegroundColor DarkGray
            } else {
                $sawOther = $true
                Write-Host ("`n  [+{0}s] other USB  {1}" -f $elapsed, $id) -ForegroundColor DarkGray
            }
        }
    }
    Write-Host -NoNewline '.'
    Start-Sleep -Milliseconds $PollMs
}
Write-Host ''

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
Hr 'Result'
if ($sawLoader) {
    OK 'Loader (PID_320A) is on the bus.'

    if (Test-Path $RkExe) {
        $ld = (& $RkExe ld | Out-String)
        if ($ld -match 'Pid=0x320a') {
            OK 'rkdeveloptool confirms Loader is open and ready to flash.'
            Write-Host "    $($ld.Trim())" -ForegroundColor DarkGray
            Write-Host ''
            Write-Host '  Next step:' -ForegroundColor Cyan
            Write-Host '    .\scripts\flash.ps1' -ForegroundColor White
        } else {
            Note 'Loader enumerated on PnP but rkdeveloptool cannot open it yet.'
            Note 'WinUSB is not bound to PID_320A. Fix with Zadig:'
            Note '  1. Open Zadig (tools\zadig.exe)'
            Note '  2. Options -> List All Devices'
            Note '  3. Select the Rockchip device -> Replace Driver -> WinUSB'
            Note '  4. Re-run: .\scripts\enter-loader.ps1'
        }
    } else {
        Note 'rkdeveloptool not found - cannot confirm open. Check WinUSB binding with Zadig.'
    }
} else {
    Bad "No Loader appeared within ${TimeoutSec}s."
    if ($sawOther) {
        Note 'Something else appeared (see above). The tablet may not have reached Loader mode.'
        Note 'Common causes: adb reboot loader was rejected (auth), or the Loader window'
        Note '  closed before USB connected. Re-run immediately after `adb reboot loader`.'
    } else {
        Bad 'No USB device at all - D+/D- data lines may not be making contact.'
        Note 'Verify harness: OTG_DP (D+) and OTG_DM (D-) pins must be wired to the USB cable.'
        Note 'Try a different USB port or check the 30-pin connector seating.'
    }
}
Write-Host ''

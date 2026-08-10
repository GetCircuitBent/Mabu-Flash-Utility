# flash-new-mabu.ps1  --  DEPRECATED
#
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# !!  THIS SCRIPT IS DEPRECATED. DO NOT USE IT.                          !!
# !!                                                                      !!
# !!  Use scripts\flash-mabu.ps1 instead -- it is the current            !!
# !!  all-in-one script and receives all updates.                         !!
# !!                                                                      !!
# !!  This file is kept for historical reference only and will be         !!
# !!  removed in a future cleanup.                                        !!
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#
# Full Mabu flash protocol: liberation + SELinux serial-access patch.
# Runs the complete sequence every time. USB harness only — no WiFi required.
#
# Protocol:
#   1. Check prerequisites
#   2. Get device into Loader (ADB reboot if available; else wait for power-cycle)
#   3. Apply liberation patches
#   4. Reboot, wait for USB ADB, enable tcpip 5555, switch to WiFi ADB
#      (USB ADB dies after ~4 reboot-loader cycles; WiFi is required from here)
#   5. Dump /vendor partition (via WiFi ADB for cycle re-entry)
#   6. Inject SELinux rule in WSL, verify
#   7. Write patched policy back via Loader
#   8. Reboot, verify on device via WiFi ADB
#
# If anything fails the script stops immediately and prints what went wrong.
# Do not retry individual steps — power off the unit and run the full script again.
#
# Prerequisites (one-time per PC):
#   .\scripts\install-tools.ps1            # rkdeveloptool, WSL sepolicy-inject
#   .\scripts\install-android-driver.ps1   # USB ADB driver for PID 0x0006

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Re-launching as Administrator (required for USB device removal)..." -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
$RepoRoot = Split-Path -Parent $PSScriptRoot
$RK       = Join-Path $RepoRoot 'tools\rkdeveloptool\rkdeveloptool.exe'
$ADB      = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
if (-not (Test-Path $ADB)) {
    $ADB = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" `
            -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
}

function Banner($msg) { Write-Host "`n====  $msg  ====" -ForegroundColor Cyan }
function OK($msg)     { Write-Host "  [OK]  $msg" -ForegroundColor Green }
function Info($msg)   { Write-Host "  [--]  $msg" -ForegroundColor Gray }
function Fail($msg)   { Write-Host "`n  [FAIL]  $msg" -ForegroundColor Red; exit 1 }

function Test-Loader {
    (& $RK ld 2>&1) -match 'Vid=0x2207,Pid=0x320a.*Loader'
}

function Find-UsbAdb {
    $local:ErrorActionPreference = 'SilentlyContinue'
    $lines = & $ADB devices 2>&1 | Where-Object { $_ -is [string] -and $_ -match '\bdevice$' }
    foreach ($line in $lines) {
        $serial = ($line -split '\s+')[0]
        try {
            if ((& $ADB -s $serial shell echo ok 2>&1) -match '^ok') { return $serial }
        } catch {}
    }
    return $null
}

function Wait-Loader([int]$TimeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Loader) { return $true }
        Start-Sleep -Seconds 1
        Write-Host '.' -NoNewline
    }
    Write-Host ''
    return $false
}

function Wait-UsbAdb([int]$TimeoutSec = 180) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $s = Find-UsbAdb
        if ($s) { return $s }
        Start-Sleep -Seconds 3
        Write-Host '.' -NoNewline
    }
    Write-Host ''
    return $null
}

# ===========================================================================
# 0. Release USB + clear all VID_2207 entries
# After repeated Loader cycles, ADB and rkdeveloptool accumulate stale
# libusb handles that block re-enumeration. Kill both, then purge every
# VID_2207 PnP entry (present or ghost) so Windows re-enumerates clean.
# ===========================================================================
Banner '0. Release USB + clear VID_2207 entries'

Info "Killing ADB server..."
& $ADB kill-server 2>$null
Start-Sleep -Milliseconds 500

Info "Killing any stale rkdeveloptool processes..."
Get-Process -Name 'rkdeveloptool' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

$stuck = Get-PnpDevice | Where-Object { $_.FriendlyName -match 'Device Descriptor Request Failed' }
if ($stuck) {
    foreach ($d in $stuck) {
        Info "Removing stuck device: $($d.InstanceId)"
        & pnputil /remove-device $d.InstanceId 2>&1 | Out-Null
    }
    OK "Stuck USB entries cleared."
    Start-Sleep -Seconds 1
} else {
    OK "No stuck USB devices."
}

$allRk = Get-PnpDevice | Where-Object { $_.InstanceId -match 'VID_2207' }
if ($allRk) {
    foreach ($d in $allRk) {
        Info "Removing: $($d.InstanceId) [Present=$($d.Present)]"
        & pnputil /remove-device $d.InstanceId 2>&1 | Out-Null
    }
    OK "All VID_2207 entries removed."
} else {
    OK "No VID_2207 entries found."
}

Info "Scanning for hardware changes..."
& pnputil /scan-devices 2>&1 | Out-Null
Start-Sleep -Seconds 2
OK "USB bus ready."

function Find-ZadigPath {
    $candidates = @(
        "$env:USERPROFILE\scoop\apps\zadig\current\zadig.exe",
        "$env:USERPROFILE\scoop\shims\zadig.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Akeo.Zadig*\zadig*.exe",
        "$env:ProgramFiles\Zadig\zadig.exe",
        "${env:ProgramFiles(x86)}\Zadig\zadig.exe",
        (Join-Path $RepoRoot 'tools\zadig.exe')
    )
    foreach ($pat in $candidates) {
        $hit = Get-ChildItem -Path $pat -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $cmd = Get-Command zadig -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Test-WinUSBBound {
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB\VID_2207&PID_320A'
    if (-not (Test-Path $key)) { return $false }
    foreach ($sub in Get-ChildItem $key -ErrorAction SilentlyContinue) {
        $svc = (Get-ItemProperty $sub.PSPath -Name Service -ErrorAction SilentlyContinue).Service
        if ($svc -eq 'WinUSB') { return $true }
    }
    return $false
}

function Invoke-ZadigBind {
    if (Test-WinUSBBound) {
        Write-Host ''
        Write-Host '  ============================================================' -ForegroundColor Cyan
        Write-Host '   WinUSB already bound for PID 0x320A.' -ForegroundColor Cyan
        Write-Host '   Loader window was missed — power the Mabu OFF, then' -ForegroundColor White
        Write-Host '   press Enter and power it back ON when prompted.' -ForegroundColor White
        Write-Host '  ============================================================' -ForegroundColor Cyan
        Write-Host ''
        Read-Host '  Press Enter when the Mabu is powered OFF and ready to retry'
        return
    }

    $zadig = Find-ZadigPath
    if (-not $zadig) {
        Write-Host "  [--]  Zadig not found — installing via winget..." -ForegroundColor Yellow
        winget install --id Akeo.Zadig --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        $zadig = Find-ZadigPath
        if (-not $zadig) { Fail "Could not find or install Zadig. Install it manually from https://zadig.akeo.ie/ and re-run." }
    }

    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Yellow
    Write-Host '   WinUSB NOT BOUND — ACTION REQUIRED IN ZADIG' -ForegroundColor Yellow
    Write-Host '  ============================================================' -ForegroundColor Yellow
    Write-Host '   1. Power ON the Mabu now (Loader window is ~10s after boot)' -ForegroundColor White
    Write-Host '   2. In Zadig: Options -> List All Devices' -ForegroundColor White
    Write-Host '   3. Pick the device with USB ID  2207 320A' -ForegroundColor White
    Write-Host '   4. Target driver: WinUSB  ->  click Replace Driver / Install Driver' -ForegroundColor White
    Write-Host '   5. Wait ~30s for Windows to finish, then power OFF the Mabu' -ForegroundColor White
    Write-Host '  ============================================================' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  Launching Zadig: $zadig" -ForegroundColor Cyan
    Start-Process $zadig
    Read-Host '  Press Enter once WinUSB is bound and the Mabu is powered OFF'
}

# ===========================================================================
# 1. Prerequisites
# ===========================================================================
Banner '1. Prerequisites'

if (-not (Test-Path $RK)) {
    Write-Host "  [--]  rkdeveloptool not found — running install-tools.ps1..." -ForegroundColor Yellow
    & (Join-Path $RepoRoot 'scripts\install-tools.ps1')
    if (-not (Test-Path $RK)) { Fail "rkdeveloptool still missing after install-tools.ps1. Check output above." }
    OK "rkdeveloptool installed."
}
if (-not $ADB -or -not (Test-Path $ADB)) {
    Write-Host "  [--]  adb.exe not found — installing Google.PlatformTools via winget..." -ForegroundColor Yellow
    winget install --id Google.PlatformTools --silent --accept-package-agreements --accept-source-agreements
    # Re-locate after install
    $ADB = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" `
            -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    if (-not $ADB -or -not (Test-Path $ADB)) { Fail "adb.exe still not found after winget install. Restart PowerShell and re-run." }
    OK "adb installed: $ADB"
}

$patchDir = Join-Path $RepoRoot 'firmware\patches'
$required = @(
    'parameter-patched.img',
    'adbd-authreq-patched.bin',
    'adbd-authinit-patched.bin',
    'espersupervisor-apk-eocd-patched.bin',
    'esperdpc-apk-eocd-patched.bin',
    'esperhelper-apk-eocd-patched.bin',
    'zeros-4k.bin'
)
foreach ($f in $required) {
    if (-not (Test-Path (Join-Path $patchDir $f))) {
        Fail "Missing patch payload: firmware\patches\$f"
    }
}

$wslCheck = wsl -d Ubuntu -- which sepolicy-inject 2>&1
if ($wslCheck -notmatch 'sepolicy-inject') {
    Write-Host "  [--]  sepolicy-inject not found in WSL — running install-tools.ps1..." -ForegroundColor Yellow
    & (Join-Path $RepoRoot 'scripts\install-tools.ps1')
    $wslCheck = wsl -d Ubuntu -- which sepolicy-inject 2>&1
    if ($wslCheck -notmatch 'sepolicy-inject') { Fail "sepolicy-inject still missing after install-tools.ps1. Check WSL/build output above." }
    OK "sepolicy-inject installed."
}

OK "rkdeveloptool, adb, patch payloads, sepolicy-inject — all present."

$scratchDir = Join-Path $RepoRoot 'firmware\scratch'
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

# ===========================================================================
# 2. Get device into Loader
# ===========================================================================
Banner '2. Get device into Loader'

if (Test-Loader) {
    OK "Already in Loader."
} else {
    $usbSerial = Find-UsbAdb
    if ($usbSerial) {
        Info "Device already in Android mode with ADB ($usbSerial) — sending reboot loader..."
        & $ADB -s $usbSerial shell reboot loader 2>&1 | Out-Null
    } else {
        Write-Host ''
        Write-Host '  ============================================================' -ForegroundColor Yellow
        Write-Host '   POWER ON THE MABU NOW' -ForegroundColor Yellow
        Write-Host '   Loader window appears ~10s after power-on. You have 90 seconds.' -ForegroundColor Yellow
        Write-Host '  ============================================================' -ForegroundColor Yellow
        Write-Host ''
    }

    Write-Host "  Waiting for Loader (20s)..." -ForegroundColor Cyan
    if (-not (Wait-Loader 20)) {
        # WinUSB probably not bound — recover via Zadig then retry
        Invoke-ZadigBind
        Write-Host ''
        Write-Host '  ============================================================' -ForegroundColor Yellow
        Write-Host '   POWER ON THE MABU NOW' -ForegroundColor Yellow
        Write-Host '   Loader window appears ~10s after power-on. You have 60 seconds.' -ForegroundColor Yellow
        Write-Host '  ============================================================' -ForegroundColor Yellow
        Write-Host ''
        Write-Host "  Waiting for Loader (60s)..." -ForegroundColor Cyan
        if (-not (Wait-Loader 60)) {
            Fail "Loader still not detected after WinUSB bind. Make sure Zadig completed successfully and the USB harness is connected before powering on."
        }
    }
    OK "Loader caught."
}

# ===========================================================================
# 3. Liberation
# ===========================================================================
Banner '3. Liberation'

Info "Applying patches..."
& (Join-Path $RepoRoot 'scripts\liberate-mabu.ps1') -Reset
if ($LASTEXITCODE -ne 0) { Fail "liberate-mabu.ps1 failed (exit $LASTEXITCODE)." }
OK "All liberation patches written. Device rebooting to Android."

# ===========================================================================
# 4. Wait for USB ADB, then immediately switch to WiFi ADB
# USB ADB over WinUSB dies after ~4 reboot-loader cycles. WiFi ADB is the
# only reliable transport for the dump and all subsequent ADB steps.
# ===========================================================================
Banner '4. Wait for USB ADB + switch to WiFi'

Info "Waiting for Android + USB ADB (up to 3 min)..."
$usbSerial = Wait-UsbAdb 180
if (-not $usbSerial) {
    Fail "USB ADB not seen after 3 min.`n  If this is the first flash on this PC, the ADB USB driver needs installing:`n  -> Run scripts\install-android-driver.ps1 and follow the Device Manager steps.`n  Then power off the unit and run flash-new-mabu.ps1 again."
}
OK "USB ADB: $usbSerial"

# Enable persistent WiFi ADB immediately
& $ADB -s $usbSerial tcpip 5555 2>&1 | Out-Null
Info "adb tcpip 5555 sent. Waiting for WiFi IP on wlan0..."

# Get WiFi IP (retry up to 60s in case DHCP is slow)
$wifiIp = $null
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    $ipOut = & $ADB -s $usbSerial shell "ip -f inet addr show wlan0 2>/dev/null" 2>&1
    $match = $ipOut | Select-String 'inet\s+([\d.]+)/'
    if ($match) { $wifiIp = $match.Matches[0].Groups[1].Value; break }
    Start-Sleep -Seconds 3
    Write-Host '.' -NoNewline
}
Write-Host ''

if (-not $wifiIp) {
    Write-Host ''
    Write-Host '  [!]  No WiFi IP on wlan0. Connect the Mabu to CB Quarantine WiFi now.' -ForegroundColor Yellow
    Write-Host '       SSID: CB Quarantine   Pass: HereBeDragons' -ForegroundColor Yellow
    Write-Host '       Waiting up to 3 min for WiFi IP...' -ForegroundColor Yellow
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline) {
        $ipOut = & $ADB -s $usbSerial shell "ip -f inet addr show wlan0 2>/dev/null" 2>&1
        $match = $ipOut | Select-String 'inet\s+([\d.]+)/'
        if ($match) { $wifiIp = $match.Matches[0].Groups[1].Value; break }
        Start-Sleep -Seconds 5
        Write-Host '.' -NoNewline
    }
    Write-Host ''
    if (-not $wifiIp) { Fail "Could not get WiFi IP. Connect to CB Quarantine and re-run." }
}

OK "WiFi IP: $wifiIp"
Info "Connecting via WiFi ADB..."
$null = & $ADB connect "${wifiIp}:5555" 2>&1
$wifiSerial = "${wifiIp}:5555"
try {
    $ok = & $ADB -s $wifiSerial shell echo ok 2>&1
    if ($ok -notmatch '^ok') { Fail "WiFi ADB connected but shell echo failed. Check network." }
} catch { Fail "WiFi ADB shell test failed. Check network." }
OK "WiFi ADB: $wifiSerial — switching to WiFi for all remaining steps."

# ===========================================================================
# 5. Dump /vendor
# ===========================================================================
Banner '5. Dump /vendor (256 MB)'

$vendorImg = Join-Path $scratchDir 'vendor-full.img'
Remove-Item $vendorImg, (Join-Path $scratchDir 'vendor-full.state.json') -ErrorAction SilentlyContinue

& (Join-Path $RepoRoot 'scripts\dump-system-cycled.ps1') `
    -Name 'vendor-full' `
    -PartitionStartLBA 0x592000 `
    -TotalMB 256 `
    -WifiAdb $wifiSerial `
    -StartFresh
if ($LASTEXITCODE -ne 0) { Fail "Vendor dump failed (exit $LASTEXITCODE)." }
if (-not (Test-Path $vendorImg)) { Fail "vendor-full.img not found after dump." }

$imgMB = [math]::Round((Get-Item $vendorImg).Length / 1MB, 1)
if ($imgMB -lt 255) { Fail "vendor-full.img is only ${imgMB} MB — dump incomplete. Re-run." }
OK "vendor-full.img: ${imgMB} MB"

# ===========================================================================
# 6. Locate policy, inject rule, verify
# ===========================================================================
Banner '6. Inject SELinux rule'

$locator = Join-Path $RepoRoot 'scripts\locate_vendor_policy.py'
$wVendor  = '/mnt/c/Claude Projects/mabu-guides/firmware/scratch/vendor-full.img'
$wScratch = '/mnt/c/Claude Projects/mabu-guides/firmware/scratch'

$locOut = wsl -d Ubuntu -- python3 `
    '/mnt/c/Claude Projects/mabu-guides/scripts/locate_vendor_policy.py' `
    $wVendor 2>&1
$locOut | ForEach-Object { Info $_ }

$fileLba     = [string]($locOut | Select-String 'FILE_LBA\s*=\s*(\d+)'     | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
$nsect       = [string]($locOut | Select-String 'NSECT\s*=\s*(\d+)'        | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
$inodeLba    = [string]($locOut | Select-String 'INODE_LBA\s*=\s*(\d+)'    | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
$inodeOff    = [string]($locOut | Select-String 'INODE_OFFSET\s*=\s*(\d+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
$isize       = [string]($locOut | Select-String 'i_size\s*=\s*(\d+)'       | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
$metaCsum    = ($locOut -join ' ') -match 'metadata_csum=ON'

if (-not $fileLba -or -not $nsect -or -not $inodeLba) {
    Fail "locate_vendor_policy.py did not return FILE_LBA/NSECT/INODE_LBA. See output above."
}
OK "Policy at FILE_LBA=$fileLba NSECT=$nsect INODE_LBA=$inodeLba INODE_OFFSET=$inodeOff i_size=$isize meta_csum=$(if ($metaCsum){'ON'}else{'OFF'})"

# Save originals before touching anything
Info "Saving originals..."
& $RK rl $fileLba  $nsect (Join-Path $scratchDir 'policy.orig.blob')  2>&1 | Out-Null
& $RK rl $inodeLba 1      (Join-Path $scratchDir 'inode.orig.sector') 2>&1 | Out-Null
if (-not (Test-Path (Join-Path $scratchDir 'policy.orig.blob'))) { Fail "Failed to read policy blob from device." }
OK "Originals saved."

# Inject rule
$injectOut = wsl -d Ubuntu -- sepolicy-inject "$wScratch/policy.orig.blob" "$wScratch/policy.patched.bin" 2>&1
$injectOut | ForEach-Object { Info $_ }
if (-not ($injectOut -join ' ' -match 'Done')) { Fail "sepolicy-inject failed. See output above." }

# Verify rule is present before writing anything to the device
$verifyOut = wsl -d Ubuntu -- sesearch --allow -s untrusted_app -t serial_device -c chr_file "$wScratch/policy.patched.bin" 2>&1
Info "sesearch: $($verifyOut -join ' ')"
if (-not ($verifyOut -join ' ' -match 'serial_device')) {
    Fail "sesearch did not confirm the rule in the patched policy. Aborting — device not modified."
}
OK "Rule verified. Proceeding to write."

$patchedBytes = [int](wsl -d Ubuntu -- stat -c '%s' "$wScratch/policy.patched.bin" 2>&1 | Select-Object -First 1)

# ===========================================================================
# 7. Write patched policy via Loader
# ===========================================================================
Banner '7. Write patched policy'

# Must be in Loader to write
Info "Sending reboot loader via WiFi ADB ($wifiSerial)..."
& $ADB -s $wifiSerial shell reboot loader 2>&1 | Out-Null
Write-Host "  Waiting for Loader..." -ForegroundColor Yellow
if (-not (Wait-Loader 30)) { Fail "Loader did not appear after 'reboot loader'. Power-cycle and re-run." }
OK "In Loader."

if ($metaCsum) {
    # Route 2: swap file inside /vendor image, reflash whole partition
    Info "metadata_csum=ON — Route 2: reflash whole /vendor"
    $r2out = wsl -d Ubuntu -u root -- bash -c @"
set -e
mkdir -p /mnt/vendor
mount -o loop '$wVendor' /mnt/vendor
cp '$wScratch/policy.patched.bin' /mnt/vendor/etc/selinux/precompiled_sepolicy
sync
sesearch --allow -s untrusted_app -t serial_device -c chr_file /mnt/vendor/etc/selinux/precompiled_sepolicy
umount /mnt/vendor
echo ROUTE2_OK
"@ 2>&1
    $r2out | ForEach-Object { Info $_ }
    if (-not ($r2out -join ' ' -match 'ROUTE2_OK')) { Fail "Route 2 mount/copy failed. See output above." }

    Info "Flashing /vendor (256 MB — this takes a few minutes)..."
    $wlOut = & $RK wl 0x592000 (Join-Path $scratchDir 'vendor-full.img') 2>&1
    $wlOut | ForEach-Object { Info $_ }
    if (-not ($wlOut -join ' ' -match '100%')) { Fail "wl for /vendor did not report 100%. Restoring original and aborting.`n  Run: rkdeveloptool wl 0x592000 firmware\scratch\vendor-full.img" }
} else {
    # Route 1: surgical in-place write
    Info "metadata_csum=OFF — Route 1: surgical write"
    $targetBytes = [int]$nsect * 512
    if ($patchedBytes -gt $targetBytes) {
        Fail "Patched policy ($patchedBytes B) exceeds allocated blocks ($targetBytes B). Use Route 2 (metadata_csum forced check failed)."
    }

    # Pad to block boundary
    wsl -d Ubuntu -- python3 -c @"
data = open('$wScratch/policy.patched.bin','rb').read()
target = $targetBytes
assert len(data) <= target, f'{len(data)} > {target}'
open('$wScratch/policy.padded.blob','wb').write(data + b'\x00'*(target-len(data)))
print(f'padded {len(data)} to {target} bytes')
"@ 2>&1 | ForEach-Object { Info $_ }

    Info "Writing policy data (LBA=$fileLba, $nsect sectors)..."
    $wlOut = & $RK wl $fileLba (Join-Path $scratchDir 'policy.padded.blob') 2>&1
    $wlOut | ForEach-Object { Info $_ }
    if (-not ($wlOut -join ' ' -match '100%')) { Fail "Policy data write did not report 100%." }

    # Patch inode i_size
    wsl -d Ubuntu -- python3 -c @"
import struct
sect = bytearray(open('$wScratch/inode.orig.sector','rb').read())
struct.pack_into('<I', sect, $inodeOff + 4, $patchedBytes)
open('$wScratch/inode.patched.sector','wb').write(sect)
print(f'set i_size={$patchedBytes} at sector-byte {$inodeOff+4}')
"@ 2>&1 | ForEach-Object { Info $_ }

    Info "Writing patched inode (LBA=$inodeLba)..."
    $wlOut = & $RK wl $inodeLba (Join-Path $scratchDir 'inode.patched.sector') 2>&1
    $wlOut | ForEach-Object { Info $_ }
    if (-not ($wlOut -join ' ' -match '100%')) { Fail "Inode write did not report 100%." }
}
OK "Write complete."

# ===========================================================================
# 8. Reboot and verify
# ===========================================================================
Banner '8. Reboot and verify'

& $RK rd 2>&1 | Out-Null
Info "Waiting for Android (via WiFi ADB $wifiSerial)..."
$wifiOk = $false
$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline) {
    try {
        $ok = & $ADB -s $wifiSerial shell echo ok 2>&1
        if ($ok -match '^ok') { $wifiOk = $true; break }
    } catch {}
    Start-Sleep -Seconds 3
    Write-Host '.' -NoNewline
}
Write-Host ''
if (-not $wifiOk) { Fail "WiFi ADB not responding after reboot. Check device booted and network is up." }
OK "ADB: $wifiSerial"

$enforce = (& $ADB -s $wifiSerial shell getenforce 2>&1) -join ''
Info "getenforce: $enforce"
if ($enforce -notmatch 'Enforcing') {
    Fail "SELinux is not Enforcing — unexpected. Check device state."
}

$label = (& $ADB -s $wifiSerial shell ls -Z /dev/ttyS1 2>&1) -join ''
Info "/dev/ttyS1: $label"
if ($label -notmatch 'serial_device') {
    Fail "/dev/ttyS1 label does not contain 'serial_device'. Check device state."
}

$denied = & $ADB -s $wifiSerial shell logcat -d 2>&1 |
    Select-String 'avc.*denied.*serial_device' | Select-Object -Last 5
if ($denied) {
    $denied | ForEach-Object { Info $_ }
    Fail "AVC denials for serial_device present in logcat — patch did not load. Power off and re-run."
}
OK "No AVC denials for serial_device. SELinux patch loaded."

# ===========================================================================
Banner 'DONE'
OK "Unit fully flashed. WiFi ADB: adb connect $wifiSerial"
Info "Do NOT run motor tests until Alex confirms hardware is ready and watching."

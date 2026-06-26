# flash-mabu.ps1
#
# Unified Mabu liberation + restore script.
#
# Phases:
#   1. Detect Rockchip Loader (PID 0x320A). If not present, attempt to
#      enter via wifi/usb adb 'reboot loader'.
#   2. Apply liberate-mabu patches (parameter + adbd + 3x EOCD + 2x init).
#   3. Optionally wipe /data head (-WipeData; needed for active Esper).
#   4. Reset to Android. Wait for adb (usb or wifi).
#   5. Install user-facing apps: F-Droid, Lawnchair. Set Lawnchair home.
#   6. Optionally install Mabu factory mode + push assets (-RestoreMabu).
#
# Use cases:
#   - Fresh Esper-active Mabu:
#       .\flash-mabu.ps1 -WipeData -RestoreMabu
#   - Already-liberated unit re-applying patches:
#       .\flash-mabu.ps1 -RestoreMabu
#   - Just neutralize the new init.esper.rc + sdo.sh on a previously-patched unit:
#       .\flash-mabu.ps1 -SkipApps
#
# After -WipeData, wifi creds are wiped. The device will need wifi set up
# via the touch UI before -RestoreMabu / app installs can proceed. The
# script will pause and ask you to set up wifi when this happens.

[CmdletBinding()]
param(
    [switch] $WipeData,          # zero head of /data; needed when Esper kiosk policies are active
    [int]    $WipeMB = 96,       # 96 MB matches v3 procedure (preserves Dev Options on this build)
    [switch] $RestoreMabu,       # install factorymode + push animations/voice assets
    [switch] $SkipApps,          # only do Loader-side patches; no F-Droid/Lawnchair
    [string] $WifiIp = '192.168.0.18',  # static lease; override if IP changes
    [string] $UsbSerial,         # if known; else autodetect
    [string] $LawnchairApk = 'apks/Lawnchair.apk',
    [string] $FDroidApk    = 'apks/F-Droid.apk',
    [string] $MabuArchive  = 'mabu-archive/unit-2022010501476'
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path '.').Path
$RK = Join-Path $Root 'tools/rkdeveloptool/rkdeveloptool.exe'
$ADB = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" | Select-Object -First 1).FullName
if (-not $ADB) { throw "adb.exe not found" }

function Section($msg) { Write-Host "" -ForegroundColor Cyan; Write-Host "==== $msg ====" -ForegroundColor Cyan }
function Info($msg)    { Write-Host "  $msg" -ForegroundColor Gray }
function Ok($msg)      { Write-Host "  $msg" -ForegroundColor Green }
function Warn($msg)    { Write-Host "  $msg" -ForegroundColor Yellow }
function Fail($msg)    { Write-Host "  $msg" -ForegroundColor Red }

function Test-Loader { (& $RK ld 2>&1) -match 'Vid=0x2207,Pid=0x320a.*Loader' }

function Find-AdbDevice {
    param([string] $PreferIp, [int] $TimeoutSec = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        # try wifi first if hint
        if ($PreferIp) {
            $r = & $ADB connect "${PreferIp}:5555" 2>&1
            if ($r -match 'connected to|already connected') {
                $ok = & $ADB -s "${PreferIp}:5555" shell echo ok 2>&1
                if ($ok -match '^ok') { return "${PreferIp}:5555" }
            }
        }
        # then any usb device
        $usb = & $ADB devices 2>&1 | Where-Object { $_ -match '^\d+\s+device$' }
        if ($usb) {
            $serial = ($usb[0] -split '\s+')[0]
            $ok = & $ADB -s $serial shell echo ok 2>&1
            if ($ok -match '^ok') { return $serial }
        }
        Start-Sleep -Seconds 3
    }
    return $null
}

# --- Phase 1: Catch / verify Loader ---
Section 'Loader detection'
if (Test-Loader) {
    Ok 'Loader already present.'
} else {
    Info 'Loader not seen. Attempting to enter via adb reboot loader.'
    $dev = Find-AdbDevice -PreferIp $WifiIp -TimeoutSec 30
    if (-not $dev) {
        Fail 'No adb device and no Loader. Power-cycle the tablet to catch Loader, then re-run.'
        exit 1
    }
    Info "Found adb device: $dev. Rebooting into Loader."
    & $ADB -s $dev shell reboot loader 2>&1 | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Loader) { Ok "Loader caught after ${i}s."; break }
    }
    if (-not (Test-Loader)) { Fail 'Loader did not appear in 30s.'; exit 1 }
}

# --- Phase 2: Apply patches ---
Section 'Applying liberation patches'
& (Join-Path $Root 'scripts/liberate-mabu.ps1')
if ($LASTEXITCODE -ne 0) { Fail 'liberate-mabu.ps1 failed.'; exit 1 }
Ok 'All 8 patches written.'

# --- Phase 3: Optional /data wipe ---
# A single Loader session can do all 8 small patch writes OR a 96 MB wipe,
# but doing patches+wipe back-to-back wedges Loader on the first wipe chunk.
# Workaround: reset between phases. This means rebooting to Android,
# letting adb come up, then `reboot loader` to re-enter Loader fresh.
if ($WipeData) {
    Section 'Resetting Loader between patch and wipe phases'
    Info 'Loader wedges if we do patches + 16 MB write back-to-back.'
    Info 'Booting to Android, then re-entering Loader via adb.'
    & $RK rd 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    $bootDev = Find-AdbDevice -PreferIp $WifiIp -TimeoutSec 120
    if (-not $bootDev) { Fail 'No adb after inter-phase reset. Power-cycle and retry.'; exit 1 }
    Ok "adb up at $bootDev"
    & $ADB -s $bootDev shell reboot loader 2>&1 | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Loader) { Ok "Loader re-caught after ${i}s."; break }
    }
    if (-not (Test-Loader)) { Fail 'Loader not re-caught.'; exit 1 }

    Section "Wiping head of /data ($WipeMB MB)"
    & (Join-Path $Root 'scripts/wipe-data-head.ps1') -SizeMB $WipeMB
    if ($LASTEXITCODE -ne 0) { Fail '/data head wipe failed.'; exit 1 }
    Ok '/data head zeroed; vold will reformat on boot.'
}

# --- Phase 4: Reset and wait for adb ---
Section 'Resetting device'
& $RK rd 2>&1 | Out-Null
Ok 'Reset issued.'

if ($SkipApps) {
    Write-Host ""
    Ok 'Loader-side patches done. SkipApps requested -- no userspace install.'
    exit 0
}

Section 'Waiting for adb (usb or wifi)'
if ($WipeData) {
    Warn '/data was wiped: WiFi credentials are gone.'
    Warn 'On the tablet touch UI, connect to WiFi. Then come back here.'
    Read-Host 'Press Enter once WiFi is associated on the tablet'
}
$dev = Find-AdbDevice -PreferIp $WifiIp -TimeoutSec 180
if (-not $dev) {
    Fail 'Timed out waiting for adb. Check usb cable / wifi connection.'
    exit 1
}
Ok "Connected: $dev"

# Quick audit
Section 'Post-boot audit'
$audit = & $ADB -s $dev shell 'echo DO=$(getprop ro.device_owner); echo SDOSVC=$(getprop init.svc.set-device-owner); dumpsys device_policy | grep -E "Device managed:|provisioningState" | head -3; pm list packages | grep -iE "esper|shoonya" | head -5' 2>&1
$audit | ForEach-Object { Info $_ }

# --- Phase 5: Install user-facing apps ---
Section 'Installing user apps'
foreach ($apk in @($FDroidApk, $LawnchairApk)) {
    if (-not (Test-Path (Join-Path $Root $apk))) { Warn "Missing APK: $apk -- skipping"; continue }
    $r = & $ADB -s $dev install (Join-Path $Root $apk) 2>&1 | Select-Object -Last 1
    Info "$apk : $r"
}
& $ADB -s $dev shell 'cmd package set-home-activity app.lawnchair/.LawnchairLauncher' 2>&1 | Out-Null
Ok 'Lawnchair set as default launcher.'

# --- Phase 6: Mabu restore ---
if ($RestoreMabu) {
    Section 'Restoring Mabu factory mode + assets'
    $installed = (& $ADB -s $dev shell 'pm list packages | grep -i catalia') 2>&1
    if ($installed -match 'com.catalia.factorymode') {
        Info 'com.catalia.factorymode already installed -- skipping APK install.'
    } else {
        $apk = Join-Path $Root "$MabuArchive/apks/com.catalia.factorymode.apk"
        $r = & $ADB -s $dev install $apk 2>&1 | Select-Object -Last 1
        Info "factorymode install: $r"
    }
    foreach ($p in 'CAMERA','RECORD_AUDIO','READ_PHONE_STATE','READ_EXTERNAL_STORAGE','WRITE_EXTERNAL_STORAGE') {
        & $ADB -s $dev shell pm grant com.catalia.factorymode "android.permission.$p" 2>&1 | Out-Null
    }
    Ok 'Runtime perms granted.'

    $SD = Join-Path $Root "$MabuArchive/sdcard/sdcard"
    if (Test-Path $SD) {
        Info 'Pushing animation CSVs...'
        Get-ChildItem "$SD/*.csv" | ForEach-Object {
            & $ADB -s $dev push $_.FullName /sdcard/ 2>&1 | Out-Null
        }
        if (Test-Path "$SD/nuance") { & $ADB -s $dev push "$SD/nuance" /sdcard/ 2>&1 | Out-Null }
        if (Test-Path "$SD/sound.raw") { & $ADB -s $dev push "$SD/sound.raw" /sdcard/ 2>&1 | Out-Null }
        Ok 'Assets pushed.'
    } else {
        Warn "Mabu archive sdcard dir not found at $SD"
    }
}

Section 'Done'
Ok "Unit at $dev liberated and provisioned. Verify on-device:"
Info '  - Home screen = Lawnchair (long-press to customize)'
Info '  - F-Droid available for additional apps'
if ($RestoreMabu) {
    Info '  - Mabu Factory Mode launches motor diagnostics'
    Info '  - Open Trouble Shooting/Motor Debug to recalibrate motors'
}

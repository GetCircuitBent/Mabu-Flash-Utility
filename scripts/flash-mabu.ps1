# flash-mabu.ps1
#
# Unified Mabu liberation + restore script.
#
# Phases:
#   1. Detect Rockchip Loader (PID 0x320A). If not present, find an adb device,
#      AUTO-DETECT the Esper state (A vs B), then enter Loader via 'reboot loader'.
#   2. Apply liberate-mabu patches (parameter + adbd + 3x EOCD + 2x init).
#   3. Wipe /data head when the unit is State A (or forced/undetermined).
#   4. Reset to Android. Wait for WiFi adb (installs/pulls run over WiFi).
#   5. Install user-facing apps: F-Droid, Lawnchair. Set Lawnchair home.
#   6. Optionally install Mabu factory mode + push assets (-RestoreMabu).
#
# State auto-detection (the /data wipe is the only thing that differs):
#   - State A (active Esper): the live DPC io.shoonya.shoonyadpc lives in
#     /data/app and survives the /system patches, so it MUST be wiped. Detected
#     by that package being installed. -> wipe (default).
#   - State B (factory-reset Esper): no live /data DPC; the patches alone
#     liberate it. -> patch-only (skips the 96 MB wipe, far less USB traffic).
#   Override the auto choice with -WipeData (force wipe) or -NoWipe (force
#   patch-only). If state can't be determined (e.g. Loader was already caught,
#   so there's no Android to probe), the SAFE DEFAULT is to wipe.
#
# Transport rule (matches FLASH-A-NEW-MABU.md): USB is used ONLY when 100%
# necessary -- the Loader flash itself and the adb 'reboot loader' calls that
# enter Loader. USB adb on this hardware times out too fast to rely on, so the
# whole install/provision phase (5/6) runs over WiFi adb on 5555.
#
# Use cases:
#   - Fresh Esper Mabu (auto-detects A->wipe / B->patch-only):
#       .\flash-mabu.ps1 -RestoreMabu
#   - Force a full wipe regardless of detected state:
#       .\flash-mabu.ps1 -WipeData -RestoreMabu
#   - Force patch-only (skip the wipe) on a known State-B unit:
#       .\flash-mabu.ps1 -NoWipe -RestoreMabu
#   - Just neutralize the new init.esper.rc + sdo.sh on a previously-patched unit:
#       .\flash-mabu.ps1 -SkipApps
#
# When the unit is wiped, wifi creds are wiped too. The device will need wifi
# set up via the touch UI before -RestoreMabu / app installs can proceed. The
# script will pause and ask you to set up wifi when this happens.

[CmdletBinding()]
param(
    [switch] $WipeData,          # FORCE the /data wipe regardless of detected state
    [switch] $NoWipe,            # FORCE patch-only (skip the wipe) regardless of detected state
    [int]    $WipeMB = 96,       # 96 MB matches v3 procedure (preserves Dev Options on this build)
    [switch] $RestoreMabu,       # install factorymode + push animations/voice assets
    [switch] $SkipApps,          # only do Loader-side patches; no F-Droid/Lawnchair
    [string] $WifiIp = '192.168.0.18',  # static lease; override if IP changes
    [string] $UsbSerial,         # if known; else autodetect
    [string] $LawnchairApk = 'apks/Lawnchair.apk',
    [string] $FDroidApk    = 'apks/F-Droid.apk',
    [string] $MabuArchive  = 'mabu-archive'
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

function Get-MabuState {
    # Classify the booted unit as 'A', 'B', or 'Unknown' over adb.
    #   A = active Esper: the live DPC io.shoonya.shoonyadpc is installed in
    #       /data/app. It survives the /system patches, so the /data wipe is
    #       required. (Esper's /system apps -- espersupervisor etc. -- persist
    #       through a factory reset, so they DON'T distinguish A from B; the
    #       /data-resident shoonya DPC is the reliable signal.)
    #   B = factory-reset Esper: no live /data DPC; patches alone liberate it.
    #   Unknown = no working shell to probe (caller decides; default is to wipe).
    param([string] $Dev)
    if (-not $Dev) { return 'Unknown' }
    $alive = & $ADB -s $Dev shell 'echo MABU_OK' 2>&1
    if ($alive -notmatch 'MABU_OK') { return 'Unknown' }   # adb wedged/offline
    $dpc = & $ADB -s $Dev shell 'pm path io.shoonya.shoonyadpc 2>/dev/null' 2>&1
    if ($dpc -match 'package:') { return 'A' }
    return 'B'
}

function Find-AdbDevice {
    # -WifiOnly: never fall back to USB. USB adb on this hardware times out too
    # fast to use for installs/pulls, so the provision phase passes -WifiOnly and
    # connects over WiFi (5555) only. USB is reserved for entering Loader.
    param([string] $PreferIp, [int] $TimeoutSec = 180, [switch] $WifiOnly)
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
        # then any usb device (only when USB is acceptable -- i.e. just to enter
        # Loader; skipped under -WifiOnly so installs never run over flaky USB)
        if (-not $WifiOnly) {
            $usb = & $ADB devices 2>&1 | Where-Object { $_ -match '^\d+\s+device$' }
            if ($usb) {
                $serial = ($usb[0] -split '\s+')[0]
                $ok = & $ADB -s $serial shell echo ok 2>&1
                if ($ok -match '^ok') { return $serial }
            }
        }
        Start-Sleep -Seconds 3
    }
    return $null
}

# --- Phase 1: Catch / verify Loader, auto-detect Esper state ---
Section 'Loader detection'
$state = 'Unknown'
if (Test-Loader) {
    Ok 'Loader already present.'
    Warn 'Device is in Loader (not Android), so the Esper state cannot be probed.'
    Warn 'State -> Unknown. If you want auto-detect, let the script catch Loader'
    Warn 'from a booted unit instead, or pass -WipeData / -NoWipe explicitly.'
} else {
    Info 'Loader not seen. Finding an adb device to detect state and enter Loader.'
    $dev = Find-AdbDevice -PreferIp $WifiIp -TimeoutSec 30
    if (-not $dev) {
        Fail 'No adb device and no Loader. Power-cycle the tablet to catch Loader, then re-run.'
        exit 1
    }
    $state = Get-MabuState -Dev $dev
    switch ($state) {
        'A' { Ok  "Detected State A (active Esper DPC in /data) at $dev." }
        'B' { Ok  "Detected State B (factory-reset Esper) at $dev." }
        default { Warn "Could not determine Esper state at $dev (adb may be wedging)." }
    }
    Info "Rebooting into Loader."
    & $ADB -s $dev shell reboot loader 2>&1 | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Loader) { Ok "Loader caught after ${i}s."; break }
    }
    if (-not (Test-Loader)) { Fail 'Loader did not appear in 30s.'; exit 1 }
}

# --- Decide wipe policy: explicit flags win, else auto from detected state ---
if ($WipeData -and $NoWipe) { Fail 'Pass only one of -WipeData / -NoWipe.'; exit 1 }
if     ($WipeData) { $doWipe = $true;  $wipeWhy = 'forced by -WipeData' }
elseif ($NoWipe)   { $doWipe = $false; $wipeWhy = 'forced by -NoWipe' }
elseif ($state -eq 'A') { $doWipe = $true;  $wipeWhy = 'auto: State A (active /data DPC must be wiped)' }
elseif ($state -eq 'B') { $doWipe = $false; $wipeWhy = 'auto: State B (patches alone suffice)' }
else                    { $doWipe = $true;  $wipeWhy = 'auto: state undetermined -> safe default = wipe' }
Section 'Wipe policy'
if ($doWipe) { Ok  "/data wipe: ON  ($wipeWhy)" }
else         { Ok  "/data wipe: OFF ($wipeWhy)" }

# --- Phase 2: Apply patches ---
Section 'Applying liberation patches'
& (Join-Path $Root 'scripts/liberate-mabu.ps1')
if ($LASTEXITCODE -ne 0) { Fail 'liberate-mabu.ps1 failed.'; exit 1 }
Ok 'All 8 patches written.'

# --- Phase 3: /data wipe (State A / forced / undetermined) ---
# A single Loader session can do all 8 small patch writes OR a 96 MB wipe,
# but doing patches+wipe back-to-back wedges Loader on the first wipe chunk.
# Workaround: reset between phases. This means rebooting to Android,
# letting adb come up, then `reboot loader` to re-enter Loader fresh.
if ($doWipe) {
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

Section 'Waiting for WiFi adb'
Info 'USB adb on this hardware times out too fast for installs/pulls --'
Info "the provision phase runs over WiFi adb (${WifiIp}:5555)."
if ($doWipe) {
    Warn '/data was wiped: WiFi credentials are gone.'
    Warn 'On the tablet touch UI, connect to WiFi. Then come back here.'
    Read-Host 'Press Enter once WiFi is associated on the tablet'
}
$dev = Find-AdbDevice -PreferIp $WifiIp -WifiOnly -TimeoutSec 180
if (-not $dev) {
    Warn "Could not reach WiFi adb at ${WifiIp}:5555."
    Warn 'Make sure the tablet is on WiFi (static lease at that IP, or pass -WifiIp).'
    Read-Host 'Press Enter to retry WiFi adb (Ctrl+C to abort)'
    $dev = Find-AdbDevice -PreferIp $WifiIp -WifiOnly -TimeoutSec 180
}
if (-not $dev) {
    Fail 'Timed out waiting for WiFi adb. Check the tablet WiFi / IP.'
    exit 1
}
Ok "Connected over WiFi: $dev"

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

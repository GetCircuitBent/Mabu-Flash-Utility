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
    [string] $WifiIp = '192.168.0.18',  # initial hint only; auto-discovered from the device (wlan0) at runtime
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

# Pre-start the adb server NOW, while errors are non-fatal. The very first adb
# call otherwise prints "* daemon not running; starting now at tcp:5037" to
# stderr, and with $ErrorActionPreference='Stop' the 2>&1 capture turns that
# banner into a terminating NativeCommandError that aborts the whole script
# mid-flash (bit us right after the patch phase). Starting it here means no later
# adb call emits that banner.
$ErrorActionPreference = 'Continue'
& $ADB start-server 2>&1 | Out-Null
$ErrorActionPreference = 'Stop'

function Section($msg) { Write-Host "" -ForegroundColor Cyan; Write-Host "==== $msg ====" -ForegroundColor Cyan }
function Info($msg)    { Write-Host "  $msg" -ForegroundColor Gray }
function Ok($msg)      { Write-Host "  $msg" -ForegroundColor Green }
function Warn($msg)    { Write-Host "  $msg" -ForegroundColor Yellow }
function Fail($msg)    { Write-Host "  $msg" -ForegroundColor Red }

function Test-Loader { (& $RK ld 2>&1) -match 'Vid=0x2207,Pid=0x320a.*Loader' }

function Get-LoaderDriverService {
    # Driver service bound to Loader PID 320A (e.g. 'WinUSB' or 'Rockusb'), or
    # $null if the device isn't present. rkdeveloptool needs WinUSB; when the
    # device is bound to Rockchip's 'Rockusb' (rockusb.sys), 'ld' still LISTS the
    # Loader but any read/write fails with "creating comm object failed".
    $d = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
         Where-Object { $_.InstanceId -match 'VID_2207&PID_320A' } | Select-Object -First 1
    if (-not $d) { return $null }
    return (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue).Data
}

function Find-Zadig {
    # Locate a Zadig exe: winget package dir first, then Program Files.
    $c = @()
    $c += Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\akeo.ie.Zadig_*" -Filter 'zadig*.exe' -Recurse -ErrorAction SilentlyContinue
    $c += Get-ChildItem "$env:ProgramFiles","${env:ProgramFiles(x86)}" -Filter 'zadig*.exe' -Recurse -ErrorAction SilentlyContinue
    return ($c | Select-Object -First 1).FullName
}

function Confirm-LoaderWinUsb {
    # Gate before any Loader read/write: ensure PID 320A is bound to WinUSB.
    # If it's on Rockusb (the default after a first-ever Loader catch on a PC),
    # auto-launch Zadig so the user can rebind 320A -> WinUSB (one-time; persists),
    # then re-verify. Returns once WinUSB is confirmed; exits on failure.
    Section 'Loader driver binding (WinUSB)'
    $svc = Get-LoaderDriverService
    if ($svc -match 'WinUSB|libusb') { Ok "PID 320A bound to '$svc' -- rkdeveloptool can talk to it."; return }

    Warn "PID 320A is bound to '$svc', not WinUSB."
    Warn "rkdeveloptool can SEE Loader but writes fail ('creating comm object failed')."
    Warn 'Launching Zadig to rebind 320A -> WinUSB (one-time per PC; it persists).'
    $zadig = Find-Zadig
    if ($zadig) {
        Info "Zadig: $zadig"
        Start-Process $zadig
        Write-Host ""
        Warn 'In Zadig:'
        Warn '  1. Options -> List All Devices'
        Warn "  2. In the dropdown pick 'Rockusb Device' (USB ID 2207 320A)"
        Warn '  3. Set the target driver to WinUSB, then click Replace Driver'
        Warn "  4. Wait for 'Driver Installed Successfully'"
        Warn 'Keep the tablet powered / in Loader the whole time -- do NOT power-cycle.'
    } else {
        Fail 'Zadig not found. Install it (winget install -e --id akeo.ie.Zadig)'
        Fail 'and rebind 320A -> WinUSB manually, then re-run this script.'
        exit 1
    }
    Read-Host 'Press Enter after Zadig reports the WinUSB driver is installed'

    # Re-verify the binding (device re-enumerates on rebind; allow a moment).
    for ($i = 0; $i -lt 20; $i++) {
        $svc = Get-LoaderDriverService
        if ($svc -match 'WinUSB|libusb') { break }
        Start-Sleep -Seconds 1
    }
    if ($svc -notmatch 'WinUSB|libusb') {
        Fail "PID 320A still bound to '$svc'. Re-run Zadig (target WinUSB), then re-run this script."
        exit 1
    }
    # Confirm rkdeveloptool sees Loader again after the rebind.
    if (-not (Test-Loader)) {
        Warn 'Loader not visible right after rebind; waiting for re-enumeration...'
        for ($i = 0; $i -lt 15; $i++) { Start-Sleep -Seconds 1; if (Test-Loader) { break } }
    }
    if (-not (Test-Loader)) {
        Fail 'Loader gone after rebind. Re-catch Loader (hold ADKEY through power-on) and re-run.'
        exit 1
    }
    Ok "PID 320A now bound to '$svc'. rkdeveloptool ready."
}

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
            # @() forces an array: a single 'serial<TAB>device' match is otherwise
            # a scalar string, so $usb[0] would index its first CHARACTER (e.g.
            # '2' of 2022...), producing "device '2' not found".
            $usb = @(& $ADB devices 2>&1 | Where-Object { $_ -match '^\S+\s+device$' -and $_ -notmatch ':\d+\s+device$' })
            if ($usb.Count -gt 0) {
                $serial = ($usb[0] -split '\s+')[0]
                $ok = & $ADB -s $serial shell echo ok 2>&1
                if ($ok -match '^ok') { return $serial }
            }
        }
        Start-Sleep -Seconds 3
    }
    return $null
}

function Get-DeviceWifiIp {
    # The device's WiFi (wlan0) IPv4, read over an existing adb connection, or
    # $null. Don't trust a hardcoded static lease -- a freshly-wiped unit DHCPs a
    # random IP, so we always re-read the real one.
    param([string] $Dev)
    if (-not $Dev) { return $null }
    $out = (& $ADB -s $Dev shell 'ip -f inet addr show wlan0 2>/dev/null' 2>&1) -join "`n"
    $ip  = ([regex]::Match($out, 'inet\s+(\d{1,3}(?:\.\d{1,3}){3})')).Groups[1].Value
    if (-not $ip) {
        $out = (& $ADB -s $Dev shell 'ip route 2>/dev/null' 2>&1) -join "`n"
        $ip  = ([regex]::Match($out, 'wlan0.*\bsrc\s+(\d{1,3}(?:\.\d{1,3}){3})')).Groups[1].Value
    }
    if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { return $ip }
    return $null
}

function Enable-WifiAdb {
    # Switch adbd into TCP mode on 5555 and connect over WiFi. THE PATCHED ADBD
    # DOES NOT AUTO-LISTEN ON 5555 on every unit (it didn't on 2022010501038), so
    # the provision phase must turn it on explicitly -- this is the step that was
    # missing and why WiFi adb never came up. Also sets persist.adb.tcp.port so
    # WiFi adb survives a reboot that KEEPS /data (the inter-phase Loader
    # re-catch); the /data wipe clears it, so Phase 4 re-runs this. Returns
    # "<ip>:5555" or $null. $UsbDev = a USB adb serial to issue the switch over.
    param([string] $UsbDev)
    if (-not $UsbDev) { return $null }
    $ip = Get-DeviceWifiIp -Dev $UsbDev
    if (-not $ip) { Warn 'Could not read tablet WiFi IP (is it associated to WiFi?).'; return $null }
    Info "Tablet WiFi IP: $ip"
    & $ADB -s $UsbDev shell 'setprop persist.adb.tcp.port 5555' 2>&1 | Out-Null  # best-effort persist
    & $ADB -s $UsbDev tcpip 5555 2>&1 | Out-Null                                 # restarts adbd in TCP mode
    Start-Sleep -Seconds 3
    for ($i = 0; $i -lt 10; $i++) {
        $r = & $ADB connect "${ip}:5555" 2>&1
        if ($r -match 'connected to|already connected') {
            $ok = & $ADB -s "${ip}:5555" shell echo ok 2>&1
            if ($ok -match '^ok') { $script:WifiIp = $ip; return "${ip}:5555" }
        }
        Start-Sleep -Seconds 2
    }
    Warn "tcpip enabled but ${ip}:5555 unreachable (WiFi client isolation, or different subnet)."
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
    # Switch on WiFi adb NOW, while USB is up. This gives the inter-phase Loader
    # re-catch a reliable transport instead of depending on USB re-enumerating
    # after the reboot (it often doesn't on this hardware). persist.adb.tcp.port
    # is set too, so 5555 keeps listening across the (data-preserving) reboot.
    $wifiDev = Enable-WifiAdb -UsbDev $dev
    if ($wifiDev) { Ok "WiFi adb enabled at $wifiDev"; $dev = $wifiDev }
    else          { Warn 'WiFi adb not established now; inter-phase will retry over USB/WiFi.' }
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

# --- Gate: PID 320A must be on WinUSB before any Loader write ---
# 'ld' succeeds even when bound to rockusb.sys, but writes then fail with
# "creating comm object failed". Auto-launch Zadig to rebind if needed.
Confirm-LoaderWinUsb

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
    # The FIRST wl right after the inter-phase re-catch usually wedges at chunk 0
    # because Loader isn't "warm" yet. A throwaway 'ld' + brief pause warms it,
    # and re-running the wipe with Loader still caught succeeds (re-zeroing any
    # already-written chunks is harmless). So warm up, then retry on failure
    # instead of bailing -- this is what makes a top-to-bottom run reliable.
    & $RK ld 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    $wiped = $false
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        & (Join-Path $Root 'scripts/wipe-data-head.ps1') -SizeMB $WipeMB
        if ($LASTEXITCODE -eq 0) { $wiped = $true; break }
        if (-not (Test-Loader)) { Fail "Loader dropped during wipe (attempt $attempt). Power-cycle into Loader and re-run."; exit 1 }
        Warn "Wipe attempt $attempt wedged (cold Loader); warming and retrying..."
        & $RK ld 2>&1 | Out-Null
        Start-Sleep -Seconds 3
    }
    if (-not $wiped) { Fail '/data head wipe failed after 4 attempts.'; exit 1 }
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

Section 'Provisioning transport (WiFi adb)'
Info 'USB adb on this hardware times out too fast for installs/pulls --'
Info 'the provision phase runs over WiFi adb on 5555.'
if ($doWipe) {
    Warn '/data was wiped: WiFi credentials AND the persistent tcpip flag are gone.'
    Warn 'On the tablet touch UI, connect to WiFi, then come back here.'
    Read-Host 'Press Enter once WiFi is associated on the tablet'
}
# Re-establish WiFi adb. The patched adbd does NOT auto-listen on 5555 on this
# unit, so we switch it on over USB and discover the (possibly new) DHCP IP.
# USB is used ONLY for this one switch-over; installs then run over WiFi.
Info 'Acquiring adb after reset (USB to switch on WiFi, or WiFi if already up)...'
$acq = Find-AdbDevice -PreferIp $WifiIp -TimeoutSec 180   # WiFi if already listening, else USB
if (-not $acq) {
    Fail 'No adb (USB or WiFi) after reset.'
    Fail 'Re-seat the USB harness (or fix the tablet WiFi), then finish with:'
    Fail '  .\scripts\flash-mabu.ps1 -RestoreMabu -NoWipe'
    exit 1
}
if ($acq -match ':5555$') {
    $dev = $acq                                   # WiFi adb already up (persist survived a no-wipe run)
    Ok "WiFi adb already up: $dev"
} else {
    $dev = Enable-WifiAdb -UsbDev $acq            # switch adbd to TCP, discover IP, connect
    if (-not $dev) {
        Warn 'WiFi adb unavailable; falling back to USB adb for installs.'
        Warn 'USB installs can wedge on this hardware -- if one fails, fix WiFi adb'
        Warn 'and re-run:  .\scripts\flash-mabu.ps1 -RestoreMabu -NoWipe'
        $dev = $acq
    }
}
Ok "Provisioning over: $dev"

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

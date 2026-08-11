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
#   6. Install Mabu factory mode APK + push animation/voice assets.
#
# State auto-detection (the /data wipe is the only thing that differs):
#   - State A (active Esper): the live DPC io.shoonya.shoonyadpc lives in
#     /data/app and survives the /system patches, so it MUST be wiped. Detected
#     by that package being installed. -> wipe (default).
#   - State B (factory-reset Esper): no live /data DPC; the patches alone
#     liberate it. -> patch-only (skips the 96 MB wipe, far less USB traffic).
#   Override the auto choice with -WipeData (force wipe) or -NoWipe (force
#   patch-only). If state can't be determined (e.g. Loader was already caught,
#   so there's no Android to probe), the script ABORTS and asks for an explicit
#   -WipeData / -NoWipe rather than guessing -- a wrong wipe destroys data AND can
#   trigger the factory burn-in bootloop. -KeepRoot never implies a wipe.
#
# Transport rule (matches FLASH-A-NEW-MABU.md): USB is used ONLY when 100%
# necessary -- the Loader flash itself and the adb 'reboot loader' calls that
# enter Loader. USB adb on this hardware times out too fast to rely on, so the
# whole install/provision phase (5/6) runs over WiFi adb on 5555.
#
# Use cases:
#   - Fresh Esper Mabu (auto-detects A->wipe / B->patch-only):
#       .\flash-mabu.ps1
#   - Force a full wipe regardless of detected state:
#       .\flash-mabu.ps1 -WipeData
#   - Force patch-only (skip the wipe) on a known State-B unit:
#       .\flash-mabu.ps1 -NoWipe
#   - Just neutralize the new init.esper.rc + sdo.sh on a previously-patched unit:
#       .\flash-mabu.ps1 -SkipApps
#
# When the unit is wiped, wifi creds are wiped too. The device will need wifi
# set up via the touch UI before app installs can proceed. The script will pause
# and ask you to set up wifi when this happens.

[CmdletBinding()]
param(
    [switch] $WipeData,          # FORCE the /data wipe regardless of detected state
    [switch] $NoWipe,            # FORCE patch-only (skip the wipe) regardless of detected state
    [int]    $WipeMB = 96,       # 96 MB matches v3 procedure (preserves Dev Options on this build)
    [switch] $SkipApps,          # only do Loader-side patches; no F-Droid/Lawnchair/factorymode
    [switch] $SkipSELinux,       # skip the SELinux policy fix (already applied, or not needed)
    [switch] $KeepRoot,          # persistent uid-0 adbd + permissive shell domain (WiFi /system writes). See ROOT-PATCH.md.
    [switch] $AllowKnownBrokenRoot, # override the KNOWN-BROKEN -KeepRoot gate (patch-rework re-testing ONLY -- see gate below)
    [switch] $Branded,           # deploy the GCB boot animation (/system bootanimation.zip via Loader). See BRANDED-EDITION-SPEC.md.
    [switch] $BrandedPlanOnly,   # -Branded preview: locate + verify + print the write plan, but do NOT write anything
    [string] $WifiIp = '192.168.0.18',  # initial hint only; auto-discovered from the device (wlan0) at runtime
    [string] $UsbSerial,         # if known; else autodetect
    [string] $LawnchairApk = 'apks/Lawnchair.apk',
    [string] $FDroidApk    = 'apks/F-Droid.apk',
    [string] $MabuArchive  = 'mabu-archive'
)

$ErrorActionPreference = 'Stop'

# --- Message helpers (defined first so the bootstrap below can use them) ---
function Section($msg) { Write-Host "" -ForegroundColor Cyan; Write-Host "==== $msg ====" -ForegroundColor Cyan }
function Info($msg)    { Write-Host "  $msg" -ForegroundColor Gray }
function Ok($msg)      { Write-Host "  $msg" -ForegroundColor Green }
function Warn($msg)    { Write-Host "  $msg" -ForegroundColor Yellow }
function Fail($msg)    { Write-Host "  $msg" -ForegroundColor Red }
function Die {
    # Print one or more red lines, then abort. Use this in place of a Fail call
    # followed by a separate exit, so an aborting path can never silently fall
    # through when someone forgets the exit -- Fail on its own only prints.
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Lines)
    foreach ($l in $Lines) { Fail $l }
    exit 1
}

# --- Elevation: driver binding + PnP queries need Administrator ---
# Un-elevated, Get-PnpDevice returns nothing, so the WinUSB check silently reports
# "not bound" even when it is, and Zadig cannot replace the driver. Refuse up front
# with an actionable message rather than self-elevating: this script is interactive
# (Read-Host prompts, long live output) and re-launching would move all of that into
# a new window.
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die 'This script must run as Administrator (USB driver binding and PnP queries require it).' `
        'Close this window, then:' `
        '  1. Right-click the Start menu -> "Windows PowerShell (Admin)" / "Terminal (Admin)"' `
        "  2. cd `"$(Split-Path -Parent $PSScriptRoot)`"" `
        '  3. Re-run this script.'
}

# --- Repo root: derive from the SCRIPT location, never the working directory ---
# $PSScriptRoot is <repo>\scripts, so the parent is the repo root. Using the CWD
# here meant the script only worked when invoked from exactly the repo root -- run
# from scripts\, or from the outer folder of a GitHub ZIP (which nests as
# Mabu-Flash-Utility-main\Mabu-Flash-Utility-main\), and every asset path silently
# pointed at nothing.
$Root = Split-Path -Parent $PSScriptRoot

$RK = Join-Path $Root 'tools/rkdeveloptool/rkdeveloptool.exe'
if (-not (Test-Path $RK)) {
    Die "rkdeveloptool.exe not found at: $RK" `
        'The repo tooling is missing or incomplete. Run the one-time setup first:' `
        '  .\scripts\install-tools.ps1' `
        'If you downloaded the ZIP, make sure you extracted the WHOLE archive and are' `
        'running from the folder that contains scripts\, tools\ and firmware\.'
}

function Test-Winget {
    # winget is absent on Win10 LTSC / Server and on machines where App Installer
    # has never been provisioned. Calling it blind is a terminating
    # CommandNotFoundException, so every auto-install path checks this first.
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

# Locate adb.exe: PATH first, then common install locations, then winget install.
function Find-Adb {
    # PATH
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # Android SDK
    $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path $sdk) { return $sdk }
    # WinGet package dir (may not exist on a fresh machine -- check before Get-ChildItem)
    $wgBase = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path $wgBase) {
        $hit = Get-ChildItem "$wgBase\Google.PlatformTools_*\platform-tools\adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

$ADB = Find-Adb
if (-not $ADB) {
    if (-not (Test-Winget)) {
        Die 'adb (Android platform-tools) was not found, and winget is unavailable to install it.' `
            'Install platform-tools manually, then re-run:' `
            '  https://developer.android.com/tools/releases/platform-tools' `
            'Unzip it and either add the folder to PATH or place it at:' `
            "  $env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
    }
    Warn 'adb not found -- installing Google Platform Tools via winget (one-time)...'
    winget install -e --id Google.PlatformTools --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
    $ADB = Find-Adb
    if (-not $ADB) {
        Die 'adb still not found after the winget install.' `
            'Close and reopen PowerShell (so PATH refreshes), then re-run this script.'
    }
    Ok "adb installed: $ADB"
}

# Pre-start the adb server NOW, while errors are non-fatal. The very first adb
# call otherwise prints "* daemon not running; starting now at tcp:5037" to
# stderr, and with $ErrorActionPreference='Stop' the 2>&1 capture turns that
# banner into a terminating NativeCommandError that aborts the whole script
# mid-flash (bit us right after the patch phase). Starting it here means no later
# adb call emits that banner.
$ErrorActionPreference = 'Continue'
& $ADB start-server 2>&1 | Out-Null
$ErrorActionPreference = 'Stop'

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
    # Explicit candidate paths only. This used to recurse all of Program Files,
    # which measured ~6s on a clean machine (far worse on a loaded one) and sits on
    # the hot path. Candidate list mirrors install-tools.ps1, including scoop.
    $candidates = @(
        (Join-Path $Root 'tools\zadig.exe'),
        (Join-Path $Root 'tools\zadig\zadig*.exe'),
        "$env:USERPROFILE\scoop\apps\zadig\current\zadig.exe",
        "$env:USERPROFILE\scoop\shims\zadig.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\akeo.ie.Zadig*\zadig*.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Akeo.Zadig*\zadig*.exe",
        "$env:ProgramFiles\Zadig\zadig.exe",
        "${env:ProgramFiles(x86)}\Zadig\zadig.exe"
    )
    foreach ($pat in $candidates) {
        $hit = Get-ChildItem -Path $pat -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $cmd = Get-Command zadig -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Install-Zadig {
    if (-not (Test-Winget)) {
        Die 'Zadig is required to bind the Loader to WinUSB, and winget is unavailable to install it.' `
            'Download it manually from https://zadig.akeo.ie/ , then either put zadig.exe in:' `
            "  $(Join-Path $Root 'tools\zadig.exe')" `
            'or install it normally, and re-run this script.'
    }
    Info 'Zadig not found -- installing via winget (one-time)...'
    winget install -e --id akeo.ie.Zadig --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
    $path = Find-Zadig
    if (-not $path) {
        Die 'Zadig install failed. Install it manually from https://zadig.akeo.ie/ and re-run.'
    }
    Ok "Zadig installed: $path"
    return $path
}

function Confirm-LoaderWinUsb {
    # Gate before any Loader read/write: ensure PID 320A is bound to WinUSB.
    # If it's on Rockusb (the default after a first-ever Loader catch on a PC),
    # auto-install + launch Zadig so the user can rebind 320A -> WinUSB (one-time;
    # persists), then re-verify. Returns once WinUSB is confirmed; exits on failure.
    Section 'Loader driver binding (WinUSB)'
    $svc = Get-LoaderDriverService
    if ($svc -match 'WinUSB|libusb') { Ok "PID 320A bound to '$svc' -- rkdeveloptool can talk to it."; return }

    Warn "PID 320A is bound to '$svc', not WinUSB."
    Warn "rkdeveloptool can SEE Loader but writes fail ('creating comm object failed')."
    Warn 'Launching Zadig to rebind 320A -> WinUSB (one-time per PC; it persists).'
    $zadig = Find-Zadig
    if (-not $zadig) { $zadig = Install-Zadig }
    Info "Zadig: $zadig"
    Start-Process $zadig
    Write-Host ""
    Warn 'In Zadig:'
    Warn '  1. Options -> List All Devices'
    Warn "  2. In the dropdown pick 'Rockusb Device' (USB ID 2207 320A)"
    Warn '  3. Set the target driver to WinUSB, then click Replace Driver'
    Warn "  4. Wait for 'Driver Installed Successfully'"
    Warn 'Keep the tablet powered / in Loader the whole time -- do NOT power-cycle.'
    Read-Host 'Press Enter after Zadig reports the WinUSB driver is installed'

    # Re-verify the binding (device re-enumerates on rebind; allow a moment).
    for ($i = 0; $i -lt 20; $i++) {
        $svc = Get-LoaderDriverService
        if ($svc -match 'WinUSB|libusb') { break }
        Start-Sleep -Seconds 1
    }
    if ($svc -notmatch 'WinUSB|libusb') {
        Die "PID 320A still bound to '$svc'. Re-run Zadig (target WinUSB), then re-run this script."
    }
    # Confirm rkdeveloptool sees Loader again after the rebind.
    if (-not (Test-Loader)) {
        Warn 'Loader not visible right after rebind; waiting for re-enumeration...'
        for ($i = 0; $i -lt 15; $i++) { Start-Sleep -Seconds 1; if (Test-Loader) { break } }
    }
    if (-not (Test-Loader)) {
        Die 'Loader gone after rebind. Re-catch Loader (hold ADKEY through power-on) and re-run.'
    }
    Ok "PID 320A now bound to '$svc'. rkdeveloptool ready."
}

function Get-MabuState {
    # Classify the booted unit as 'A', 'B', 'Liberated', or 'Unknown' over adb.
    #   A         = active Esper: live DPC io.shoonya.shoonyadpc in /data/app.
    #               Patches alone don't suffice; /data wipe required.
    #   B         = factory-reset Esper: no live /data DPC; patches alone suffice.
    #   Liberated = already patched: init.esper.rc was zeroed, so init.svc.set-device-owner
    #               was never defined and its getprop returns empty. Skip Loader entirely.
    #   Unknown   = no working shell to probe (caller decides; default is to wipe).
    param([string] $Dev)
    if (-not $Dev) { return 'Unknown' }
    $alive = & $ADB -s $Dev shell 'echo MABU_OK' 2>&1
    if ($alive -notmatch 'MABU_OK') { return 'Unknown' }   # adb wedged/offline
    $dpc = & $ADB -s $Dev shell 'pm path io.shoonya.shoonyadpc 2>/dev/null' 2>&1
    if ($dpc -match 'package:') { return 'A' }
    # On unpatched units init.esper.rc defines the set-device-owner service, so
    # getprop init.svc.set-device-owner is 'stopped' after boot. When the RC file
    # has been zeroed the service is never registered and the prop is empty.
    $svc = & $ADB -s $Dev shell 'getprop init.svc.set-device-owner' 2>&1
    if ($svc -match '^\s*$') { return 'Liberated' }
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
            # If a specific USB serial was requested (a multi-tablet bench may have
            # OTHER adb devices attached), only ever select that one -- never touch
            # an unrelated device.
            if ($script:UsbSerial) { $usb = @($usb | Where-Object { ($_ -split '\s+')[0] -eq $script:UsbSerial }) }
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

function Confirm-RootPatchApplies {
    # BRICK GUARD for -KeepRoot. The rootdrop patch overwrites adbd's sector 29
    # (file offset 0x3A00, 512 bytes) with a PRECOMPUTED sector that differs from
    # the reference by exactly 2 bytes. That is only safe if THIS unit's live adbd
    # sector 29 is byte-identical to the reference the patch was built against
    # (firmware/originals/adbd-rootdrop-orig.bin). A different adbd build => the
    # write clobbers unrelated bytes and corrupts adbd (adb/boot break). If it
    # doesn't match, abort and tell the operator to rebuild the patch against this
    # unit (scripts/build_root_patch.py). See ROOT-PATCH.md / ROOT-A-FRESH-MABU.md.
    param([string] $Dev)
    Section '-KeepRoot: verifying root patch matches this unit''s adbd'
    $orig = Join-Path $Root 'firmware/originals/adbd-rootdrop-orig.bin'
    if (-not (Test-Path $orig)) { Die "Missing reference $orig -- cannot verify. Aborting -KeepRoot." }
    if (-not $Dev) {
        Die 'No booted adb device to pull the live adbd from. -KeepRoot must verify the patch' `
            'against the target unit BEFORE flashing. Boot to Android and re-run.'
    }
    $scratch = Join-Path $Root 'firmware/scratch'
    New-Item -ItemType Directory -Force $scratch | Out-Null
    $live = Join-Path $scratch 'adbd-live.bin'
    Remove-Item $live -ErrorAction SilentlyContinue
    Info "Pulling /system/bin/adbd from $Dev ..."
    # adb prints its "1 file pulled ..." progress to STDERR; under the script's
    # $ErrorActionPreference='Stop' a 2>&1 capture turns that benign line into a
    # terminating NativeCommandError and aborts the run. Drop to Continue around the
    # pull (same guard the script uses for the adb-server pre-start), then restore.
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $ADB -s $Dev pull /system/bin/adbd $live 2>&1 | Out-Null
    $ErrorActionPreference = $eap
    if (-not (Test-Path $live)) { Die 'Could not pull /system/bin/adbd. Aborting -KeepRoot.' }
    $bytes = [System.IO.File]::ReadAllBytes($live)
    if ($bytes.Length -lt 0x3C00) { Die "Live adbd is only $($bytes.Length) bytes -- unexpected. Aborting -KeepRoot." }
    $origSector = [System.IO.File]::ReadAllBytes($orig)
    $match = ($origSector.Length -eq 512)
    if ($match) { for ($i = 0; $i -lt 512; $i++) { if ($bytes[0x3A00 + $i] -ne $origSector[$i]) { $match = $false; break } } }
    if (-not $match) {
        Die 'Live adbd sector 29 does NOT match the reference the root patch was built from.' `
            'This unit likely ships a different adbd build; writing the precomputed patch would' `
            'corrupt adbd. Rebuild the patch against THIS unit first:' `
            "  1. adb -s $Dev pull /system/bin/adbd firmware/originals/adbd.bin" `
            '  2. python scripts/build_root_patch.py   (asserts the drop-block entry is a bl,' `
            '     then regenerates firmware/patches/adbd-rootdrop-patched.bin)' `
            '  3. re-run with -KeepRoot once the new patch is confirmed.'
    }
    Ok 'Live adbd sector 29 matches the reference -- root patch will apply cleanly (2-byte edit only).'
}

function Apply-SELinuxFix {
    # Patch /vendor/etc/selinux/precompiled_sepolicy to allow untrusted_app to
    # open/write serial_device (needed for the facetrack app to drive the motors).
    # With -PermissiveShell, ALSO make the `shell` domain permissive so uid-0
    # adbd (the -KeepRoot patch) can remount and write /system over WiFi.
    # Uses on-device magiskpolicy (ARM), pulls the result, then writes it via Loader.
    #   Stock SHA:        7f26df2d...
    #   Motor-only SHA:   03f180a2... (299,979 B, same-size bit-flip -> raw overwrite safe)
    #   +permissive shell: size/SHA measured live (permissive may GROW the policy;
    #                      guarded below -- see ROOT-PATCH.md "SELinux caveat").
    param([string] $Dev, [switch] $PermissiveShell)
    Section 'SELinux policy fix'
    $sha = (& $ADB -s $Dev shell 'sha256sum /vendor/etc/selinux/precompiled_sepolicy 2>/dev/null' 2>&1) -join ''
    if (-not $PermissiveShell -and $sha -match '03f180a2') { Ok 'SELinux policy already patched (03f180a2) -- skipping.'; return }
    if ($sha -match '7f26df2d') { Info 'Stock policy confirmed (7f26df2d).' }
    elseif ($sha -match '03f180a2') { Info 'Motor-rule policy present (03f180a2); adding permissive shell on top.' }
    else { Warn "Unexpected policy SHA: $sha -- proceeding anyway." }

    $mp = Join-Path $Root 'tools/magiskpolicy/magiskpolicy-armeabi-v7a'
    if (-not (Test-Path $mp)) { Warn 'tools/magiskpolicy/magiskpolicy-armeabi-v7a not found -- skipping.'; return }
    & $ADB -s $Dev push $mp /data/local/tmp/magiskpolicy 2>&1 | Out-Null
    & $ADB -s $Dev shell 'chmod 755 /data/local/tmp/magiskpolicy' 2>&1 | Out-Null

    # Build the magiskpolicy rule list. Motor rule always; permissive shell opt-in.
    $rules = @("'allow untrusted_app serial_device chr_file { open read write getattr ioctl }'")
    if ($PermissiveShell) { $rules += "'permissive shell'"; Warn 'Including: permissive shell (uid-0 adbd -> WiFi /system writes). See ROOT-PATCH.md.' }
    $ruleArgs = $rules -join ' '

    $r = & $ADB -s $Dev shell "cp /vendor/etc/selinux/precompiled_sepolicy /data/local/tmp/sepolicy.in && /data/local/tmp/magiskpolicy --load /data/local/tmp/sepolicy.in --save /data/local/tmp/sepolicy.out $ruleArgs && echo PATCH_OK" 2>&1
    if ($r -notmatch 'PATCH_OK') { Warn "magiskpolicy failed: $($r -join ' ') -- skipping."; return }
    Ok 'On-device patch succeeded.'

    # Size guard: the raw Loader overwrite (wl at the file's data blocks) is only
    # block-safe if the patched policy still fits the original's allocated blocks.
    # The motor bit-flip kept 299,979 B exactly. `permissive shell` may grow it.
    $inSize  = [int]((& $ADB -s $Dev shell 'stat -c %s /data/local/tmp/sepolicy.in'  2>&1) -join '').Trim()
    $outSize = [int]((& $ADB -s $Dev shell 'stat -c %s /data/local/tmp/sepolicy.out' 2>&1) -join '').Trim()
    Info "sepolicy size: in=$inSize out=$outSize bytes (74 blocks = 303,104 B allocated)"

    $outFile = Join-Path $Root 'firmware\scratch\sepolicy.patched'
    & $ADB -s $Dev pull /data/local/tmp/sepolicy.out $outFile 2>&1 | Out-Null
    if (-not (Test-Path $outFile)) { Warn 'Pull failed -- skipping Loader write.'; return }
    $patchedSha = (Get-FileHash $outFile -Algorithm SHA256).Hash.ToLower()
    Info "Patched SHA256: $patchedSha"

    if (-not $PermissiveShell) {
        # Motor-only path: unchanged, expect the known same-size result.
        if ($patchedSha -notmatch '^03f180a2') { Warn "Patched SHA unexpected ($patchedSha) -- aborting Loader write."; return }
    } else {
        if ($outSize -eq $inSize) {
            Ok "permissive-shell policy is same size ($outSize B) -> raw overwrite is block-safe, no i_size patch needed."
        } elseif ($outSize -le 303104) {
            Warn "permissive-shell policy GREW to $outSize B (was $inSize). Still <= 74 blocks, but the inode i_size MUST be patched to $outSize or the kernel reads a truncated policy. Phase 7 does NOT do i_size patching -- STOP and follow ROOT-PATCH.md 'SELinux caveat' (locate_vendor_policy.py -> patch i_size -> write blocks). Not writing automatically."
            return
        } else {
            Warn "permissive-shell policy is $outSize B > 303,104 B (74 blocks) -- does NOT fit a raw overwrite. Use the full /vendor reflash path. Not writing."
            return
        }
    }

    Info 'Entering Loader for policy write...'
    & $ADB -s $Dev shell reboot loader 2>&1 | Out-Null
    for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Seconds 1; if (Test-Loader) { Ok "Loader caught after ${i}s."; break } }
    if (-not (Test-Loader)) { Warn 'Loader not caught. Apply SELinux fix manually (wl 0x5A8AB8 firmware\scratch\sepolicy.patched).'; return }
    Confirm-LoaderWinUsb

    & $RK wl 0x5A8AB8 $outFile 2>&1 | ForEach-Object { Info $_ }
    Ok 'Policy written to vendor partition.'
    & $RK rd 2>&1 | Out-Null
    Ok 'Reset issued -- device will reboot with patched SELinux policy.'
}

function Run-SelfTest {
    param([string] $Dev)
    Section 'Self-test'
    $stP = 0; $stF = 0; $stW = 0

    # --- Liberation ---
    $v = (& $ADB -s $Dev shell 'getprop ro.device_owner' 2>&1) -join ''
    if ($v -match '^\s*$|false') { Ok  '[PASS] No device owner';                       $stP++ }
    else                         { Fail "[FAIL] No device owner  (got: $v)";            $stF++ }

    $v = (& $ADB -s $Dev shell 'getprop init.svc.set-device-owner' 2>&1) -join ''
    if ($v -match '^\s*$')       { Ok  '[PASS] init.esper.rc zeroed';                  $stP++ }
    else                         { Fail "[FAIL] init.esper.rc zeroed  (got: $v)";       $stF++ }

    $v = (& $ADB -s $Dev shell 'pm path io.shoonya.shoonyadpc 2>/dev/null' 2>&1) -join ''
    if ($v -match '^\s*$')       { Ok  '[PASS] Esper DPC absent from /data';           $stP++ }
    else                         { Fail "[FAIL] Esper DPC absent from /data  (got: $v)"; $stF++ }

    $v = (& $ADB -s $Dev shell 'getprop ro.boot.veritymode' 2>&1) -join ''
    if ($v -match 'disabled')    { Ok  '[PASS] dm-verity disabled';                    $stP++ }
    else                         { Fail "[FAIL] dm-verity disabled  (got: $v)";         $stF++ }

    # --- Apps ---
    $v = (& $ADB -s $Dev shell 'pm list packages org.fdroid.fdroid 2>/dev/null' 2>&1) -join ''
    if ($v -match 'package:')    { Ok  '[PASS] F-Droid installed';                     $stP++ }
    else                         { Fail '[FAIL] F-Droid installed';                     $stF++ }

    $v = (& $ADB -s $Dev shell 'pm list packages app.lawnchair 2>/dev/null' 2>&1) -join ''
    if ($v -match 'package:')    { Ok  '[PASS] Lawnchair installed';                   $stP++ }
    else                         { Fail '[FAIL] Lawnchair installed';                   $stF++ }

    $v = (& $ADB -s $Dev shell 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null' 2>&1) -join ''
    if ($v -match 'lawnchair')   { Ok  '[PASS] Lawnchair is home launcher';            $stP++ }
    else                         { Fail "[FAIL] Lawnchair is home launcher  (got: $v)"; $stF++ }

    $v = (& $ADB -s $Dev shell 'pm list packages com.catalia.factorymode 2>/dev/null' 2>&1) -join ''
    if ($v -match 'package:')    { Ok  '[PASS] Mabu factory mode installed';           $stP++ }
    else                         { Fail '[FAIL] Mabu factory mode installed';           $stF++ }

    # --- SELinux ---
    $v = (& $ADB -s $Dev shell 'getenforce' 2>&1) -join ''
    if ($v -match 'Enforcing')   { Ok  '[PASS] SELinux enforcing';                     $stP++ }
    else                         { Fail "[FAIL] SELinux enforcing  (got: $v)";          $stF++ }

    $v = (& $ADB -s $Dev shell 'sha256sum /vendor/etc/selinux/precompiled_sepolicy 2>/dev/null' 2>&1) -join ''
    if ($v -match '03f180a2')    { Ok  '[PASS] SELinux policy patched (03f180a2)';     $stP++ }
    else                         { Fail "[FAIL] SELinux policy patched  (got: $v)";     $stF++ }

    # --- WiFi adb (warn only -- quarantine/isolated nets block WiFi-to-Ethernet) ---
    $wlanOut = (& $ADB -s $Dev shell 'ip addr show wlan0 2>/dev/null' 2>&1) -join ' '
    $wlanIp  = ([regex]::Match($wlanOut, 'inet\s+(\d{1,3}(?:\.\d{1,3}){3})')).Groups[1].Value
    if ($wlanIp) {
        $r  = (& $ADB connect "${wlanIp}:5555" 2>&1) -join ''
        $ok = if ($r -match 'connected to|already connected') { (& $ADB -s "${wlanIp}:5555" shell echo ok 2>&1) -join '' } else { '' }
        if   ($ok -match 'ok') { Ok   "[PASS] WiFi adb reachable ($wlanIp`:5555)";             $stP++ }
        else                   { Warn "[WARN] WiFi adb unreachable ($wlanIp`:5555) -- network isolation?"; $stW++ }
    } else { Warn '[WARN] WiFi adb: no IP on wlan0'; $stW++ }

    # --- Summary ---
    Write-Host ''
    $col = if ($stF -gt 0) { 'Red' } elseif ($stW -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host "  Self-test: $stP passed  $stF failed  $stW warnings" -ForegroundColor $col
    if ($stF -gt 0) { Warn 'One or more checks FAILED -- review before deploying this unit.' }
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
    # Try WiFi connect first -- adbd may already be listening on 5555 (e.g. from a
    # prior run), avoiding USB adb calls that can hang after an aborted session.
    $r = & $ADB connect "${ip}:5555" 2>&1
    if ($r -match 'connected to|already connected') {
        $ok = & $ADB -s "${ip}:5555" shell echo ok 2>&1
        if ($ok -match '^ok') { $script:WifiIp = $ip; return "${ip}:5555" }
    }
    # Not already listening -- switch adbd to TCP mode via USB.
    # Both calls can hang when USB adb is wedged; cap each at 8s.
    $spJob = Start-Job { param($adb,$dev) & $adb -s $dev shell 'setprop persist.adb.tcp.port 5555' 2>&1 } -ArgumentList $ADB,$UsbDev
    if (-not (Wait-Job $spJob -Timeout 8)) { Stop-Job $spJob }
    Remove-Job $spJob -Force
    $tcpJob = Start-Job { param($adb,$dev) & $adb -s $dev tcpip 5555 2>&1 } -ArgumentList $ADB,$UsbDev
    if (-not (Wait-Job $tcpJob -Timeout 8)) {
        Stop-Job $tcpJob
        Warn 'adb tcpip timed out (USB adb wedged); will try WiFi connect anyway.'
    }
    Remove-Job $tcpJob -Force
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

function Deploy-BootAnimation {
    # Replace /system/media/bootanimation.zip with the GCB branded zip via the
    # Loader same-inode overwrite + i_size patch (assets/bootanimation/DEPLOY.md).
    # No root: /system is writable on a liberated (verity-off) unit.
    #
    # Safety: scripts/stage_bootanim.py locates the file by directory walk and
    # REFUSES unless the located inode's i_size equals the stock size (proves we
    # found the real stock file) and metadata_csum is OFF. -PlanOnly stops before
    # any write so the plan can be eyeballed on the real unit first. Every write is
    # read-verified afterward. NOT yet hardware-validated -- run -BrandedPlanOnly
    # first. $Dev = a live adb device (for the verity check + /system start LBA).
    param([string] $Dev, [switch] $PlanOnly)
    Section 'Branding: GCB boot animation'
    $zip = Join-Path $Root 'assets/bootanimation/bootanimation.zip'
    $py  = Join-Path $Root 'scripts/stage_bootanim.py'
    if (-not (Test-Path $zip)) { Warn "Branded zip not found: $zip -- skipping."; return }
    if (-not (Test-Path $py))  { Warn "stage_bootanim.py not found -- skipping."; return }
    if (-not $Dev) { Warn 'No adb device to read /system start LBA / verity -- skipping branding.'; return }

    # 1. verity must be OFF (liberated) or the kernel won't mount a modified /system
    $vm = (& $ADB -s $Dev shell 'getprop ro.boot.veritymode' 2>&1) -join ''
    if ($vm -notmatch 'disabled') { Warn "dm-verity is '$vm' (not disabled) -- refusing to write /system. Liberate first."; return }

    # 1b. inode + size straight from the device (skips the ext4 directory walk, which
    #     would need directory-data blocks that can sit beyond the dumpable head).
    # No spaces/quotes in the format string: nested quotes get mangled through
    # PowerShell -> Windows adb.exe -> device shell (stat then treats %s as a file).
    $statOut = (& $ADB -s $Dev shell 'stat -c %i:%s /system/media/bootanimation.zip' 2>&1) -join ' '
    $mi = [regex]::Match($statOut, '(\d+):(\d+)')
    if (-not $mi.Success) { Warn "Could not stat bootanimation.zip (got '$statOut') -- skipping."; return }
    $bootInode = [int]$mi.Groups[1].Value
    $bootSize  = [int64]$mi.Groups[2].Value
    Info "bootanimation.zip on device: inode=$bootInode size=$bootSize"
    if ($bootSize -ne 1870133) { Warn "On-device size $bootSize != stock 1,870,133 -- not the stock file (already branded / different build). Skipping."; return }

    # 2. Determine /system's rkdeveloptool (raw eMMC) LBA. IMPORTANT: the kernel's
    #    /sys .../start is NOT the rl address on this hardware -- rl reads zeros there.
    #    The real ext4 superblock sits at the parameter file's (system) LBA (0x18A000),
    #    ~0x2000 sectors BELOW the /sys value (0x18C000). rkdeveloptool has no GPT
    #    ('ppt' = none), it's pure raw LBA. So gather candidates and (step 4) pick the
    #    one whose sector actually carries the ext4 superblock.
    $cands = New-Object System.Collections.Generic.List[uint64]
    $pf = Join-Path $Root 'firmware/originals/parameter.img'
    if (Test-Path $pf) {
        $ptxt = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($pf))
        $mm = [regex]::Match($ptxt, '@0x([0-9A-Fa-f]+)\(system\)')
        if ($mm.Success) { $cands.Add([Convert]::ToUInt64($mm.Groups[1].Value, 16)) }
    }
    $sysRaw = (& $ADB -s $Dev shell 'cat /sys/class/block/mmcblk1p11/start' 2>&1) -join ''
    $sysLba = 0; [void][uint64]::TryParse(($sysRaw -replace '\D', ''), [ref]$sysLba)
    if ($sysLba -gt 0x2000) { $cands.Add([uint64]($sysLba - 0x2000)); $cands.Add([uint64]$sysLba) }
    $cands = @($cands | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    if ($cands.Count -eq 0) { Warn 'Could not determine any /system LBA candidate -- skipping.'; return }
    Info ('/system LBA candidates (rl-space): ' + (($cands | ForEach-Object { '0x{0:X}' -f $_ }) -join ', '))

    # 3. Loader + WinUSB for the dump/writes
    Info 'Entering Loader for the /system dump...'
    & $ADB -s $Dev shell reboot loader 2>&1 | Out-Null
    for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Seconds 1; if (Test-Loader) { break } }
    if (-not (Test-Loader)) { Warn 'Loader not caught -- skipping branding.'; return }
    Confirm-LoaderWinUsb

    # 4. Dump /system head in 4 MB chunks. KNOWN read-wedge: a fresh Loader session
    #    reliably yields ~5-6 4 MB reads (~20-24 MB) before wedging; a single 28 MB
    #    read trips it on chunk 0 and returns all zeros. So read chunk-by-chunk into
    #    one file, up to a safe budget, then validate the ext4 superblock (chunk 0).
    #    ~24 MB covers the file's metadata (the 28 MB head worked for staging).
    $scratch = Join-Path $Root 'assets/bootanimation/scratch'
    New-Item -ItemType Directory -Force $scratch | Out-Null
    $dump = Join-Path $scratch 'system-head.img'
    Remove-Item $dump -ErrorAction SilentlyContinue
    & $RK ld 2>&1 | Out-Null; Start-Sleep -Seconds 2
    $chunkSectors = 8192          # 4 MB
    $maxChunks    = 6             # ~24 MB, under the ~6-7 wedge ceiling
    # Temp chunk MUST be a space-free path: Start-Process -ArgumentList (PS 5.1) does
    # not quote array elements, so a path with a space (our repo lives under
    # "D:\Claude Projects\...") would be split and rkdeveloptool writes nothing.
    $tmp = Join-Path $env:TEMP 'rk-bootanim-chunk.bin'

    # Probe each candidate with a cheap 4 KB read; use the one whose sector carries
    # the ext4 superblock magic (0xEF53 at byte 0x438). This auto-corrects the
    # /sys-vs-rl LBA discrepancy without hardcoding an offset.
    $startLba = 0
    foreach ($c in $cands) {
        Remove-Item $tmp -ErrorAction SilentlyContinue
        & $RK rl $c 8 $tmp 2>&1 | Out-Null
        if (Test-Path $tmp) {
            $pb = [System.IO.File]::ReadAllBytes($tmp)
            if ($pb.Length -ge 0x43A -and $pb[0x438] -eq 0x53 -and $pb[0x439] -eq 0xEF) { $startLba = $c; break }
        }
        Info ('candidate 0x{0:X}: no ext4 superblock' -f $c)
    }
    if ($startLba -eq 0) { Warn 'No /system LBA candidate had an ext4 superblock -- skipping branding.'; & $RK rd 2>&1 | Out-Null; return }
    $lbaHex = '0x{0:X}' -f $startLba
    Ok "/system rl-LBA resolved: $startLba ($lbaHex)"

    $stream = [System.IO.File]::Open($dump, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $gotChunks = 0
    try {
        for ($k = 0; $k -lt $maxChunks; $k++) {
            $absLba = $startLba + $k * $chunkSectors
            Remove-Item $tmp -ErrorAction SilentlyContinue
            $p = Start-Process -FilePath $RK -ArgumentList @('rl', $absLba, $chunkSectors, $tmp) -NoNewWindow -PassThru -RedirectStandardOutput "$tmp.out" -RedirectStandardError "$tmp.err"
            if (-not $p.WaitForExit(30000)) {
                try { Stop-Process -Id $p.Id -Force } catch {}
                Get-Process rkdeveloptool -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Warn "chunk $($k+1) wedged (timeout) -- stopping with $gotChunks chunk(s)."; break
            }
            # Trust the file SIZE, not rkdeveloptool's exit code (this build returns
            # nonzero even on a clean read). A full-size chunk = good; a short one = wedge.
            # Chunk 0's ext4 superblock check below guards against a full-size zero read.
            $sz = if (Test-Path $tmp) { (Get-Item $tmp).Length } else { 0 }
            if ($sz -ne ($chunkSectors * 512)) { Warn "chunk $($k+1) short (got $sz B -- wedge) -- stopping with $gotChunks chunk(s)."; break }
            $b = [System.IO.File]::ReadAllBytes($tmp); $stream.Write($b, 0, $b.Length); $stream.Flush()
            $gotChunks++
            Info "dumped chunk $($k+1) (@LBA $absLba, 4 MB) -- total $($gotChunks * 4) MB"
        }
    } finally { $stream.Close(); Remove-Item $tmp, "$tmp.out", "$tmp.err" -ErrorAction SilentlyContinue }
    if ($gotChunks -eq 0) { Warn 'No chunks read -- skipping branding.'; & $RK rd 2>&1 | Out-Null; return }
    $fs = [System.IO.File]::OpenRead($dump)
    try { [void]$fs.Seek(0x438, 'Begin'); $m0 = $fs.ReadByte(); $m1 = $fs.ReadByte() } finally { $fs.Close() }
    if (-not ($m0 -eq 0x53 -and $m1 -eq 0xEF)) { Warn 'chunk 0 has no ext4 superblock -- unexpected; skipping.'; & $RK rd 2>&1 | Out-Null; return }
    Ok "ext4 superblock present; dumped $($gotChunks * 4) MB in $gotChunks chunk(s)."

    # 5. Plan (locate + verify + emit write plan; never touches the device)
    $planOut = & python $py $dump $zip $lbaHex $scratch $bootInode 2>&1
    $rc = $LASTEXITCODE
    $planOut | ForEach-Object { Info $_ }
    if ($rc -ne 0) {
        switch ($rc) {
            2 { Warn 'metadata_csum ON -> i_size hand-edit unsafe. Use the full-image reflash path (out of scope here).' }
            3 { Warn 'Located file is NOT the stock bootanimation.zip (already branded, or different build). Not writing.' }
            4 { Warn 'Branded zip too big for the file''s allocated extents. Not writing.' }
            default { Warn 'Could not locate bootanimation.zip in the 28 MiB head dump (may need a larger/second dump region). Not writing.' }
        }
        Info 'Rebooting out of Loader.'; & $RK rd 2>&1 | Out-Null
        return
    }
    $plan = Get-Content (Join-Path $scratch 'plan.json') -Raw | ConvertFrom-Json
    Info ("Plan: new_size={0} (was {1}); {2} content write(s), {3} inode sector(s); first content LBA {4}" -f `
          $plan.new_size, $plan.old_size, $plan.content_writes.Count, $plan.inode_writes.Count, $plan.first_content_lba)

    if ($PlanOnly) {
        Warn 'PLAN-ONLY: no device writes performed. Review the plan above, then re-run'
        Warn 'without -BrandedPlanOnly to apply. Rebooting out of Loader.'
        & $RK rd 2>&1 | Out-Null
        return
    }

    # 6. Write content extents, then the patched inode sector(s)
    foreach ($w in $plan.content_writes) {
        $r = (& $RK wl $w.lba $w.file 2>&1) -join ' '
        if ($r -notmatch '100%') { Fail "Content write @LBA $($w.lba) failed: $r"; Fail 'Original may be partially overwritten -- restore stock bootanimation.zip via Loader.'; return }
        Info "wrote content @LBA $($w.lba) ($($w.nsect) sectors)"
    }
    foreach ($w in $plan.inode_writes) {
        $r = (& $RK wl $w.lba $w.file 2>&1) -join ' '
        if ($r -notmatch '100%') { Fail "Inode write @LBA $($w.lba) failed: $r"; return }
        Info "wrote inode sector @LBA $($w.lba) (i_size patched)"
    }

    # 7. Read-verify: re-read each written sector-0 and confirm it matches what we wrote
    $okAll = $true
    $chk = Join-Path $scratch 'verify.bin'
    foreach ($w in @($plan.inode_writes[0], $plan.content_writes[0])) {
        & $RK rl $w.lba 1 $chk 2>&1 | Out-Null
        $a = (Get-FileHash $chk -Algorithm SHA256).Hash
        # compare against the first 512 bytes of the file we wrote
        $exp = [System.IO.File]::ReadAllBytes($w.file)[0..511]
        $tmp = Join-Path $scratch 'exp512.bin'; [System.IO.File]::WriteAllBytes($tmp, [byte[]]$exp)
        $b = (Get-FileHash $tmp -Algorithm SHA256).Hash
        if ($a -ne $b) { $okAll = $false; Fail "Verify MISMATCH @LBA $($w.lba)" } else { Ok "verified @LBA $($w.lba)" }
    }
    if ($okAll) { Ok 'Boot animation written and verified. It plays on next boot.' }
    else        { Fail 'Verification failed -- restore stock bootanimation.zip via Loader before booting.' }

    Info 'Rebooting.'; & $RK rd 2>&1 | Out-Null
}

function Set-BrandWallpaper {
    # Set the GCB home + lock wallpaper via the helper APK (no root; SET_WALLPAPER
    # is auto-granted). The helper uses setBitmap, which COPIES the image into the
    # wallpaper store, so we uninstall it afterward and the wallpaper persists.
    # Runs over adb (device booted to Android after the boot-anim reboot).
    param([string] $Dev)
    Section 'Branding: home + lock wallpaper'
    $apk = Join-Path $Root 'apks/gcb-wallpaper.apk'
    if (-not (Test-Path $apk)) { Warn "Wallpaper helper APK not found: $apk -- skipping wallpaper."; return }
    if (-not $Dev) { Warn 'No adb device -- skipping wallpaper.'; return }
    Info 'Installing GCB wallpaper helper...'
    $r = (& $ADB -s $Dev install -r $apk 2>&1) -join ' '
    if ($r -notmatch 'Success') { Warn "Wallpaper helper install failed: $r -- skipping."; return }
    & $ADB -s $Dev logcat -c 2>&1 | Out-Null
    & $ADB -s $Dev shell am start -n com.getcircuitbent.wallpaper/.SetWallpaperActivity 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    $log = (& $ADB -s $Dev logcat -d -s GCBWallpaper 2>&1) -join "`n"
    if ($log -match 'set OK') { Ok 'GCB wallpaper applied (home + lock).' }
    else { Warn "Wallpaper helper did not confirm success -- verify on device. (logcat: $log)" }
    # helper copied the image into the wallpaper store; remove it to leave a clean device
    & $ADB -s $Dev uninstall com.getcircuitbent.wallpaper 2>&1 | Out-Null
    Ok 'Wallpaper helper removed (wallpaper persists -- copied, not referenced).'
}

function Invoke-Branding {
    # Full -Branded pass: deploy the boot animation (Loader /system write, reboots),
    # then -- unless plan-only -- re-acquire adb and set the wallpaper.
    param([string] $Dev)
    Deploy-BootAnimation -Dev $Dev -PlanOnly:$BrandedPlanOnly
    if ($BrandedPlanOnly) { return }
    Info 'Waiting for adb after the boot-animation reboot (for the wallpaper step)...'
    $wpDev = Find-AdbDevice -PreferIp $WifiIp -TimeoutSec 120
    if ($wpDev) { Set-BrandWallpaper -Dev $wpDev }
    else        { Warn 'Wallpaper skipped: no adb device came back after the boot-animation reboot.' }
}

# --- -KeepRoot safety gate: the rootdrop patch is KNOWN-BROKEN on the H7R build ---
# PROVEN 2026-07-07 (unit 2022010500003): flashing the rootdrop adbd patch produces
# an adbd that does NOT come up -- no USB adb gadget, no TCP listener -- so adb is
# unreachable and root is NOT achieved. The WRITE is correct (sector reads back as the
# patched sha 7da6ee29); the patched adbd is simply non-functional at runtime. Reverting
# the single sector to stock (adbd-rootdrop-orig.bin) restores adb. Do NOT flash -KeepRoot
# until the patch is reworked -- analyze what the keep-root branch (0xBBBE) actually does
# at runtime, not just that build_root_patch.py found a `bl`. See ROOT-A-FRESH-MABU.md /
# mabuflash-keeproot-hardening. Override ONLY to re-test a reworked patch.
if ($KeepRoot -and -not $AllowKnownBrokenRoot) {
    Section '-KeepRoot refused (known-broken patch)'
    Die 'The -KeepRoot rootdrop adbd patch is KNOWN-BROKEN on this H7R build: the patched' `
        'adbd does not start (no USB adb, no TCP listener), so adb dies and root is NOT' `
        'achieved. Proven 2026-07-07 on unit 2022010500003; reverting the sector to stock' `
        'restored adb. Rework the patch before using this (analyze the keep-root path at' `
        '0xBBBE at runtime, not just that it is a bl). To re-test a REWORKED patch anyway,' `
        're-run with -AllowKnownBrokenRoot.'
}
if ($KeepRoot -and $AllowKnownBrokenRoot) {
    Warn '-KeepRoot override: proceeding with a patch KNOWN to break adbd on this build.'
    Warn 'Expect adb to be unreachable after flashing unless the patch has been reworked.'
}

# --- Phase 1: Catch / verify Loader, auto-detect Esper state ---
Section 'Loader detection'
$state = 'Unknown'
if (Test-Loader) {
    Ok 'Loader already present.'
    Warn 'Device is in Loader (not Android), so the Esper state cannot be probed.'
    Warn 'State -> Unknown. If you want auto-detect, let the script catch Loader'
    Warn 'from a booted unit instead, or pass -WipeData / -NoWipe explicitly.'
    if ($KeepRoot) {
        Die '-KeepRoot needs a BOOTED unit so the root patch can be verified against this' `
            "build's adbd before flashing (a mismatched build would corrupt adbd). Boot to" `
            'Android and re-run; do not start a -KeepRoot run from an already-caught Loader.'
    }
} else {
    Info 'Loader not seen. Finding an adb device to detect state and enter Loader.'
    $dev = Find-AdbDevice -PreferIp $WifiIp -TimeoutSec 30
    if (-not $dev) {
        Die 'No adb device and no Loader. Power-cycle the tablet to catch Loader, then re-run.'
    }
    $state = Get-MabuState -Dev $dev
    switch ($state) {
        'A'         { Ok   "Detected State A (active Esper DPC in /data) at $dev." }
        'B'         { Ok   "Detected State B (factory-reset Esper) at $dev." }
        'Liberated' { Ok   "Device already liberated at $dev -- skipping Loader flash." }
        default     { Warn "Could not determine Esper state at $dev (adb may be wedging)." }
    }
    # -KeepRoot brick guard: verify the precomputed rootdrop patch matches THIS
    # unit's adbd build before we ever write it (works for A / B / Liberated --
    # all have a booted $dev here). Aborts on drift.
    if ($KeepRoot) { Confirm-RootPatchApplies -Dev $dev }
    # Enter Loader for the patch phase whenever there's Loader work to do: any
    # not-yet-liberated unit, OR a -KeepRoot run (which must reach Loader to write
    # the rootdrop patch even on an already-liberated unit).
    if ($state -ne 'Liberated' -or $KeepRoot) {
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
        if (-not (Test-Loader)) { Die 'Loader did not appear in 30s.' }
    }
}

if ($state -eq 'Liberated' -and -not $KeepRoot) {
    Info 'Skipping wipe policy, patches, and wipe -- device is already liberated.'
}
elseif ($state -eq 'Liberated' -and $KeepRoot) {
    Info 'Device already liberated; -KeepRoot re-applies the liberation patches (idempotent)'
    Info 'plus the rootdrop patch, with NO /data wipe.'
}

# --- Decide wipe policy: explicit flags win, else auto from detected state ---
if (($state -ne 'Liberated' -or $KeepRoot) -and $WipeData -and $NoWipe) { Die 'Pass only one of -WipeData / -NoWipe.' }
if ($state -ne 'Liberated' -or $KeepRoot) {
Section 'Wipe policy'
if     ($WipeData) {
    $doWipe = $true;  $wipeWhy = 'forced by -WipeData'
    if ($KeepRoot) {
        Warn '-WipeData + -KeepRoot: the /data wipe can drop a fresh unit into the factory'
        Warn 'burn-in state that bootloops (com.cghs.stresstest reboots the device on boot).'
        Warn 'Watch the first boot; if it loops, disable that package before judging root'
        Warn '(see ROOT-A-FRESH-MABU.md).'
    }
}
elseif ($NoWipe)        { $doWipe = $false; $wipeWhy = 'forced by -NoWipe' }
elseif ($KeepRoot) {
    # -KeepRoot must NEVER imply a wipe: a surprise wipe both destroys /data and can
    # trigger the burn-in bootloop. Default OFF; the operator can still force one
    # with an explicit -WipeData above.
    $doWipe = $false; $wipeWhy = 'auto: -KeepRoot never implies a wipe (pass -WipeData to force one)'
    if ($state -eq 'A') {
        Warn 'State A (active Esper DPC in /data) + -KeepRoot with no wipe: liberation may be'
        Warn 'INCOMPLETE -- the live /data DPC survives the /system patches. For a full de-Esper,'
        Warn 'either liberate first WITHOUT -KeepRoot (confirm a clean boot) then add root as a'
        Warn 'standalone step, or pass -WipeData explicitly (mind the burn-in caveat).'
    }
}
elseif ($state -eq 'A') { $doWipe = $true;  $wipeWhy = 'auto: State A (active /data DPC must be wiped)' }
elseif ($state -eq 'B') { $doWipe = $false; $wipeWhy = 'auto: State B (patches alone suffice)' }
else {
    # Was previously a silent WIPE default. That risks destroying data / triggering the
    # burn-in loop on a unit we could not classify. Refuse to guess instead.
    Die 'Esper state is undetermined -- no Android shell was available to classify it' `
        '(e.g. Loader was already caught, so there was no booted unit to probe).' `
        'Refusing to guess the /data wipe. Re-run from a BOOTED unit (auto-detects), or' `
        'pass an explicit choice:' `
        '  -NoWipe    factory-reset / already-liberated unit (patches alone suffice)' `
        '  -WipeData  active Esper unit that must be de-provisioned'
}
if ($doWipe) { Ok  "/data wipe: ON  ($wipeWhy)" }
else         { Ok  "/data wipe: OFF ($wipeWhy)" }

# --- Gate: PID 320A must be on WinUSB before any Loader write ---
# 'ld' succeeds even when bound to rockusb.sys, but writes then fail with
# "creating comm object failed". Auto-launch Zadig to rebind if needed.
Confirm-LoaderWinUsb

# --- Phase 2: Apply patches ---
Section 'Applying liberation patches'
if ($KeepRoot) {
    # flash-mabu already passed the known-broken gate above; tell liberate-mabu not to re-block.
    & (Join-Path $Root 'scripts/liberate-mabu.ps1') -KeepRoot -AllowKnownBrokenRoot
} else {
    & (Join-Path $Root 'scripts/liberate-mabu.ps1')
}
if ($LASTEXITCODE -ne 0) { Die 'liberate-mabu.ps1 failed.' }
Ok 'Liberation patches written.'

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
    if (-not $bootDev) { Die 'No adb after inter-phase reset. Power-cycle and retry.' }
    Ok "adb up at $bootDev"
    & $ADB -s $bootDev shell reboot loader 2>&1 | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Loader) { Ok "Loader re-caught after ${i}s."; break }
    }
    if (-not (Test-Loader)) { Die 'Loader not re-caught.' }

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
        if (-not (Test-Loader)) { Die "Loader dropped during wipe (attempt $attempt). Power-cycle into Loader and re-run." }
        Warn "Wipe attempt $attempt wedged (cold Loader); warming and retrying..."
        & $RK ld 2>&1 | Out-Null
        Start-Sleep -Seconds 3
    }
    if (-not $wiped) { Die '/data head wipe failed after 4 attempts.' }
    Ok '/data head zeroed; vold will reformat on boot.'
}

# --- Phase 4: Reset and wait for adb ---
Section 'Resetting device'
& $RK rd 2>&1 | Out-Null
Ok 'Reset issued.'
} # end if ($state -ne 'Liberated' -or $KeepRoot) -- wipe policy / patches / wipe / Loader reset

if ($SkipApps) {
    Write-Host ""
    Ok 'Loader-side patches done. SkipApps requested -- no userspace install.'
    if ($Branded) {
        # brand-only / patch+brand run: boot animation + wallpaper
        $brandDev = Find-AdbDevice -PreferIp $WifiIp -TimeoutSec 120
        if ($brandDev) { Invoke-Branding -Dev $brandDev }
        else { Warn 'Branding skipped: no adb device found.' }
    }
    exit 0
}

# Destructive Loader work is done. Provisioning is best-effort; a transient
# adb hiccup should warn, not abort the whole script.
$ErrorActionPreference = 'Continue'

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
    Die 'No adb (USB or WiFi) after reset.' `
        'Re-seat the USB harness (or fix the tablet WiFi), then finish with:' `
        '  .\scripts\flash-mabu.ps1 -NoWipe'
}
if ($acq -match ':5555$') {
    $dev = $acq                                   # WiFi adb already up (persist survived a no-wipe run)
    Ok "WiFi adb already up: $dev"
} else {
    $dev = Enable-WifiAdb -UsbDev $acq            # switch adbd to TCP, discover IP, connect
    if (-not $dev) {
        Warn 'WiFi adb unavailable; falling back to USB adb for installs.'
        Warn 'USB installs can wedge on this hardware -- if one fails, fix WiFi adb'
        Warn 'and re-run:  .\scripts\flash-mabu.ps1 -NoWipe'
        $dev = $acq
    }
}
Ok "Provisioning over: $dev"

# Quick audit
Section 'Post-boot audit'
$audit = & $ADB -s $dev shell 'echo DO=$(getprop ro.device_owner); echo SDOSVC=$(getprop init.svc.set-device-owner); dumpsys device_policy 2>/dev/null | grep -E "Device managed|provisioningState" | head -3; pm list packages 2>/dev/null | grep -iE "esper|shoonya" | head -5' 2>&1
$audit | ForEach-Object { Info $_ }

# --- Phase 5: Install user-facing apps ---
Section 'Installing user apps'
if (-not (Test-Path (Join-Path $Root $FDroidApk))) { Warn "Missing APK: $FDroidApk -- skipping" }
elseif ((& $ADB -s $dev shell 'pm list packages org.fdroid.fdroid 2>/dev/null' 2>&1) -match 'package:') { Ok 'F-Droid already installed -- skipping.' }
else {
    $r = (& $ADB -s $dev install (Join-Path $Root $FDroidApk) 2>&1) | Where-Object { $_ -notmatch 'RemoteException' } | Select-Object -Last 1
    Info "$FDroidApk : $r"
}

if (-not (Test-Path (Join-Path $Root $LawnchairApk))) { Warn "Missing APK: $LawnchairApk -- skipping" }
elseif ((& $ADB -s $dev shell 'pm list packages app.lawnchair 2>/dev/null' 2>&1) -match 'package:') { Ok 'Lawnchair already installed -- skipping.' }
else {
    $r = (& $ADB -s $dev install (Join-Path $Root $LawnchairApk) 2>&1) | Where-Object { $_ -notmatch 'RemoteException' } | Select-Object -Last 1
    Info "$LawnchairApk : $r"
}
& $ADB -s $dev shell 'cmd package set-home-activity app.lawnchair/.LawnchairLauncher' 2>&1 | Out-Null
Ok 'Lawnchair set as default launcher.'

# --- Phase 6: Mabu factory mode + assets ---
if (-not $SkipApps) {
    Section 'Installing Mabu factory mode + assets'
    $installed = (& $ADB -s $dev shell 'pm list packages | grep -i catalia') 2>&1
    if ($installed -match 'com.catalia.factorymode') {
        Info 'com.catalia.factorymode already installed -- skipping APK install.'
    } else {
        $apk = Join-Path $Root "$MabuArchive/apks/com.catalia.factorymode.apk"
        $r = (& $ADB -s $dev install $apk 2>&1) | Where-Object { $_ -notmatch 'RemoteException' } | Select-Object -Last 1
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

# --- Phase 7: SELinux policy fix ---
if (-not $SkipApps -and -not $SkipSELinux) {
    # Find a live adb device for the on-device patch step. WiFi may be down after
    # the assets push, so allow USB fallback -- SELinux only does small shell ops.
    $selinuxDev = Find-AdbDevice -PreferIp $WifiIp -TimeoutSec 120
    if (-not $selinuxDev) { $selinuxDev = $dev }
    Apply-SELinuxFix -Dev $selinuxDev -PermissiveShell:$KeepRoot
}

# --- Phase 8: Self-test ---
# The SELinux fix ends with a Loader reset; wait for the device to come back
# before running tests. If SELinux was skipped the device is already up.
if (-not $SkipApps) {
    Info 'Waiting for device to come up for self-test...'
    $testDev = Find-AdbDevice -PreferIp $WifiIp -TimeoutSec 120
    if ($testDev) {
        & $ADB -s $testDev shell 'cmd package set-home-activity app.lawnchair/.LawnchairLauncher' 2>&1 | Out-Null
        Run-SelfTest -Dev $testDev
    }
    else          { Warn 'Self-test skipped: no adb device found after reboot.' }
}

# --- Phase 9: Branding (GCB boot animation + wallpaper) ---
if ($Branded) {
    $brandDev = Find-AdbDevice -PreferIp $WifiIp -TimeoutSec 120
    if ($brandDev) { Invoke-Branding -Dev $brandDev }
    else           { Warn 'Branding skipped: no adb device found for the boot-animation deploy.' }
}

Section 'Done'
Ok "Unit at $dev liberated and provisioned. Verify on-device:"
Info '  - Home screen = Lawnchair (long-press to customize)'
Info '  - F-Droid available for additional apps'
if (-not $SkipApps) {
    Info '  - Mabu Factory Mode launches motor diagnostics'
    Info '  - Open Trouble Shooting/Motor Debug to recalibrate motors'
}
if (-not $SkipSELinux) {
    Info '  - SELinux fix applied: untrusted_app can open serial_device (motors)'
}

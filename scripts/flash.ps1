# flash.ps1
#
# The one command to flash a Mabu. Liberates the unit from its factory lock,
# provisions user apps, and opens motor access; then self-tests the result.
#
# This is the merged, canonical flasher. It supersedes the older pair (now
# removed; see git history):
#   - flash-mabu.ps1      (liberation + wipe + apps + on-device magiskpolicy SELinux)
#   - flash-new-mabu.ps1  (WSL sepolicy-inject SELinux + USB re-enumeration hardening)
#
# What it does, in order:
#   0. Release USB + purge stale VID_2207 entries so Windows re-enumerates clean.
#      (The whole script requires Administrator, so this always runs.)
#   1. Check prerequisites (rkdeveloptool, adb, patch payloads, magiskpolicy).
#   2. Detect Rockchip Loader; if absent, find an adb device, AUTO-DETECT the
#      Esper state (A / B / Liberated), enable Wi-Fi ADB, then enter Loader.
#   3. Apply the 8 liberation patches (parameter + adbd + 3x EOCD + 2x init).
#   4. Wipe the head of /data when the unit is State A (or forced / undetermined).
#   5. Reset to Android, re-acquire adb over Wi-Fi (installs run over Wi-Fi).
#   6. Install user apps: F-Droid, Lawnchair (set as home).
#   7. Install Mabu factory mode + push assets (unless -SkipMabu).
#   8. Motor SELinux fix (see below).
#   9. Self-test (12 checks) and print a pass/fail summary.
#
# SELinux motor fix (Phase 8): the patched policy is produced on-device with
# magiskpolicy (no WSL needed). If the patch does NOT change the policy file's
# size, it is written surgically to the /vendor policy extent via Loader: the
# validated fast path. If magiskpolicy grows the file (it can spill past its
# allocated blocks), the script automatically FALLS BACK to a full /vendor
# reflash, which loop-mounts the partition image in WSL to swap the file in.
# The fallback needs WSL2 + Ubuntu; if that isn't installed the script says so
# and leaves the unit unmodified rather than writing a truncated policy.
#
# State auto-detection (only the /data wipe differs):
#   - State A (active Esper DPC in /data)      -> wipe (default)
#   - State B (factory-reset Esper, no DPC)    -> patch-only, no wipe
#   - Liberated (already patched)              -> skip Loader, go to provisioning
#   Override with -WipeData / -NoWipe. Undetermined state -> safe default = wipe.
#
# Transport rule: USB is used ONLY when necessary (the Loader flash and the adb
# 'reboot loader' calls). USB adb on this hardware times out too fast to rely on,
# so installs/pulls run over Wi-Fi ADB on 5555. A wiped unit loses its Wi-Fi creds;
# the script pauses and asks you to rejoin Wi-Fi on the tablet's touch UI.

[CmdletBinding()]
param(
    [switch] $WipeData,          # FORCE the /data wipe regardless of detected state
    [switch] $NoWipe,            # FORCE patch-only (skip the wipe) regardless of state
    [int]    $WipeMB = 96,       # 96 MB matches v3 procedure (preserves Dev Options)
    [switch] $SkipApps,          # only do Loader-side patches; no F-Droid/Lawnchair/Mabu
    [switch] $SkipMabu,          # install F-Droid/Lawnchair but not Mabu factory mode
    [switch] $SkipSELinux,       # skip the motor SELinux fix (already applied, or not needed)
    [switch] $PurgeUsb,          # up front, release USB + drop stale VID_2207 PnP entries so Windows re-enumerates clean.
                                 # Not needed for a normal flash; Phase 2 runs the same purge on its own when the bus looks
                                 # wedged, so this is only for starting from a known-clean slate.
    [string] $WifiIp,            # optional Wi-Fi IP hint; auto-discovered from the device otherwise
    [string] $LawnchairApk = 'apks/Lawnchair.apk',
    [string] $FDroidApk    = 'apks/F-Droid.apk',
    [string] $MabuArchive  = 'mabu-archive'
)

$ErrorActionPreference = 'Stop'

# Resolve everything from the repo (via this script's location), NOT the current
# directory, so the flash works from any folder the repo is unzipped into.
$RepoRoot   = Split-Path -Parent $PSScriptRoot
$RK         = Join-Path $RepoRoot 'tools\rkdeveloptool\rkdeveloptool.exe'
$scratchDir = Join-Path $RepoRoot 'firmware\scratch'
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

function Test-Winget {
    # winget is absent on Win10 LTSC / Server and on machines where App Installer
    # has never been provisioned. Calling it blind is a terminating
    # CommandNotFoundException under ErrorActionPreference='Stop', so every
    # auto-install path checks this first.
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

function Find-Adb {
    # Candidate order is shared with Get-AdbPath in install-tools.ps1 and the
    # helper scripts -- keep them in step. The repo-relative copy installed by
    # install-tools.ps1 is checked FIRST because it is the only location that
    # survives an elevation which switches user accounts: this script forces
    # admin, and if the signed-in user is not an admin then %LOCALAPPDATA% below
    # points at a different profile entirely.
    $repo = Join-Path $RepoRoot 'tools\platform-tools\adb.exe'
    if (Test-Path $repo) { return $repo }
    # PATH (covers scoop/choco/manual installs), then the Android SDK, then the
    # winget package dir. The winget parent may not exist on a fresh machine, so
    # it is Test-Path'd before the wildcard Get-ChildItem.
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path $sdk) { return $sdk }
    $wgBase = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path $wgBase) {
        $hit = Get-ChildItem "$wgBase\Google.PlatformTools_*\platform-tools\adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

$ADB = Find-Adb

# Pre-start the adb server NOW, while errors are non-fatal. The first adb call
# otherwise prints "* daemon not running; starting now..." to stderr, and with
# $ErrorActionPreference='Stop' the 2>&1 capture turns that banner into a
# terminating error that aborts mid-flash. Starting it here avoids that later.
if ($ADB -and (Test-Path $ADB)) {
    $ErrorActionPreference = 'Continue'
    & $ADB start-server 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
}

function Section($msg) { Write-Host "" ; Write-Host "==== $msg ====" -ForegroundColor Cyan }
function Info($msg)    { Write-Host "  $msg" -ForegroundColor Gray }
function Ok($msg)      { Write-Host "  $msg" -ForegroundColor Green }
function Warn($msg)    { Write-Host "  $msg" -ForegroundColor Yellow }
function Fail($msg)    { Write-Host "  $msg" -ForegroundColor Red }
function Die {
    # Print one or more red lines, then abort. Use this in place of a Fail call
    # followed by a separate exit, so an aborting path can never silently fall
    # through when someone forgets the exit -- Fail on its own only prints.
    # (MabuFlashCore.ps1 has the same idea as Abort(), which throws instead of
    # exiting because the GUI cannot exit the host process.)
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Lines)
    foreach ($l in $Lines) { Fail $l }
    exit 1
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Elevation is required, not just nice-to-have: Zadig cannot replace the Loader's
# driver without it, and Phase 0's pnputil device removal is admin-only too.
# Note that PnP *queries* are NOT the reason -- Get-PnpDevice,
# Get-PnpDeviceProperty (DEVPKEY_Device_Service) and `pnputil /enum-drivers` all
# work fine un-elevated; an earlier version of this comment claimed otherwise.
# The script refuses up front with an actionable message rather than failing
# confusingly mid-flash. (The packaged .exe already carries a
# requireAdministrator manifest, so this only matters when running flash.ps1
# directly.) Because this gate exits, everything below can assume Administrator.
if (-not (Test-Admin)) {
    Die 'This script must run as Administrator (USB driver binding and PnP queries require it).' `
        'Close this window, then:' `
        '  1. Right-click the Start menu -> "Windows PowerShell (Admin)" / "Terminal (Admin)"' `
        "  2. cd `"$RepoRoot`"" `
        '  3. Re-run this script.'
}

# Convert a Windows path (D:\a\b) to its WSL mount path (/mnt/d/a/b). Derived
# from wherever the repo lives; never hardcode a specific location.
function ConvertTo-WslPath([string]$WinPath) {
    $full = [System.IO.Path]::GetFullPath($WinPath)
    if ($full -match '^([A-Za-z]):(.*)$') {
        $drive = $matches[1].ToLower()
        $rest  = $matches[2] -replace '\\','/'
        return "/mnt/$drive$rest"
    }
    return ($full -replace '\\','/')
}

# Name of an installed Ubuntu WSL distro, or $null. Used only by the SELinux
# reflash fallback; the default magiskpolicy path needs no WSL.
function Get-WslUbuntu {
    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) { return $null }
    $d = (wsl --list --quiet 2>$null) | Where-Object { $_ -match 'Ubuntu' } | Select-Object -First 1
    if ($d) { return $d.Trim() }
    return $null
}

function Test-Loader { (& $RK ld 2>&1) -match 'Vid=0x2207,Pid=0x320a.*Loader' }

function Wait-Loader([int]$TimeoutSec = 30) {
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        if (Test-Loader) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Get-LoaderDriverService {
    # Driver service bound to Loader PID 320A (e.g. 'WinUSB' or 'Rockusb'), or
    # $null. rkdeveloptool needs WinUSB; on 'Rockusb' (rockusb.sys) 'ld' still
    # LISTS the Loader but any read/write fails with "creating comm object failed".
    $d = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
         Where-Object { $_.InstanceId -match 'VID_2207&PID_320A' } | Select-Object -First 1
    if (-not $d) { return $null }
    return (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue).Data
}

function Find-Zadig {
    # Explicit candidate paths only. Recursing all of Program Files measured ~6s on
    # a clean machine (far worse on a loaded one) and this sits on the hot path.
    $candidates = @(
        (Join-Path $RepoRoot 'tools\zadig.exe'),
        (Join-Path $RepoRoot 'tools\zadig\zadig*.exe'),
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

function Confirm-LoaderWinUsb {
    # Gate before any Loader read/write: ensure PID 320A is bound to WinUSB. If
    # it's on Rockusb (the default after a first-ever Loader catch), auto-launch
    # Zadig so the user can rebind 320A -> WinUSB (one-time per PC), then re-verify.
    Section 'Loader Driver Binding (WinUSB)'
    $svc = Get-LoaderDriverService
    if ($svc -match 'WinUSB|libusb') { Ok "PID 320A bound to '$svc'; rkdeveloptool can talk to it."; return }

    Warn "PID 320A is bound to '$svc', not WinUSB."
    Warn "rkdeveloptool can SEE Loader but writes fail ('creating comm object failed')."
    Warn 'Launching Zadig to rebind 320A -> WinUSB (one-time per PC; it persists).'
    $zadig = Find-Zadig
    if (-not $zadig) {
        if (Test-Winget) {
            Warn 'Zadig not found: installing via winget...'
            winget install -e --id akeo.ie.Zadig --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
            $zadig = Find-Zadig
        } else {
            Warn 'Zadig not found and winget is unavailable on this machine.'
            Warn 'Download it from https://zadig.akeo.ie/ and place zadig.exe at:'
            Warn "  $(Join-Path $RepoRoot 'tools\zadig.exe')"
        }
    }
    if ($zadig) {
        Info "Zadig: $zadig"
        Start-Process $zadig
        Write-Host ""
        Warn 'In Zadig:'
        Warn '  1. Options -> List All Devices'
        Warn "  2. In the dropdown pick 'Rockusb Device' (USB ID 2207 320A)"
        Warn '  3. Set the target driver to WinUSB, then click Replace Driver'
        Warn "  4. Wait for 'Driver Installed Successfully'"
        Warn 'Keep the tablet powered / in Loader the whole time; do NOT power-cycle.'
    } else {
        Die 'Zadig not found and could not be installed. Install it from https://zadig.akeo.ie/' `
            'rebind 320A -> WinUSB manually, then re-run this script.'
    }
    Read-Host 'Press Enter after Zadig reports the WinUSB driver is installed'

    for ($i = 0; $i -lt 20; $i++) {
        $svc = Get-LoaderDriverService
        if ($svc -match 'WinUSB|libusb') { break }
        Start-Sleep -Seconds 1
    }
    if ($svc -notmatch 'WinUSB|libusb') {
        Die "PID 320A still bound to '$svc'. Re-run Zadig (target WinUSB), then re-run this script."
    }
    if (-not (Test-Loader)) {
        Warn 'Loader not visible right after rebind; waiting for re-enumeration...'
        for ($i = 0; $i -lt 15; $i++) { Start-Sleep -Seconds 1; if (Test-Loader) { break } }
    }
    if (-not (Test-Loader)) {
        Die 'Loader gone after rebind. Re-catch Loader (hold ADKEY through power-on) and re-run.'
    }
    Ok "PID 320A now bound to WinUSB. rkdeveloptool ready."
}

function Get-MabuState {
    # Classify a booted unit as 'A' / 'B' / 'Liberated' / 'Unknown' over adb.
    param([string] $Dev)
    if (-not $Dev) { return 'Unknown' }
    $alive = & $ADB -s $Dev shell 'echo MABU_OK' 2>&1
    if ($alive -notmatch 'MABU_OK') { return 'Unknown' }
    $dpc = & $ADB -s $Dev shell 'pm path io.shoonya.shoonyadpc 2>/dev/null' 2>&1
    if ($dpc -match 'package:') { return 'A' }
    $svc = & $ADB -s $Dev shell 'getprop init.svc.set-device-owner' 2>&1
    if ($svc -match '^\s*$') { return 'Liberated' }
    return 'B'
}

function Find-AdbDevice {
    # -WifiOnly: never fall back to USB (installs/pulls need Wi-Fi; USB is only for Loader).
    param([string] $PreferIp, [int] $TimeoutSec = 180, [switch] $WifiOnly)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($PreferIp) {
            $r = & $ADB connect "${PreferIp}:5555" 2>&1
            if ($r -match 'connected to|already connected') {
                $ok = & $ADB -s "${PreferIp}:5555" shell echo ok 2>&1
                if ($ok -match '^ok') { return "${PreferIp}:5555" }
            }
        }
        if (-not $WifiOnly) {
            $usb = @(& $ADB devices 2>&1 | Where-Object { $_ -match '^\S+\s+device$' -and $_ -notmatch ':\d+\s+device$' })
            if ($usb.Count -gt 0) {
                $serial = ($usb[0] -split '\s+')[0]
                $ok = & $ADB -s $serial shell echo ok 2>&1
                if ($ok -match '^ok') { return $serial }
            }
            # An 'unauthorized' device never matches the 'device' pattern above,
            # so without this the loop just spins to the full timeout with no
            # explanation. Warn once, then keep waiting in case they approve it.
            if (-not $script:WarnedUnauthorized) {
                $unauth = @(& $ADB devices 2>&1 | Where-Object { $_ -match '^\S+\s+unauthorized$' })
                if ($unauth.Count -gt 0) {
                    $script:WarnedUnauthorized = $true
                    Warn 'A tablet is attached but reports "unauthorized".'
                    Warn 'Accept the "Allow USB debugging?" prompt on the tablet screen.'
                    Warn 'Note: adb host keys live in %USERPROFILE%\.android and the adb SERVER'
                    Warn 'owns them, so a key approved under a different account (or a server'
                    Warn 'started by one) will not carry over. If no prompt appears, run'
                    Warn '"adb kill-server" and re-plug so the server restarts under this account.'
                }
            }
        }
        Start-Sleep -Seconds 3
    }
    return $null
}

function Get-DeviceWifiIp {
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
    # Switch adbd into TCP mode on 5555 and connect over Wi-Fi. The patched adbd
    # does NOT auto-listen on 5555 on every unit, so switch it on explicitly.
    # persist.adb.tcp.port makes Wi-Fi ADB survive a data-preserving reboot.
    param([string] $UsbDev)
    if (-not $UsbDev) { return $null }
    $ip = Get-DeviceWifiIp -Dev $UsbDev
    if (-not $ip) { Warn 'Could not read tablet Wi-Fi IP (is it associated to Wi-Fi?).'; return $null }
    Info "Tablet Wi-Fi IP: $ip"
    $r = & $ADB connect "${ip}:5555" 2>&1
    if ($r -match 'connected to|already connected') {
        $ok = & $ADB -s "${ip}:5555" shell echo ok 2>&1
        if ($ok -match '^ok') { $script:WifiIp = $ip; return "${ip}:5555" }
    }
    $spJob = Start-Job { param($adb,$dev) & $adb -s $dev shell 'setprop persist.adb.tcp.port 5555' 2>&1 } -ArgumentList $ADB,$UsbDev
    if (-not (Wait-Job $spJob -Timeout 8)) { Stop-Job $spJob }
    Remove-Job $spJob -Force
    $tcpJob = Start-Job { param($adb,$dev) & $adb -s $dev tcpip 5555 2>&1 } -ArgumentList $ADB,$UsbDev
    if (-not (Wait-Job $tcpJob -Timeout 8)) { Stop-Job $tcpJob; Warn 'adb tcpip timed out (USB ADB wedged); trying Wi-Fi anyway.' }
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
    Warn "tcpip enabled but ${ip}:5555 unreachable (Wi-Fi client isolation, or different subnet)."
    return $null
}

# ---------------------------------------------------------------------------
# SELinux motor fix: magiskpolicy on-device by default; WSL reflash on spill.
# ---------------------------------------------------------------------------
function Write-PolicySurgical {
    # Fast path: patched policy is the same size as the original, so overwrite
    # its blocks in place at the known /vendor extent. No WSL, no full reflash.
    param([string] $Dev, [string] $OutFile)
    $patchedSha = (Get-FileHash $OutFile -Algorithm SHA256).Hash.ToLower()
    Info "Patched SHA256: $patchedSha"
    Info 'Entering Loader to write policy...'
    & $ADB -s $Dev shell reboot loader 2>&1 | Out-Null
    if (-not (Wait-Loader 30)) { Warn 'Loader not caught for policy write. Fix: rkdeveloptool wl 0x5A8AB8 firmware\scratch\sepolicy.patched'; return $false }
    Confirm-LoaderWinUsb
    $wlOut = & $RK wl 0x5A8AB8 $OutFile 2>&1
    $wlOut | ForEach-Object { Info $_ }
    if (-not ($wlOut -join ' ' -match '100%')) { Warn 'Policy write did not report 100%.'; return $false }
    Ok 'Policy written to /vendor via Loader (surgical).'
    & $RK rd 2>&1 | Out-Null
    Ok 'Reset issued: device reboots with patched SELinux policy.'
    return $true
}

function Invoke-WslVendorReflash {
    # Fallback: the patched policy changed size, so it can't be overwritten in
    # place. Swap it into a full /vendor image and reflash the whole partition.
    # Loop-mounting an ext4 image needs WSL2 + Ubuntu.
    param([string] $Dev, [string] $PatchedPolicy)
    $ubuntu = Get-WslUbuntu
    if (-not $ubuntu) {
        Fail 'The patched policy grew, so the SELinux fix needs the WSL reflash fallback,'
        Fail 'but WSL2 + Ubuntu is not installed. Install it (run scripts\install-tools.ps1'
        Fail '-InstallWsl as Administrator, or: wsl --install Ubuntu ; restart), then re-run'
        Fail 'with -NoWipe.'
        Fail 'The unit was NOT modified by the SELinux step.'
        return $false
    }
    if ($Dev -notmatch ':5555$') {
        Warn "Vendor reflash needs Wi-Fi ADB for the cycled dump; current device is '$Dev'."
        $wifi = Enable-WifiAdb -UsbDev $Dev
        if ($wifi) { $Dev = $wifi } else { Fail 'Could not establish Wi-Fi ADB for the reflash fallback.'; return $false }
    }

    Section 'SELinux Fallback: Full /vendor Reflash (via WSL)'
    $vendorImg = Join-Path $scratchDir 'vendor-full.img'
    Remove-Item $vendorImg, (Join-Path $scratchDir 'vendor-full.state.json') -ErrorAction SilentlyContinue

    Info 'Dumping /vendor (256 MB) over Wi-Fi ADB; this takes a few minutes...'
    & (Join-Path $RepoRoot 'scripts\dump-system-cycled.ps1') `
        -Name 'vendor-full' -PartitionStartLBA 0x592000 -TotalMB 256 -WifiAdb $Dev -StartFresh
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $vendorImg)) { Fail 'Vendor dump failed; SELinux fix not applied.'; return $false }
    $imgMB = [math]::Round((Get-Item $vendorImg).Length / 1MB, 1)
    if ($imgMB -lt 255) { Fail "vendor-full.img is only ${imgMB} MB: dump incomplete."; return $false }
    Ok "vendor-full.img: ${imgMB} MB"

    $wVendor  = ConvertTo-WslPath $vendorImg
    $wPatched = ConvertTo-WslPath $PatchedPolicy
    Info 'Swapping patched policy into the /vendor image (WSL loop-mount)...'
    $r2 = wsl -d $ubuntu -u root -- bash -c @"
set -e
mkdir -p /mnt/vendor
mount -o loop '$wVendor' /mnt/vendor
cp '$wPatched' /mnt/vendor/etc/selinux/precompiled_sepolicy
sync
umount /mnt/vendor
echo ROUTE2_OK
"@ 2>&1
    $r2 | ForEach-Object { Info $_ }
    if (-not ($r2 -join ' ' -match 'ROUTE2_OK')) { Fail 'WSL mount/copy failed; /vendor NOT reflashed.'; return $false }

    Info 'Entering Loader to reflash /vendor...'
    & $ADB -s $Dev shell reboot loader 2>&1 | Out-Null
    if (-not (Wait-Loader 30)) { Fail 'Loader not caught for /vendor reflash.'; return $false }
    Confirm-LoaderWinUsb
    Info 'Flashing /vendor (256 MB; a few minutes)...'
    $wlOut = & $RK wl 0x592000 $vendorImg 2>&1
    $wlOut | ForEach-Object { Info $_ }
    if (-not ($wlOut -join ' ' -match '100%')) { Fail 'wl for /vendor did not report 100%. Re-run: rkdeveloptool wl 0x592000 firmware\scratch\vendor-full.img'; return $false }
    Ok '/vendor reflashed with patched policy.'
    & $RK rd 2>&1 | Out-Null
    Ok 'Reset issued: device reboots with patched SELinux policy.'
    return $true
}

function Apply-SELinuxFix {
    # Patch /vendor/etc/selinux/precompiled_sepolicy to let untrusted_app open
    # serial_device (so the facetrack app can drive the motors). magiskpolicy
    # runs ON the Mabu (ARM); we pull the result and write it back via Loader.
    param([string] $Dev)
    Section 'SELinux Policy Fix (Motor Access)'
    $sha = (& $ADB -s $Dev shell 'sha256sum /vendor/etc/selinux/precompiled_sepolicy 2>/dev/null' 2>&1) -join ''
    if ($sha -match '03f180a2') { Ok 'SELinux policy already patched (03f180a2): skipping.'; return $true }
    if ($sha -match '7f26df2d') { Info 'Stock policy confirmed (7f26df2d): applying fix.' }
    else { Warn "Unexpected policy SHA: $sha. Proceeding anyway." }

    $mp = Join-Path $RepoRoot 'tools\magiskpolicy\magiskpolicy-armeabi-v7a'
    if (-not (Test-Path $mp)) { Warn 'tools\magiskpolicy\magiskpolicy-armeabi-v7a not found: skipping SELinux fix.'; return $false }

    $origSize = 0
    [int]::TryParse(((& $ADB -s $Dev shell 'stat -c %s /vendor/etc/selinux/precompiled_sepolicy 2>/dev/null' 2>&1) -join '').Trim(), [ref]$origSize) | Out-Null

    & $ADB -s $Dev push $mp /data/local/tmp/magiskpolicy 2>&1 | Out-Null
    & $ADB -s $Dev shell 'chmod 755 /data/local/tmp/magiskpolicy' 2>&1 | Out-Null
    $r = & $ADB -s $Dev shell "cp /vendor/etc/selinux/precompiled_sepolicy /data/local/tmp/sepolicy.in && /data/local/tmp/magiskpolicy --load /data/local/tmp/sepolicy.in --save /data/local/tmp/sepolicy.out 'allow untrusted_app serial_device chr_file { open read write getattr ioctl }' && echo PATCH_OK" 2>&1
    if ($r -notmatch 'PATCH_OK') { Warn "magiskpolicy failed: $($r -join ' '). Skipping."; return $false }
    Ok 'On-device policy patch succeeded.'

    $outFile = Join-Path $scratchDir 'sepolicy.patched'
    Remove-Item $outFile -ErrorAction SilentlyContinue
    & $ADB -s $Dev pull /data/local/tmp/sepolicy.out $outFile 2>&1 | Out-Null
    if (-not (Test-Path $outFile)) { Warn 'Pull of patched policy failed: skipping Loader write.'; return $false }
    $patchedSize = (Get-Item $outFile).Length
    Info "Policy size: original $origSize B, patched $patchedSize B"

    # Only a CONFIRMED size change triggers the WSL reflash. If the size matches
    # (the validated case) OR we couldn't read the original size, use the surgical
    # write; that is exactly what the validated flasher always did.
    if ($origSize -gt 0 -and $patchedSize -ne $origSize) {
        Warn "Patched policy size changed ($origSize -> $patchedSize B): surgical write is unsafe."
        Warn 'Falling back to a full /vendor reflash (needs WSL).'
        return (Invoke-WslVendorReflash -Dev $Dev -PatchedPolicy $outFile)
    }
    if ($origSize -le 0) { Info 'Could not read original policy size: using the validated surgical write.' }
    else                 { Info 'No size change -> surgical in-place write (no WSL needed).' }
    return (Write-PolicySurgical -Dev $Dev -OutFile $outFile)
}

function Run-SelfTest {
    param([string] $Dev)
    Section 'Self-Test'
    $stP = 0; $stF = 0; $stW = 0

    $v = (& $ADB -s $Dev shell 'getprop ro.device_owner' 2>&1) -join ''
    if ($v -match '^\s*$|false') { Ok  '[PASS] No device owner';                        $stP++ } else { Fail "[FAIL] No device owner  (got: $v)"; $stF++ }
    $v = (& $ADB -s $Dev shell 'getprop init.svc.set-device-owner' 2>&1) -join ''
    if ($v -match '^\s*$')       { Ok  '[PASS] init.esper.rc zeroed';                   $stP++ } else { Fail "[FAIL] init.esper.rc zeroed  (got: $v)"; $stF++ }
    $v = (& $ADB -s $Dev shell 'pm path io.shoonya.shoonyadpc 2>/dev/null' 2>&1) -join ''
    if ($v -match '^\s*$')       { Ok  '[PASS] Esper DPC absent from /data';            $stP++ } else { Fail "[FAIL] Esper DPC absent from /data  (got: $v)"; $stF++ }
    $v = (& $ADB -s $Dev shell 'getprop ro.boot.veritymode' 2>&1) -join ''
    if ($v -match 'disabled')    { Ok  '[PASS] dm-verity disabled';                     $stP++ } else { Fail "[FAIL] dm-verity disabled  (got: $v)"; $stF++ }

    if (-not $SkipApps) {
        $v = (& $ADB -s $Dev shell 'pm list packages org.fdroid.fdroid 2>/dev/null' 2>&1) -join ''
        if ($v -match 'package:')    { Ok  '[PASS] F-Droid installed';                  $stP++ } else { Fail '[FAIL] F-Droid installed'; $stF++ }
        $v = (& $ADB -s $Dev shell 'pm list packages app.lawnchair 2>/dev/null' 2>&1) -join ''
        if ($v -match 'package:')    { Ok  '[PASS] Lawnchair installed';                $stP++ } else { Fail '[FAIL] Lawnchair installed'; $stF++ }
        $v = (& $ADB -s $Dev shell 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null' 2>&1) -join ''
        if ($v -match 'lawnchair')   { Ok  '[PASS] Lawnchair is home launcher';         $stP++ } else { Fail "[FAIL] Lawnchair is home launcher  (got: $v)"; $stF++ }
        if (-not $SkipMabu) {
            $v = (& $ADB -s $Dev shell 'pm list packages com.catalia.factorymode 2>/dev/null' 2>&1) -join ''
            if ($v -match 'package:') { Ok  '[PASS] Mabu factory mode installed';       $stP++ } else { Fail '[FAIL] Mabu factory mode installed'; $stF++ }
        }
    }

    $v = (& $ADB -s $Dev shell 'getenforce' 2>&1) -join ''
    if ($v -match 'Enforcing')   { Ok  '[PASS] SELinux enforcing';                      $stP++ } else { Fail "[FAIL] SELinux enforcing  (got: $v)"; $stF++ }
    if (-not $SkipSELinux) {
        $v = (& $ADB -s $Dev shell 'sha256sum /vendor/etc/selinux/precompiled_sepolicy 2>/dev/null' 2>&1) -join ''
        if ($v -match '03f180a2') { Ok  '[PASS] SELinux policy patched (03f180a2)';     $stP++ } else { Fail "[FAIL] SELinux policy patched  (got: $v)"; $stF++ }
    }

    $wlanOut = (& $ADB -s $Dev shell 'ip addr show wlan0 2>/dev/null' 2>&1) -join ' '
    $wlanIp  = ([regex]::Match($wlanOut, 'inet\s+(\d{1,3}(?:\.\d{1,3}){3})')).Groups[1].Value
    if ($wlanIp) {
        $r  = (& $ADB connect "${wlanIp}:5555" 2>&1) -join ''
        $ok = if ($r -match 'connected to|already connected') { (& $ADB -s "${wlanIp}:5555" shell echo ok 2>&1) -join '' } else { '' }
        if ($ok -match 'ok') { Ok "[PASS] Wi-Fi ADB reachable ($wlanIp`:5555)"; $stP++ } else { Warn "[WARN] Wi-Fi ADB unreachable ($wlanIp`:5555): network isolation?"; $stW++ }
    } else { Warn '[WARN] Wi-Fi ADB: no IP on wlan0'; $stW++ }

    Write-Host ''
    $col = if ($stF -gt 0) { 'Red' } elseif ($stW -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host "  Self-test: $stP passed  $stF failed  $stW warnings" -ForegroundColor $col
    if ($stF -gt 0) { Warn 'One or more checks FAILED: review before deploying this unit.' }
    $script:LastSelfTestFails = $stF
}

# ===========================================================================
# Phase 0: (Admin) release USB + purge stale VID_2207 entries
# ===========================================================================
function Invoke-UsbPurge {
    # Release USB and drop every VID_2207 PnP entry so Windows re-enumerates from
    # scratch -- the fix for a bus wedged by repeated Loader cycles, where stale
    # entries stop the fresh device binding correctly.
    #
    # pnputil /remove-device is admin-only, which the elevation gate above already
    # guarantees. No Test-Admin check: that gate exits, so this is only reachable
    # when elevated. (The guard that used to wrap this had an unreachable else
    # branch claiming the phase was "skipped automatically when not run as
    # Administrator" -- it never was.)
    #
    # NOTE: this removes PRESENT devices too, so any live Loader session is
    # dropped and has to be re-caught. Only call it with nothing to lose.
    param([string] $Reason)

    Section 'Release USB + Clear Stale VID_2207 Entries'
    if ($Reason) { Info $Reason }
    $ErrorActionPreference = 'Continue'
    & $ADB kill-server 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
    Start-Sleep -Milliseconds 500
    Get-Process -Name 'rkdeveloptool' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    $stuck = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'Device Descriptor Request Failed' }
    foreach ($d in $stuck) { Info "Removing stuck device: $($d.InstanceId)"; & pnputil /remove-device $d.InstanceId 2>&1 | Out-Null }
    $allRk = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_2207' }
    foreach ($d in $allRk) { Info "Removing: $($d.InstanceId) [Present=$($d.Present)]"; & pnputil /remove-device $d.InstanceId 2>&1 | Out-Null }
    & pnputil /scan-devices 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    $ErrorActionPreference = 'Continue'
    & $ADB start-server 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
    Ok 'USB bus ready.'
}

function Invoke-UsbPurgeRecovery {
    # Auto-recovery for the failure paths that used to abort with "power-cycle and
    # re-run": do the re-enumeration the operator would have done by hand, then let
    # the caller retry. Capped at one attempt per run -- if a clean re-enumeration
    # did not fix it, repeating it will not either, and looping would mask a real
    # hardware or wiring fault.
    param([string] $Reason)
    if ($script:UsbPurgeRecoveryUsed) { return $false }
    $script:UsbPurgeRecoveryUsed = $true
    Warn "$Reason -- attempting an automatic USB re-enumeration before giving up."
    Invoke-UsbPurge -Reason 'Triggered automatically by the failure above.'
    return $true
}

# Opt-in only: a normal flash does not need this, and it drops any Loader session
# already caught. Phase 2 below runs the same purge by itself when the bus looks
# genuinely wedged.
if ($PurgeUsb) {
    Invoke-UsbPurge -Reason 'Requested with -PurgeUsb.'
}

# ===========================================================================
# Phase 1: Prerequisites
# ===========================================================================
Section '1. Prerequisites'
if (-not (Test-Path $RK)) {
    Warn 'rkdeveloptool not found: running install-tools.ps1...'
    & (Join-Path $RepoRoot 'scripts\install-tools.ps1')
    if (-not (Test-Path $RK)) {
        Die 'rkdeveloptool still missing after install-tools.ps1.' `
            'If you downloaded the ZIP, make sure the WHOLE archive was extracted and' `
            'that you are running from the folder containing scripts\, tools\ and firmware\.'
    }
}
if (-not $ADB -or -not (Test-Path $ADB)) {
    if (-not (Test-Winget)) {
        Die 'adb (Android platform-tools) was not found, and winget is unavailable to install it.' `
            'Install platform-tools manually, then re-run:' `
            '  https://developer.android.com/tools/releases/platform-tools' `
            'Unzip it and either add the folder to PATH or place it at:' `
            "  $env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
    }
    Warn 'adb.exe not found: installing Google.PlatformTools via winget...'
    winget install -e --id Google.PlatformTools --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
    $ADB = Find-Adb
    if (-not $ADB -or -not (Test-Path $ADB)) {
        Die 'adb.exe still not found after the winget install.' `
            'Close and reopen PowerShell (so PATH refreshes), then re-run this script.'
    }
    & $ADB start-server 2>&1 | Out-Null
}
$patchDir = Join-Path $RepoRoot 'firmware\patches'
foreach ($f in @('parameter-patched.img','adbd-authreq-patched.bin','adbd-authinit-patched.bin','espersupervisor-apk-eocd-patched.bin','esperdpc-apk-eocd-patched.bin','esperhelper-apk-eocd-patched.bin','zeros-4k.bin')) {
    if (-not (Test-Path (Join-Path $patchDir $f))) { Die "Missing patch payload: firmware\patches\$f" }
}
if (-not $SkipSELinux -and -not (Test-Path (Join-Path $RepoRoot 'tools\magiskpolicy\magiskpolicy-armeabi-v7a'))) {
    Warn 'magiskpolicy binary missing: the SELinux fix will be skipped unless you add it.'
}
Ok 'rkdeveloptool, adb, patch payloads present.'
if (-not (Get-WslUbuntu)) { Info 'WSL/Ubuntu not detected: fine unless the SELinux fix needs the reflash fallback.' }

# ===========================================================================
# Phase 2: Catch / verify Loader, auto-detect Esper state
# ===========================================================================
Section '2. Loader Detection'
$state = 'Unknown'

# If NEITHER a Loader nor any adb device is visible, the bus is very likely wedged
# from earlier Loader cycles. That used to abort with "power-cycle and re-run";
# instead do the re-enumeration the operator would have had to do by hand, once,
# and carry on. Placed BEFORE the branch so whatever comes back -- a Loader or a
# booted adb device -- flows through the normal path with no special-casing.
# Free on the happy path: Test-Loader short-circuits, so the adb probe is skipped
# whenever a Loader is already present.
if (-not (Test-Loader) -and -not (Find-AdbDevice -PreferIp $WifiIp -TimeoutSec 5)) {
    [void](Invoke-UsbPurgeRecovery -Reason 'Neither a Loader nor an adb device is visible')
}

if (Test-Loader) {
    Ok 'Loader already present.'
    Warn 'Device is in Loader (not Android), so the Esper state cannot be probed.'
    Warn 'State -> Unknown. For auto-detect, let the script catch Loader from a booted'
    Warn 'unit instead, or pass -WipeData / -NoWipe explicitly.'
} else {
    Info 'Loader not seen. Finding an adb device to detect state and enter Loader.'
    $dev = Find-AdbDevice -PreferIp $WifiIp -TimeoutSec 30
    if (-not $dev) {
        Die 'No adb device and no Loader, including after an automatic USB re-enumeration.' `
            'Power-cycle the tablet (hold ADKEY through power-on) to catch Loader, then re-run.' `
            'If the PC never sees the device at all, run the read-only USB diagnostic:' `
            '  .\scripts\diagnose-usb.ps1 -Watch'
    }
    $state = Get-MabuState -Dev $dev
    switch ($state) {
        'A'         { Ok   "Detected State A (active Esper DPC in /data) at $dev." }
        'B'         { Ok   "Detected State B (factory-reset Esper) at $dev." }
        'Liberated' { Ok   "Device already liberated at ${dev}: skipping Loader flash." }
        default     { Warn "Could not determine Esper state at $dev (adb may be wedging)." }
    }
    if ($state -ne 'Liberated') {
        $wifiDev = Enable-WifiAdb -UsbDev $dev
        if ($wifiDev) { Ok "Wi-Fi ADB enabled at $wifiDev"; $dev = $wifiDev } else { Warn 'Wi-Fi ADB not established now; inter-phase will retry.' }
        Info 'Rebooting into Loader.'
        & $ADB -s $dev shell reboot loader 2>&1 | Out-Null
        if (-not (Wait-Loader 30)) { Die 'Loader did not appear in 30s.' }
        Ok 'Loader caught.'
    }
}

if ($state -eq 'Liberated') { Info 'Skipping wipe policy, patches, and wipe: device is already liberated.' }

# --- Decide wipe policy: explicit flags win, else auto from detected state ---
if ($state -ne 'Liberated' -and $WipeData -and $NoWipe) { Die 'Pass only one of -WipeData / -NoWipe.' }
if ($state -ne 'Liberated') {
    if     ($WipeData)      { $doWipe = $true;  $wipeWhy = 'forced by -WipeData' }
    elseif ($NoWipe)        { $doWipe = $false; $wipeWhy = 'forced by -NoWipe' }
    elseif ($state -eq 'A') { $doWipe = $true;  $wipeWhy = 'auto: State A (active /data DPC must be wiped)' }
    elseif ($state -eq 'B') { $doWipe = $false; $wipeWhy = 'auto: State B (patches alone suffice)' }
    else                    { $doWipe = $true;  $wipeWhy = 'auto: state undetermined -> safe default = wipe' }
    Section 'Wipe Policy'
    if ($doWipe) { Ok "/data wipe: ON  ($wipeWhy)" } else { Ok "/data wipe: OFF ($wipeWhy)" }

    Confirm-LoaderWinUsb

    # --- Phase 3: Apply patches ---
    Section '3. Applying Liberation Patches'
    & (Join-Path $RepoRoot 'scripts\liberate-mabu.ps1')
    if ($LASTEXITCODE -ne 0) { Die 'liberate-mabu.ps1 failed.' }
    Ok 'All 8 patches written.'

    # --- Phase 4: /data wipe (State A / forced / undetermined) ---
    if ($doWipe) {
        Section 'Resetting Loader between Patch and Wipe Phases'
        Info 'Loader wedges if we do patches + a large write back-to-back. Booting to'
        Info 'Android, then re-entering Loader via adb.'
        & $RK rd 2>&1 | Out-Null
        Start-Sleep -Seconds 4
        $bootDev = Find-AdbDevice -PreferIp $WifiIp -TimeoutSec 120
        if (-not $bootDev) { Die 'No adb after inter-phase reset. Power-cycle and retry.' }
        Ok "adb up at $bootDev"
        & $ADB -s $bootDev shell reboot loader 2>&1 | Out-Null
        if (-not (Wait-Loader 30)) { Die 'Loader not re-caught.' }
        Ok 'Loader re-caught.'

        Section "Wiping head of /data ($WipeMB MB)"
        & $RK ld 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        $wiped = $false
        for ($attempt = 1; $attempt -le 4; $attempt++) {
            & (Join-Path $RepoRoot 'scripts\wipe-data-head.ps1') -SizeMB $WipeMB
            if ($LASTEXITCODE -eq 0) { $wiped = $true; break }
            if (-not (Test-Loader)) { Die "Loader dropped during wipe (attempt $attempt). Power-cycle into Loader and re-run." }
            Warn "Wipe attempt $attempt wedged (cold Loader); warming and retrying..."
            & $RK ld 2>&1 | Out-Null
            Start-Sleep -Seconds 3
        }
        if (-not $wiped) { Die '/data head wipe failed after 4 attempts.' }
        Ok '/data head zeroed; vold will reformat on boot.'
    }

    # --- Reset back to Android ---
    Section 'Resetting Device'
    & $RK rd 2>&1 | Out-Null
    Ok 'Reset issued.'
}

if ($SkipApps) {
    Write-Host ""
    Ok 'Loader-side patches done. -SkipApps requested: no userspace install, no SELinux fix.'
    exit 0
}

# Destructive Loader work is done. Provisioning is best-effort.
$ErrorActionPreference = 'Continue'

# ===========================================================================
# Phase 5: Re-acquire adb over Wi-Fi for provisioning
# ===========================================================================
Section '5. Provisioning Transport (Wi-Fi ADB)'
Info 'Installs run over Wi-Fi ADB on 5555 (USB ADB on this hardware times out too fast).'
if ($doWipe) {
    Warn '/data was wiped: Wi-Fi credentials and the persistent tcpip flag are gone.'
    Warn 'On the tablet touch UI, join your Wi-Fi network, then come back here.'
    Read-Host 'Press Enter once Wi-Fi is associated on the tablet'
}
$acq = Find-AdbDevice -PreferIp $WifiIp -TimeoutSec 180
if (-not $acq) {
    Die 'No adb (USB or Wi-Fi) after reset.' `
        'Re-seat the USB harness (or fix tablet Wi-Fi), then finish with:' `
        '  .\scripts\flash.ps1 -NoWipe'
}
if ($acq -match ':5555$') { $dev = $acq; Ok "Wi-Fi ADB already up: $dev" }
else {
    $dev = Enable-WifiAdb -UsbDev $acq
    if (-not $dev) { Warn 'Wi-Fi ADB unavailable; falling back to USB ADB for installs (may wedge).'; $dev = $acq }
}
Ok "Provisioning over: $dev"

Section 'Post-Boot Audit'
$audit = & $ADB -s $dev shell 'echo DO=$(getprop ro.device_owner); echo SDOSVC=$(getprop init.svc.set-device-owner); pm list packages 2>/dev/null | grep -iE "esper|shoonya" | head -5' 2>&1
$audit | ForEach-Object { Info $_ }

# ===========================================================================
# Phase 6: Install user apps
# ===========================================================================
Section '6. Installing User Apps'
if (-not (Test-Path (Join-Path $RepoRoot $FDroidApk))) { Warn "Missing APK: $FDroidApk. Skipping." }
elseif ((& $ADB -s $dev shell 'pm list packages org.fdroid.fdroid 2>/dev/null' 2>&1) -match 'package:') { Ok 'F-Droid already installed. Skipping.' }
else { $r = (& $ADB -s $dev install (Join-Path $RepoRoot $FDroidApk) 2>&1) | Where-Object { $_ -notmatch 'RemoteException' } | Select-Object -Last 1; Info "$FDroidApk : $r" }

if (-not (Test-Path (Join-Path $RepoRoot $LawnchairApk))) { Warn "Missing APK: $LawnchairApk. Skipping." }
elseif ((& $ADB -s $dev shell 'pm list packages app.lawnchair 2>/dev/null' 2>&1) -match 'package:') { Ok 'Lawnchair already installed. Skipping.' }
else { $r = (& $ADB -s $dev install (Join-Path $RepoRoot $LawnchairApk) 2>&1) | Where-Object { $_ -notmatch 'RemoteException' } | Select-Object -Last 1; Info "$LawnchairApk : $r" }
& $ADB -s $dev shell 'cmd package set-home-activity app.lawnchair/.LawnchairLauncher' 2>&1 | Out-Null
Ok 'Lawnchair set as default launcher.'

# ===========================================================================
# Phase 7: Mabu factory mode + assets
# ===========================================================================
if (-not $SkipMabu) {
    Section '7. Restoring Mabu Factory Mode + Assets'
    $installed = (& $ADB -s $dev shell 'pm list packages | grep -i catalia') 2>&1
    if ($installed -match 'com.catalia.factorymode') { Info 'com.catalia.factorymode already installed: skipping APK install.' }
    else {
        $apk = Join-Path $RepoRoot "$MabuArchive\apks\com.catalia.factorymode.apk"
        if (Test-Path $apk) { $r = (& $ADB -s $dev install $apk 2>&1) | Where-Object { $_ -notmatch 'RemoteException' } | Select-Object -Last 1; Info "factorymode install: $r" }
        else { Warn "Mabu factory APK not found at $apk. Skipping (pass -SkipMabu to silence)." }
    }
    foreach ($p in 'CAMERA','RECORD_AUDIO','READ_PHONE_STATE','READ_EXTERNAL_STORAGE','WRITE_EXTERNAL_STORAGE') {
        & $ADB -s $dev shell pm grant com.catalia.factorymode "android.permission.$p" 2>&1 | Out-Null
    }
    $SD = Join-Path $RepoRoot "$MabuArchive\sdcard\sdcard"
    if (Test-Path $SD) {
        Info 'Pushing animation CSVs + assets...'
        Get-ChildItem "$SD\*.csv" -ErrorAction SilentlyContinue | ForEach-Object { & $ADB -s $dev push $_.FullName /sdcard/ 2>&1 | Out-Null }
        if (Test-Path "$SD\nuance")    { & $ADB -s $dev push "$SD\nuance" /sdcard/ 2>&1 | Out-Null }
        if (Test-Path "$SD\sound.raw") { & $ADB -s $dev push "$SD\sound.raw" /sdcard/ 2>&1 | Out-Null }
        Ok 'Assets pushed.'
    } else { Warn "Mabu archive sdcard dir not found at $SD" }
}

# ===========================================================================
# Phase 8: SELinux motor fix
# ===========================================================================
if (-not $SkipSELinux) {
    $selinuxDev = Find-AdbDevice -PreferIp $WifiIp -TimeoutSec 120
    if (-not $selinuxDev) { $selinuxDev = $dev }
    Apply-SELinuxFix -Dev $selinuxDev | Out-Null
}

# ===========================================================================
# Phase 9: Self-test
# ===========================================================================
Info 'Waiting for device to come up for self-test...'
$script:LastSelfTestFails = $null
$testDev = Find-AdbDevice -PreferIp $WifiIp -TimeoutSec 120
if ($testDev) {
    & $ADB -s $testDev shell 'cmd package set-home-activity app.lawnchair/.LawnchairLauncher' 2>&1 | Out-Null
    Run-SelfTest -Dev $testDev
} else { Warn 'Self-test skipped: no adb device found after reboot.' }

Section 'Done'
Ok "Unit at $dev liberated and provisioned. Verify on-device:"
Info '  - Home screen = Lawnchair (long-press to customize)'
Info '  - F-Droid available for additional apps'
if (-not $SkipMabu)    { Info '  - Mabu Factory Mode launches motor diagnostics' }
if (-not $SkipSELinux) { Info '  - SELinux fix applied: untrusted_app can open serial_device (motors)' }
Info 'Do NOT run motor tests until the operator confirms the hardware is ready and being watched.'

# Reassembly guidance: only when every self-test check passed.
if ($null -ne $script:LastSelfTestFails -and $script:LastSelfTestFails -eq 0) {
    Section 'All Checks Passed: Safe to Reassemble'
    Ok 'The flash is complete and fully validated. You can now:'
    Info '  1. Power OFF the Mabu.'
    Info '  2. Disconnect the USB harness from the internal header.'
    Info '  3. Reassemble the robot.'
} elseif ($null -eq $script:LastSelfTestFails) {
    Warn 'Self-test was skipped: verify the unit manually before powering off and reassembling.'
} else {
    Warn "Self-test had $($script:LastSelfTestFails) failed check(s). Do NOT reassemble yet; review the failures above and re-run the flash."
}

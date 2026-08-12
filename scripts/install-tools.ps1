# install-tools.ps1
#
# Bootstraps the Windows tooling needed to talk to the Mabu's Rockchip
# rockusb gadget (VID 0x2207 / PID 0x0006).
#
# What this does:
#   1. Installs Zadig (used to replace the default Windows driver on the
#      rockusb device with WinUSB, so libusb-based tools can open it).
#   2. Installs rkdeveloptool into tools\rkdeveloptool\.
#   3. Installs adb (Google platform-tools).
#   4. Patches in the Google Android USB driver for the Mabu's VID/PID.
#   5. Verifies whatever is in place.
#
# Every download here is HASH-PINNED: the expected SHA-256 is a literal, the
# bytes are verified after transfer, and a mismatch deletes the file rather than
# using it. The adb/Zadig pins and the download itself live in
# scripts\lib\MabuTools.ps1, shared with both CLI flashers and the GUI core so a
# re-pin lands everywhere at once; rkdeveloptool's manifest is still below.
# Package managers (winget, scoop) are used when present but are never required
# -- plenty of locked-down and older Windows 10 images have neither, and the
# direct pinned download is what keeps those machines working.
#
# What this does NOT do:
#   - Auto-bind WinUSB. Zadig is GUI-driven by design (driver replacement
#     is a security-sensitive operation). The script launches it and tells
#     you exactly which device to pick.
#   - Install winget. Bootstrapping the App Installer MSIX just to fetch two
#     files is more fragile than fetching them directly, and AppX deployment is
#     frequently the thing that is blocked on these images in the first place.
#
# Idempotent: re-running is safe and just verifies state.
#
# Elevation: run this at whatever elevation you like -- no step aborts the run,
# and everything it installs lands in the repo, so it stays visible to the
# elevated flasher even if UAC elevates into a different account. The ONE part
# that genuinely needs Administrator is the Android USB driver install in
# section 5, which hands off to Device Manager; that step says so itself and
# skips cleanly otherwise. Everything else works un-elevated.

[CmdletBinding()]
param(
    # Install WSL2 + Ubuntu. Off by default: WSL is only used by the flasher's
    # rare SELinux /vendor reflash fallback, and installing it costs several
    # minutes plus a full reboot. Opting in keeps the default run fast and keeps
    # it from behaving differently depending on elevation. Needs Administrator.
    [switch]$InstallWsl
)

$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$ToolsDir   = Join-Path $RepoRoot 'tools'
$RkDir      = Join-Path $ToolsDir 'rkdeveloptool'
$RkExe      = Join-Path $RkDir   'rkdeveloptool.exe'

# This script is shared verbatim between the two editions, which ship different
# flasher entry points (flash-mabu.ps1 on main, flash-mabu.ps1 alongside the WPF app).
# Detect which one this copy has so the guidance below names the right command
# without the file itself having to diverge.
$FlashScript = if     (Test-Path (Join-Path $PSScriptRoot 'flash-mabu.ps1')) { '.\scripts\flash-mabu.ps1' }
               elseif (Test-Path (Join-Path $PSScriptRoot 'flash-mabu.ps1'))      { '.\scripts\flash-mabu.ps1' }
               else                                                          { '.\scripts\flash-mabu.ps1' }

function Write-Step($msg)  { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-OK($msg)    { Write-Host "  [OK]   $msg"  -ForegroundColor Green }
function Write-Note($msg)  { Write-Host "  [note] $msg"  -ForegroundColor Yellow }
function Write-Warn($msg)  { Write-Host "  [warn] $msg"  -ForegroundColor DarkYellow }

# Shared tool acquisition: hash-pinned download, the SHA-256 pins themselves,
# and the adb/Zadig locators + installers. Lives in one place so a re-pin lands
# in every entry point at once -- this script, both CLI flashers and the GUI
# core all use it. See scripts\lib\MabuTools.ps1.
. (Join-Path $PSScriptRoot 'lib\MabuTools.ps1')

# Route the module's output through this script's console writers.
Set-MabuToolsLogger {
    param([string] $Level, [string] $Message)
    switch ($Level) {
        'ok'   { Write-OK   $Message }
        'warn' { Write-Warn $Message }
        default { Write-Note $Message }
    }
}

# ---------------------------------------------------------------------------
# 1. Zadig
# ---------------------------------------------------------------------------
Write-Step 'Zadig'

# Acquisition lives in scripts\lib\MabuTools.ps1: already-installed, then winget,
# then the pinned direct download. The direct download is the path that matters --
# on locked-down and older Windows 10 images there is no winget, and this script
# used to give up here, leaving the machine unable to flash at all.
# (An existing scoop install is still detected; auto-installing VIA scoop was
# dropped, since the pinned download supersedes it and works everywhere.)
$zadig = Install-MabuZadig -RepoRoot $RepoRoot
if ($zadig) {
    Write-OK "Zadig ready: $zadig"
} else {
    Write-Warn 'Could not obtain Zadig.'
    Write-Note 'Manual install: download from https://zadig.akeo.ie/ (single .exe, no installer needed).'
    Write-Note "Place at: $(Join-Path $ToolsDir 'zadig.exe')  -or-  anywhere on PATH."
}

# ---------------------------------------------------------------------------
# 2. rkdeveloptool (hash-pinned download from cpebit/rkdeveloptool-bin)
# ---------------------------------------------------------------------------
# Source pinned to a specific commit so the bytes we download match what
# was reviewed when this script was authored. Hashes below are computed
# from that commit. Re-run with -RefreshRkdev to upgrade the pin (you'll
# need to manually update $RkdevManifest below to match the new SHA256s).
Write-Step 'rkdeveloptool (hash-pinned download)'

$RkdevRepo   = 'cpebit/rkdeveloptool-bin'
$RkdevCommit = 'c23f0f5d04f329a1d40b42537983565698a02865'
$RkdevManifest = @(
    @{ Name='rkdeveloptool.exe'; Sha256='995a7409171fd1c08c3f32d802918c719433ccac328ddb7c7668d4f9cef26396' },
    @{ Name='libusb-1.0.dll';    Sha256='d40c48048854b89b245e65c8116d95d93770fa9b9b9fb6c4ad4051dee75a719c' },
    @{ Name='msvcp140.dll';      Sha256='6ff049b5ead1d723f64f6a3e54eb4d9a47d3c3a289d44800c6b19357e664cc78' },
    @{ Name='vcruntime140.dll';  Sha256='833c31c5310de499d791e94d686d101eac8cc04240071de2b9d0ca37892c3f72' }
)

if (-not (Test-Path $RkDir)) { New-Item -ItemType Directory -Path $RkDir -Force | Out-Null }

# Provenance README, regenerated each run.
$readmePath = Join-Path $RkDir 'README.md'
@"
# rkdeveloptool (auto-managed by scripts\install-tools.ps1)

Source:  https://github.com/$RkdevRepo
Pin:     $RkdevCommit
Files:   rkdeveloptool.exe, libusb-1.0.dll, msvcp140.dll, vcruntime140.dll
Hashes:  see `$RkdevManifest in scripts\install-tools.ps1

This is a third-party Windows build of upstream
https://github.com/rockchip-linux/rkdeveloptool. The pin is fixed in
the install script; bytes are verified against the embedded SHA-256
manifest after download. To upgrade the pin, change `$RkdevCommit and
the corresponding hashes in scripts\install-tools.ps1.

To rebuild from source instead, see option (A) in the project README.
"@ | Set-Content -Path $readmePath -Encoding UTF8

# Download each file (skip if already present with matching hash).
foreach ($entry in $RkdevManifest) {
    $local = Join-Path $RkDir $entry.Name
    $needs = $true
    if (Test-Path $local) {
        $existing = (Get-FileHash -Algorithm SHA256 -Path $local).Hash.ToLower()
        if ($existing -eq $entry.Sha256) {
            Write-OK "$($entry.Name) already present (sha256 verified)"
            $needs = $false
        } else {
            Write-Note "$($entry.Name) hash mismatch ($existing != $($entry.Sha256)); re-downloading"
        }
    }
    if ($needs) {
        $url = "https://raw.githubusercontent.com/$RkdevRepo/$RkdevCommit/bin/$($entry.Name)"
        Write-Note "Downloading $url"
        try {
            Invoke-WebRequest -Uri $url -OutFile $local -UseBasicParsing
        } catch {
            Write-Warn "Download failed: $_"
            continue
        }
        $got = (Get-FileHash -Algorithm SHA256 -Path $local).Hash.ToLower()
        if ($got -ne $entry.Sha256) {
            Remove-Item $local -Force
            Write-Warn "$($entry.Name) hash mismatch after download. Expected $($entry.Sha256), got $got. Deleted file."
        } else {
            Write-OK "$($entry.Name) downloaded and verified"
        }
    }
}

if (Test-Path $RkExe) {
    Write-OK "rkdeveloptool.exe in place at $RkExe"
} else {
    Write-Warn "rkdeveloptool.exe is missing. Check the download errors above."
}

# ---------------------------------------------------------------------------
# 3. adb (Android platform-tools)
# ---------------------------------------------------------------------------
# The flasher drives the whole provisioning phase over adb, so this is a hard
# requirement -- it used to be missing here entirely, and the flash script would
# die at startup on a fresh PC with an unguarded WinGet-path lookup.
Write-Step 'adb (Android platform-tools)'

# Acquisition lives in scripts\lib\MabuTools.ps1: already-installed, then winget,
# then the pinned direct download of Google's VERSIONED (immutable) archive.
# It unpacks to <repo>	ools\platform-tools\ -- deliberately repo-relative, not
# %LOCALAPPDATA%: this script needs no elevation but every flasher does, and if
# the signed-in user is not a local admin then UAC elevates into a different
# account with a different %LOCALAPPDATA%, where the adb we just installed would
# be invisible.
$adbPath = Install-MabuAdb -RepoRoot $RepoRoot
$AdbOk   = [bool]$adbPath
if ($AdbOk) {
    Write-OK "adb ready: $adbPath"
} else {
    Write-Warn 'Could not obtain adb.'
    Write-Note 'Download platform-tools manually and add it to PATH:'
    Write-Note '  https://developer.android.com/tools/releases/platform-tools'
    Write-Note "Or unzip it to: $(Join-Path $ToolsDir 'platform-tools')"
}

# ---------------------------------------------------------------------------
# 4. WSL2 + Ubuntu (SELinux reflash fallback only)
# ---------------------------------------------------------------------------
# The flasher's SELinux motor fix runs on-device magiskpolicy by default and
# never touches WSL. WSL2 + Ubuntu is ONLY needed for the automatic fallback that
# fires if the patched policy changes size (Invoke-WslVendorReflash): it loop-
# mounts a /vendor dump to swap the policy file in, then reflashes the whole
# partition. That's a rare path -- the common motor-only patch is a validated
# same-size bit-flip -- so this whole section is ADVISORY: it reports what it
# finds, never installs anything unless asked with -InstallWsl, and is not
# allowed to abort the run. Everything is wrapped accordingly.
# Note: this does NOT build sepolicy-inject; that was a dependency of the old,
# removed flash-new-mabu.ps1 and nothing here uses it.
Write-Step 'WSL2 + Ubuntu (SELinux reflash fallback)'

function Get-WslExe {
    # Get-Command is not sufficient on its own. On Windows 10 images where the
    # "Windows Subsystem for Linux" optional feature was never enabled there is
    # no wsl.exe at all -- and calling a bare `wsl` under
    # ErrorActionPreference=Stop throws CommandNotFoundException, which used to
    # abort this entire script partway through (taking the Android driver step,
    # the device check and the summary with it). Resolve the real binary first
    # and only ever invoke it through this path.
    $sys = Join-Path $env:WINDIR 'System32\wsl.exe'
    if (Test-Path -LiteralPath $sys) { return $sys }
    $cmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-WslDistros($wslExe) {
    # `wsl --list` emits UTF-16LE. PowerShell 5.1 decodes it as ANSI unless the
    # console encoding is switched first, which turns "Ubuntu" into "U.b.u.n.t.u"
    # and made machines that DO have Ubuntu report as having none. Switch the
    # encoding, capture, restore. Null-strip covers the older builds too.
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.Encoding]::Unicode
        $raw = & $wslExe --list --quiet 2>$null
    } catch {
        return @()
    } finally {
        [Console]::OutputEncoding = $prev
    }
    if (-not $raw) { return @() }
    return @($raw | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
}

$WslOk = $false
try {
    $wslExe = Get-WslExe
    if (-not $wslExe) {
        Write-Warn 'WSL is not installed on this PC. This is optional -- continuing.'
        Write-Note 'A normal flash never uses WSL. It only matters if the SELinux motor patch'
        Write-Note 'changes size, which is the rare case that triggers the /vendor reflash fallback.'
        Write-Note 'To add it later, from an Administrator PowerShell:  wsl --install Ubuntu'
        Write-Note 'If that command does not exist, enable the feature first, then restart:'
        Write-Note '  dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart'
    } else {
        $ubuntu = Get-WslDistros $wslExe | Where-Object { $_ -match 'Ubuntu' } | Select-Object -First 1
        if ($ubuntu) {
            Write-OK "WSL Ubuntu distro present: $ubuntu"
            $WslOk = $true
        } elseif ($InstallWsl) {
            # Opt-in only: this takes several minutes and needs a reboot before the
            # distro is usable, so it can never finish in the same pass.
            $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $isAdmin) {
                Write-Warn '-InstallWsl needs Administrator. Re-run from an Administrator PowerShell (right-click Start > Terminal (Admin)).'
            } else {
                Write-Note 'Installing WSL + Ubuntu (this can take several minutes)...'
                & $wslExe --install Ubuntu
                if ($LASTEXITCODE -ne 0) {
                    Write-Warn "wsl --install exited $LASTEXITCODE. Install it by hand:  wsl --install Ubuntu"
                } else {
                    Write-Warn 'WSL + Ubuntu install started. RESTART the PC, let Ubuntu finish its first-time setup (username/password prompt), then re-run this script.'
                }
            }
        } else {
            Write-Warn 'WSL is present but has no Ubuntu distro. This is optional -- continuing.'
            Write-Note 'Add it with:  .\scripts\install-tools.ps1 -InstallWsl   (Administrator; several minutes + a restart)'
            Write-Note 'or by hand:   wsl --install Ubuntu'
        }
    }
} catch {
    # Belt and braces. Nothing about an optional fallback justifies killing the
    # run, so any surprise in here degrades to a warning.
    Write-Warn "WSL check failed: $($_.Exception.Message)"
    Write-Note 'Skipping -- WSL is optional and a normal flash does not use it.'
}

# ---------------------------------------------------------------------------
# 5. Android USB driver (VID 0x2207 / PID 0x0006 -> ADB after liberation)
# ---------------------------------------------------------------------------
Write-Step 'Android ADB driver (PID 0x0006)'
& (Join-Path $PSScriptRoot 'install-android-driver.ps1')

# ---------------------------------------------------------------------------
# 6. Device check
# ---------------------------------------------------------------------------
Write-Step 'Device state'

$rk = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_2207' }
if (-not $rk) {
    Write-Warn 'No Rockchip device (VID 0x2207) currently enumerated.'
    Write-Note 'Plug the Mabu USB header in and re-run.'
} else {
    foreach ($d in $rk) {
        Write-OK "$($d.FriendlyName)  -  $($d.InstanceId)  -  Status: $($d.Status)  -  Class: $($d.Class)"

        # If it's still bound to a Microsoft USB driver (Class=USBDevice/USB), Zadig hasn't run yet.
        if ($d.Class -in @('USB','USBDevice','Unknown') -or -not $d.Class) {
            Write-Note 'Driver looks like the default Windows USB stack - libusb-based tools will fail to open the device.'
            Write-Note "$FlashScript will launch Zadig and walk you through this automatically."
        } elseif ($d.Class -eq 'libusb-win32 devices' -or $d.Class -match 'WinUSB') {
            Write-OK 'Driver looks like a libusb/WinUSB binding - rkdeveloptool should be able to open it.'
        } else {
            Write-Note "Driver class is '$($d.Class)' - not sure if libusb can open this; try rkdeveloptool ld and see."
        }
    }
}

Write-Step 'Next step'
if (-not $zadig) {
    Write-Host '  Install Zadig (see notes above).' -ForegroundColor White
} elseif (-not (Test-Path $RkExe)) {
    Write-Host '  rkdeveloptool.exe missing - check download errors above and re-run.' -ForegroundColor White
} elseif (-not $AdbOk) {
    Write-Host '  Install adb (see notes above), then re-run.' -ForegroundColor White
} else {
    Write-Host '  All tools ready. To flash a Mabu:' -ForegroundColor Green
    Write-Host '  1. Connect the USB harness and power the unit on.' -ForegroundColor White
    Write-Host '     (Hold ADKEY through power-on to catch Loader; or just let Android boot -' -ForegroundColor White
    Write-Host '      the script enters Loader itself.)' -ForegroundColor White
    Write-Host '  2. From the repo root, in an Administrator PowerShell, run:' -ForegroundColor White
    Write-Host "       $FlashScript" -ForegroundColor Cyan
    Write-Host '' -ForegroundColor White
    Write-Host '  That single command does everything: liberation, wipe (only if needed),' -ForegroundColor White
    Write-Host '  app install, SELinux patch, and a self-test. It will launch Zadig on its' -ForegroundColor White
    Write-Host '  own the first time, to bind the Loader driver.' -ForegroundColor White
    Write-Host '  Reference: FLASH-A-NEW-MABU.md' -ForegroundColor White
    if (-not $WslOk) {
        Write-Host '' -ForegroundColor White
        Write-Note 'WSL/Ubuntu is not set up. A normal flash does not need it -- it only matters'
        Write-Note 'if the SELinux motor patch happens to change size, which is rare. Set it up'
        Write-Note 'with  .\scripts\install-tools.ps1 -InstallWsl  if you ever see'
        Write-Note '"SELinux fallback: full /vendor reflash" fail.'
    }
}

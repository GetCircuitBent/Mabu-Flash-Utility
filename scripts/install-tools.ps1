# install-tools.ps1
#
# Bootstraps the Windows tooling needed to talk to the Mabu's Rockchip
# rockusb gadget (VID 0x2207 / PID 0x0006).
#
# What this does:
#   1. Installs Zadig (used to replace the default Windows driver on the
#      rockusb device with WinUSB, so libusb-based tools can open it).
#   2. Sets up tools\rkdeveloptool\ as a drop-in location for the
#      rkdeveloptool CLI binary (manual download - see notes below).
#   3. Verifies whatever is in place.
#
# What this does NOT do:
#   - Auto-download rkdeveloptool. There is no canonical pre-built Windows
#     binary URL I trust to hardcode (upstream is Linux-source-only;
#     Windows builds come from various forks of varying quality).
#     The script tells you where to drop the binary and verifies it.
#   - Auto-bind WinUSB. Zadig is GUI-driven by design (driver replacement
#     is a security-sensitive operation). The script launches it and tells
#     you exactly which device to pick.
#
# Idempotent: re-running is safe and just verifies state.

$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$ToolsDir   = Join-Path $RepoRoot 'tools'
$RkDir      = Join-Path $ToolsDir 'rkdeveloptool'
$RkExe      = Join-Path $RkDir   'rkdeveloptool.exe'

function Write-Step($msg)  { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-OK($msg)    { Write-Host "  [OK]   $msg"  -ForegroundColor Green }
function Write-Note($msg)  { Write-Host "  [note] $msg"  -ForegroundColor Yellow }
function Write-Warn($msg)  { Write-Host "  [warn] $msg"  -ForegroundColor DarkYellow }

# ---------------------------------------------------------------------------
# 1. Zadig
# ---------------------------------------------------------------------------
Write-Step 'Zadig'

function Get-ZadigPath {
    # Try common install locations from the package managers below first.
    $candidates = @(
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

$zadig = Get-ZadigPath
if ($zadig) {
    Write-OK "Zadig already installed: $zadig"
} else {
    $installed = $false

    # Prefer winget if available.
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Note 'Installing Zadig via winget...'
        $p = Start-Process winget `
            -ArgumentList 'install','--id','akeo.ie.Zadig','-e','--accept-source-agreements','--accept-package-agreements' `
            -NoNewWindow -Wait -PassThru
        if ($p.ExitCode -eq 0) {
            $installed = $true
        } else {
            Write-Warn "winget exit code $($p.ExitCode); will try fallback."
        }
    }

    # Fallback: scoop.
    if (-not $installed -and (Get-Command scoop -ErrorAction SilentlyContinue)) {
        Write-Note 'Installing Zadig via scoop (extras bucket)...'
        try {
            scoop bucket add extras 2>$null | Out-Null
            scoop install zadig
            $installed = $true
        } catch {
            Write-Warn "scoop install failed: $_"
        }
    }

    if ($installed) {
        $zadig = Get-ZadigPath
        if ($zadig) { Write-OK "Zadig installed: $zadig" }
    } else {
        Write-Warn 'Could not auto-install Zadig.'
        Write-Note 'Manual install: download from https://zadig.akeo.ie/ (single .exe, no installer needed).'
        Write-Note "Place at: $RkDir\..\zadig.exe  -or-  anywhere on PATH."
    }
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
# 3. WSL sepolicy-inject (needed for Phase A/B of the flash guide)
# ---------------------------------------------------------------------------
Write-Step 'WSL: sepolicy-inject'

$SepolicyC   = Join-Path $RepoRoot 'tools\sepolicy-inject.c'
$SepolicyBin = '/usr/local/bin/sepolicy-inject'
$WslOk       = $false

# Auto-install WSL2 + Ubuntu. Needs Administrator and a reboot before the
# distro is usable, so this kicks off the install and tells the user to
# restart and re-run — it cannot finish sepolicy-inject in the same pass.
function Install-WslUbuntu {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Warn 'Installing WSL needs Administrator. Re-run this script from an Administrator PowerShell (right-click Start > Terminal (Admin)).'
        Write-Note 'Or install it yourself:  wsl --install Ubuntu   (then restart the PC).'
        return
    }
    Write-Note 'Installing WSL + Ubuntu (this can take several minutes)...'
    wsl --install Ubuntu
    Write-Warn 'WSL + Ubuntu install started. RESTART the PC now, let Ubuntu finish its first-time setup (it will ask you to create a username/password), then re-run:  .\scripts\install-tools.ps1'
}

$wslCheck = Get-Command wsl -ErrorAction SilentlyContinue
if (-not $wslCheck) {
    Write-Warn 'WSL not found.'
    Install-WslUbuntu
} else {
    # Detect a runnable Ubuntu distro
    $distros = wsl --list --quiet 2>$null
    $ubuntu  = $distros | Where-Object { $_ -match 'Ubuntu' } | Select-Object -First 1
    if (-not $ubuntu) {
        Write-Warn 'No Ubuntu WSL distro found.'
        Install-WslUbuntu
    } else {
        $ubuntu = $ubuntu.Trim()
        Write-Note "Using WSL distro: $ubuntu"

        # Check if already built
        $existing = wsl -d $ubuntu -- test -x $SepolicyBin '&&' echo yes 2>$null
        if ($existing -match 'yes') {
            Write-OK "sepolicy-inject already at $SepolicyBin"
            $WslOk = $true
        } else {
            Write-Note 'Building sepolicy-inject in WSL...'
            # Install build deps (run as root to avoid sudo password prompt)
            $apt = wsl -d $ubuntu -u root -- apt-get install -y libsepol-dev build-essential setools 2>&1 | Select-Object -Last 3
            $apt | ForEach-Object { Write-Note $_ }

            # Compile — source is in tools/sepolicy-inject.c (accessible from WSL as /mnt/c/...)
            $wsrc = ($SepolicyC -replace '\\','/') -replace '^([A-Za-z]):',{ '/mnt/' + $args[0].Value.ToLower() }
            $compile = wsl -d $ubuntu -u root -- gcc -o $SepolicyBin $wsrc /usr/lib/x86_64-linux-gnu/libsepol.a 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-OK "sepolicy-inject compiled and installed at $SepolicyBin"
                $WslOk = $true
            } else {
                Write-Warn "Compile failed: $compile"
                Write-Note "Manual fix: in WSL run: gcc -o $SepolicyBin '<path-to-tools/sepolicy-inject.c>' /usr/lib/x86_64-linux-gnu/libsepol.a"
            }
        }

        # Verify sesearch (used in Phase A3 verification)
        $ss = wsl -d $ubuntu -- sesearch --version 2>$null
        if ($ss -match '\d') {
            Write-OK "sesearch $($ss.Trim()) available"
        } else {
            Write-Warn "sesearch not found — run: wsl -d $ubuntu -u root -- apt-get install -y setools"
        }
    }
}

# ---------------------------------------------------------------------------
# 4. adb (Android platform-tools)
# ---------------------------------------------------------------------------
# flash.ps1 / MabuFlashCore.ps1 drive the whole provisioning phase over adb, so
# this is a hard requirement. It was missing from this script entirely -- adb
# had to already be on the machine some other way, or the flash script died at
# startup with an unguarded WinGet-path lookup.
Write-Step 'adb (Android platform-tools)'

function Get-AdbPath {
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

$AdbOk   = $false
$adbPath = Get-AdbPath
if ($adbPath) {
    Write-OK "adb already installed: $adbPath"
    $AdbOk = $true
} elseif (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Note 'Installing Google platform-tools via winget...'
    $p = Start-Process winget `
        -ArgumentList 'install','--id','Google.PlatformTools','-e','--accept-source-agreements','--accept-package-agreements' `
        -NoNewWindow -Wait -PassThru
    $adbPath = Get-AdbPath
    if ($adbPath) {
        Write-OK "adb installed: $adbPath"
        $AdbOk = $true
    } else {
        Write-Warn "winget finished (exit $($p.ExitCode)) but adb was not found. Reopen PowerShell so PATH refreshes, then re-run."
    }
} else {
    Write-Warn 'adb not found and winget is unavailable on this machine.'
    Write-Note 'Download platform-tools manually and add it to PATH:'
    Write-Note '  https://developer.android.com/tools/releases/platform-tools'
    Write-Note "Or unzip it to: $env:LOCALAPPDATA\Android\Sdk\platform-tools\"
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
            Write-Note 'Run Zadig and replace the driver for this device with WinUSB. See scripts\bind-winusb.ps1.'
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
} elseif (-not $WslOk) {
    Write-Host '  Fix WSL / sepolicy-inject issues above, then re-run.' -ForegroundColor White
    Write-Note 'This only blocks the SELinux-patch reflash fallback (spilled policy size);'
    Write-Note 'a normal flash usually does not need it.'
} else {
    Write-Host '  All tools ready. To flash a Mabu:' -ForegroundColor Green
    Write-Host '  1. Connect the USB harness and power the unit on.' -ForegroundColor White
    Write-Host '     (Hold ADKEY through power-on to catch Loader; or just let Android boot -' -ForegroundColor White
    Write-Host '      flash.ps1 enters Loader itself.)' -ForegroundColor White
    Write-Host '  2. From the repo root, in an Administrator PowerShell, run:' -ForegroundColor White
    Write-Host '       .\scripts\flash.ps1' -ForegroundColor Cyan
    Write-Host '' -ForegroundColor White
    Write-Host '  That single command does everything: liberation, wipe (only if needed),' -ForegroundColor White
    Write-Host '  app install, SELinux patch, and a self-test. It will launch Zadig on its' -ForegroundColor White
    Write-Host '  own the first time, to bind the Loader driver.' -ForegroundColor White
}

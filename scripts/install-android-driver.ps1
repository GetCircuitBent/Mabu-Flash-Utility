# install-android-driver.ps1
#
# Sets up the Google Android USB driver to recognize the Mabu's
# rockchip-VID device (VID 0x2207 / PID 0x0006) as an Android ADB
# device. After this runs and the driver is installed via Device
# Manager, `adb devices` will see the tablet.
#
# What this does:
#   1. Downloads usb_driver_r13-windows.zip from dl.google.com
#      (hash-pinned: 360b01d3dfb6c41621a3a64ae570dfac2c9a40cca1b5a1f136ae90d02f5e9e0b)
#   2. Extracts to tools\google-usb-driver\ (gitignored).
#   3. Patches android_winusb.inf to add VID_2207&PID_0006 to both the
#      x86 and amd64 sections. Removes the catalog signature reference
#      since editing the INF invalidates it.
#   4. Prints exact Device Manager click-through to install.
#
# What this does NOT do:
#   - Auto-install the driver. Modified Google INF won't pass code
#     signing checks via pnputil; Device Manager UI lets you click
#     through the warning, which is the expected workflow.
#   - Remove the existing Zadig WinUSB binding. The Device Manager
#     install step does that implicitly when it replaces the driver.
#
# Idempotent: re-running re-verifies the download and patch.

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ToolsDir = Join-Path $RepoRoot 'tools'
$DriverSrc = Join-Path $ToolsDir 'google-usb-driver-source.zip'
$DriverDir = Join-Path $ToolsDir 'google-usb-driver'

$DriverUrl    = 'https://dl.google.com/android/repository/usb_driver_r13-windows.zip'
$DriverSha256 = '360b01d3dfb6c41621a3a64ae570dfac2c9a40cca1b5a1f136ae90d02f5e9e0b'

$TargetVid = '2207'
$TargetPid = '0006'

function Write-Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-OK($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Note($m) { Write-Host "  [note] $m" -ForegroundColor Yellow }
function Write-Warn($m) { Write-Host "  [warn] $m" -ForegroundColor DarkYellow }

# ---------------------------------------------------------------------------
# 1. Download
# ---------------------------------------------------------------------------
Write-Step 'Download Google Android USB driver'

if (-not (Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null }

$needsDownload = $true
if (Test-Path $DriverSrc) {
    $existing = (Get-FileHash -Algorithm SHA256 -Path $DriverSrc).Hash.ToLower()
    if ($existing -eq $DriverSha256) {
        Write-OK "ZIP already present and verified ($DriverSrc)"
        $needsDownload = $false
    } else {
        Write-Note "ZIP hash mismatch ($existing != $DriverSha256); re-downloading"
    }
}
if ($needsDownload) {
    Write-Note "Downloading $DriverUrl ..."
    Invoke-WebRequest -Uri $DriverUrl -OutFile $DriverSrc -UseBasicParsing
    $got = (Get-FileHash -Algorithm SHA256 -Path $DriverSrc).Hash.ToLower()
    if ($got -ne $DriverSha256) {
        Remove-Item $DriverSrc -Force
        throw "Downloaded file hash mismatch. Expected $DriverSha256, got $got."
    }
    Write-OK 'Downloaded and verified.'
}

# ---------------------------------------------------------------------------
# 2. Extract
# ---------------------------------------------------------------------------
Write-Step 'Extract'

if (Test-Path $DriverDir) { Remove-Item $DriverDir -Recurse -Force }
New-Item -ItemType Directory -Path $DriverDir -Force | Out-Null

# The zip contains a top-level usb_driver\ folder; flatten it.
$staging = Join-Path $env:TEMP "google-usb-driver-extract-$([guid]::NewGuid().ToString('N'))"
Expand-Archive -Path $DriverSrc -DestinationPath $staging -Force
$inner = Join-Path $staging 'usb_driver'
Get-ChildItem $inner | Move-Item -Destination $DriverDir
Remove-Item $staging -Recurse -Force
Write-OK "Extracted to $DriverDir"

# ---------------------------------------------------------------------------
# 3. Patch the INF
# ---------------------------------------------------------------------------
Write-Step "Patch android_winusb.inf for VID_${TargetVid}&PID_${TargetPid}"

$infPath = Join-Path $DriverDir 'android_winusb.inf'
if (-not (Test-Path $infPath)) { throw "android_winusb.inf not found at $infPath" }

$content = Get-Content -Path $infPath -Raw

$marker = "Mabu (VID_${TargetVid}&PID_${TargetPid})"
$patch = @"

;$marker - added by scripts\install-android-driver.ps1
%SingleAdbInterface%        = USB_Install, USB\VID_${TargetVid}&PID_${TargetPid}
%CompositeAdbInterface%     = USB_Install, USB\VID_${TargetVid}&PID_${TargetPid}&MI_01

"@

if ($content -match [regex]::Escape($marker)) {
    Write-OK 'INF already contains the Mabu entry.'
} else {
    # Insert after each [Google.NTx86] and [Google.NTamd64] section header.
    $patched = $content -replace '(?m)(^\[Google\.NTx86\]\s*$)',   "`$1$patch"
    $patched = $patched -replace '(?m)(^\[Google\.NTamd64\]\s*$)', "`$1$patch"
    if ($patched -eq $content) {
        throw 'Could not find [Google.NTx86] or [Google.NTamd64] section headers; INF format may have changed.'
    }
    [System.IO.File]::WriteAllText($infPath, $patched)
    Write-OK 'Inserted Mabu entries into x86 and amd64 sections.'
}

# Strip catalog references - editing the INF invalidates the catalog signature.
# Without these lines, Windows treats it as an unsigned third-party driver and
# shows the standard "this driver is not signed" dialog the user can accept.
$content2 = Get-Content -Path $infPath -Raw
$catalogLines = ($content2 -split "`r?`n" | Where-Object { $_ -match '^\s*CatalogFile' }).Count
if ($catalogLines -gt 0) {
    $stripped = ($content2 -split "`r?`n" | Where-Object { $_ -notmatch '^\s*CatalogFile' }) -join "`r`n"
    [System.IO.File]::WriteAllText($infPath, $stripped)
    Write-OK "Removed $catalogLines CatalogFile reference(s) (signature is broken anyway after the edit)."
}

# Also delete the .cat files - they'd just sit there confusing things.
Get-ChildItem -Path $DriverDir -Filter '*.cat' -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item $_.FullName -Force
    Write-OK "Removed $($_.Name)"
}

# ---------------------------------------------------------------------------
# 4. Verify patch
# ---------------------------------------------------------------------------
Write-Step 'Verify'

$final = Get-Content -Path $infPath -Raw
$mabuMatches = ([regex]::Matches($final, [regex]::Escape("VID_${TargetVid}&PID_${TargetPid}"))).Count
if ($mabuMatches -lt 2) {
    Write-Warn "Expected at least 2 occurrences of VID_${TargetVid}&PID_${TargetPid} (one per section), found $mabuMatches."
} else {
    Write-OK "INF references VID_${TargetVid}&PID_${TargetPid} $mabuMatches times (one per section, plus any &MI_xx variants)."
}

# Check current device state
$dev = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match "VID_${TargetVid}&PID_${TargetPid}" }
if ($dev) {
    Write-OK "Device present: $($dev.FriendlyName) [$($dev.InstanceId)]"
    $svc = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue).Data
    Write-Note "Currently bound to driver service: $svc (will be replaced when you install the patched driver)"
} else {
    Write-Warn 'Device not currently enumerated. Plug it in before doing the Device Manager install.'
}

# ---------------------------------------------------------------------------
# 5. Install instructions
# ---------------------------------------------------------------------------
Write-Step 'Install via Device Manager'
Write-Host ''
Write-Host '  Patched driver is ready at:' -ForegroundColor White
Write-Host "    $DriverDir" -ForegroundColor Cyan
Write-Host ''

# Everything above this point -- download, extract, INF patch -- works fine
# un-elevated. Installing the driver does not: Windows requires Administrator to
# replace a device driver, and this INF is deliberately unsigned (patching it
# invalidates the catalog). Say so plainly rather than letting the user walk the
# nine steps below and hit a read-only Device Manager at step 3.
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Warn 'Not running as Administrator -- the driver install itself will not go through.'
    Write-Note 'The download, extract and INF patch above are done and will be reused.'
    Write-Note 'To finish, re-run this from an Administrator PowerShell (right-click Start >'
    Write-Note 'Terminal (Admin)), or open Device Manager elevated and follow the steps below.'
    Write-Host ''
}

Write-Host '  Steps:' -ForegroundColor White
Write-Host '    1. Open Device Manager (devmgmt.msc).'
Write-Host '    2. Find "H7R" under "Universal Serial Bus devices" (currently bound to WinUSB by Zadig).'
Write-Host '    3. Right-click -> Update driver.'
Write-Host '    4. "Browse my computer for drivers".'
Write-Host '    5. "Let me pick from a list of available drivers on my computer".'
Write-Host '    6. Click "Have Disk..." -> Browse -> select android_winusb.inf in the path above.'
Write-Host '    7. Pick "Android ADB Interface".'
Write-Host '    8. Windows will warn the driver is not signed - click "Install this driver software anyway".'
Write-Host '    9. After install completes, run: adb devices'
Write-Host ''
Write-Host '  Expected result: an entry like'
Write-Host '    2022010502079   device' -ForegroundColor Green
Write-Host '  or possibly' -ForegroundColor White
Write-Host '    2022010502079   unauthorized' -ForegroundColor Yellow
Write-Host '  (if unauthorized, accept the host RSA key prompt on the tablet itself).'
Write-Host ''

# Offer to open Device Manager. Tolerate non-interactive sessions.
# Only offered when elevated: devmgmt.msc launched from a non-elevated shell
# inherits that token and cannot install a driver, so opening it would just walk
# the user into a dead end.
if (-not $IsAdmin) {
    Write-Note 'Skipping the Device Manager launch (needs Administrator, see above).'
} else {
    try {
        $open = Read-Host 'Open Device Manager now? [Y/n]'
        if ($open -notmatch '^[nN]') {
            Start-Process devmgmt.msc
        }
    } catch {
        Write-Note 'Non-interactive session - skipping Device Manager launch.'
        Write-Note 'Run "devmgmt.msc" yourself when ready.'
    }
}

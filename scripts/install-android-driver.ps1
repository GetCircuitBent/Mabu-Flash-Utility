# install-android-driver.ps1
#
# Sets up the Google Android USB driver to recognize the Mabu's
# rockchip-VID device (VID 0x2207) as an Android ADB device. After this
# runs and the driver is installed via Device Manager, `adb devices`
# will see the tablet.
#
# What this does:
#   1. Downloads usb_driver_r13-windows.zip from dl.google.com
#      (hash-pinned: 360b01d3dfb6c41621a3a64ae570dfac2c9a40cca1b5a1f136ae90d02f5e9e0b)
#   2. Extracts to tools\google-usb-driver\ (gitignored).
#   3. Patches android_winusb.inf to add every VID_2207 ADB PID the Mabu
#      can enumerate under, to both the x86 and amd64 sections. Removes
#      the catalog signature reference since editing the INF invalidates it.
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

# The Mabu does not always come up on the same PID -- it depends on which USB
# gadget config Android brings up:
#   0006              single ADB function      (liberated / Esper main image)
#   0010..0015 &MI_xx  MTP+ADB composite       (stock -- an H7R reports 0011)
# Patching only 0006 is why a composite unit dead-ends in Device Manager with
# "The folder you specified doesn't contain a compatible software driver for
# your device": the INF has no line matching that hardware ID, so Have Disk
# rejects the whole folder. Cover the range Rockchip's own DriverAssistant INF
# ships (tools\rockchip-stock\...\ADBDriver).
#
# The interface NUMBER is the trap. Rockchip's INF assumes adb is always &MI_01,
# and an H7R is the other way round: adb on &MI_00, MTP on &MI_01. So the static
# list below is a floor, not the answer -- whatever the attached tablet actually
# reports gets added on top (see "live" section further down), which is the only
# thing that makes Have Disk work on a unit with the interfaces reversed.
$SingleAdbPids    = @('0006')
$CompositeAdbPids = @('0010','0011','0012','0013','0014','0015')
$AllAdbPids       = $SingleAdbPids + $CompositeAdbPids

# Shared PnP helpers: Get-MabuAndroidUsbNode reads what the tablet reports right
# now (which interface is adb, what is bound to it).
. (Join-Path $PSScriptRoot 'lib\MabuTools.ps1')

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
Write-Step "Patch android_winusb.inf for VID_${TargetVid} ADB PIDs"

$infPath = Join-Path $DriverDir 'android_winusb.inf'
if (-not (Test-Path $infPath)) { throw "android_winusb.inf not found at $infPath" }

$content = Get-Content -Path $infPath -Raw

$marker = "Mabu (VID_${TargetVid} ADB PIDs)"
$lines = @(";$marker - added by scripts\install-android-driver.ps1")
$ids   = @()
foreach ($p in $SingleAdbPids)    { $ids += @{ Kind = 'Single';    Id = "USB\VID_${TargetVid}&PID_${p}" } }
foreach ($p in $CompositeAdbPids) { $ids += @{ Kind = 'Composite'; Id = "USB\VID_${TargetVid}&PID_${p}&MI_01" } }

# Now the part the static list cannot know: the hardware ID this tablet's adb
# interface is reporting on THIS bench, right now. On a unit with the interfaces
# reversed that is &MI_00, which appears in no stock INF anywhere -- add it, or
# Have Disk will keep refusing the folder no matter how many PIDs are listed.
$liveAdb = @()
try { $liveAdb = @(Get-MabuAndroidUsbNode -Vid $TargetVid | Where-Object { $_.Role -eq 'adb' }) }
catch { Write-Warn "Could not enumerate USB devices: $($_.Exception.Message)" }
foreach ($n in $liveAdb) {
    # Prefer the plain ID over the &REV_ variants: it matches across firmware revisions.
    $hw = @($n.HardwareIds | Where-Object { $_ -match '^USB\\VID_' -and $_ -notmatch '&REV_' }) |
          Sort-Object Length | Select-Object -First 1
    if (-not $hw) { continue }
    if ($ids.Id -contains $hw) {
        Write-OK "Live adb interface '$($n.Name)' reports $hw (already in the static list)."
        continue
    }
    $kind = if ($n.Mi) { 'Composite' } else { 'Single' }
    $ids += @{ Kind = $kind; Id = $hw }
    Write-OK "Live adb interface '$($n.Name)' reports $hw -- adding it."
}

foreach ($e in $ids) {
    $token = if ($e.Kind -eq 'Single') { '%SingleAdbInterface%   ' } else { '%CompositeAdbInterface%' }
    $lines += "$token     = USB_Install, $($e.Id)"
}
$patch = "`r`n" + ($lines -join "`r`n") + "`r`n"

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
$missing = @()
foreach ($p in $AllAdbPids) {
    # Two sections (x86 + amd64), so each PID must appear at least twice.
    if (([regex]::Matches($final, [regex]::Escape("VID_${TargetVid}&PID_${p}"))).Count -lt 2) { $missing += $p }
}
if ($missing.Count) {
    Write-Warn "These PIDs are missing from one or both sections: $($missing -join ', ')"
} else {
    Write-OK "INF covers all $($AllAdbPids.Count) Mabu ADB PIDs ($($AllAdbPids -join ', ')) in both sections."
}

# Report what is on the bus, and single out the node the operator must click on.
$nodes = @()
try { $nodes = @(Get-MabuAndroidUsbNode -Vid $TargetVid) } catch { }
$AdbNode = $null
if ($nodes.Count) {
    foreach ($n in $nodes) {
        $tag = switch ($n.Role) { 'adb' { 'ADB  <- this is the one' } 'parent' { 'composite parent' } default { 'other function' } }
        Write-OK "$($n.Name)  [$($n.InstanceId)]"
        Write-Note "  role=$tag  service='$($n.Service)'  provider='$($n.Provider)'"
    }
    $AdbNode = $nodes | Where-Object { $_.Role -eq 'adb' } | Select-Object -First 1
    if (-not $AdbNode) {
        Write-Warn 'None of the present interfaces identifies itself as adb.'
        Write-Note 'USB debugging may be off on the tablet, or it is in a config without an adb function.'
    } elseif ($AdbNode.AdbDriverOk) {
        Write-OK 'The Android ADB driver is already bound to it -- `adb devices` should list the tablet.'
        Write-Note 'If it does not, the tablet is probably waiting for you to accept the RSA key prompt.'
    } elseif ($AdbNode.Provider -match 'libwdi') {
        Write-Warn 'That interface is bound to a Zadig-installed WinUSB driver.'
        Write-Note 'Zadig is only for the Loader (2207 320A). Pointed at the Android-mode device it'
        Write-Note 'leaves exactly this state: the tablet works "properly" in Device Manager and adb'
        Write-Note 'is blind, because generic WinUSB never registers the ADB interface GUID.'
        Write-Note 'The install below replaces that binding, which is the fix.'
    }
} else {
    Write-Warn 'Device not currently enumerated. Plug it in and re-run: without the tablet attached'
    Write-Warn 'this script cannot add the hardware ID your unit actually reports, and Have Disk may'
    Write-Warn 'still refuse the INF.'
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

$modelName = if ($AdbNode -and $AdbNode.Mi) { 'Android Composite ADB Interface' } else { 'Android ADB Interface' }

Write-Host '  Steps:' -ForegroundColor White
Write-Host '    1. Open Device Manager (devmgmt.msc).'
if ($AdbNode) {
    Write-Host "    2. Find this exact node -- it is the adb function, and the only one that matters:"
    Write-Host "         $($AdbNode.Name)" -ForegroundColor Cyan
    Write-Host "         $($AdbNode.InstanceId)" -ForegroundColor Cyan
    Write-Host '       (Properties > Details > Hardware Ids to confirm you are on the right one.'
    Write-Host '       Binding the driver to the other interface will not give you adb.)'
} else {
    Write-Host '    2. Find the tablet''s ADB interface under "Universal Serial Bus devices"'
    Write-Host '       (named "ADB Interface", or "H7R" if Zadig has bound it).'
}
Write-Host '    3. Right-click -> Update driver.'
Write-Host '    4. "Browse my computer for drivers".'
Write-Host '    5. "Let me pick from a list of available drivers on my computer".'
Write-Host '    6. Click "Have Disk..." -> Browse -> select android_winusb.inf in the path above.'
Write-Host "    7. Pick `"$modelName`"."
Write-Host '    8. Windows will warn the driver is not signed - click "Install this driver software anyway".'
Write-Host '    9. After install completes, run: adb devices'
Write-Host ''
Write-Host '  If step 6 still says "The folder you specified doesn''t contain a compatible software'
Write-Host '  driver", the INF has no line matching that node. Two ways out:' -ForegroundColor White
Write-Host '    a. Re-run this script WITH the tablet plugged in -- it adds the hardware ID your unit'
Write-Host '       reports, which is the whole point of the live check above.'
Write-Host '    b. Force it: go back, UNCHECK "Show compatible hardware", then Have Disk. Windows then'
Write-Host "       lists every model in the INF and lets you pick `"$modelName`" anyway"
Write-Host '       (accept the "not recommended" warning). Works regardless of hardware ID.'
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

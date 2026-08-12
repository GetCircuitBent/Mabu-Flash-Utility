# diagnose-usb.ps1
#
# Read-only USB / driver diagnostic for the Mabu flash path. Answers the
# question: "the harness is the same, why can't THIS machine see the device?"
#
# It checks the two host-side failure theories, neither of which is wiring:
#   Theory 1 - WinUSB is not bound to the Loader PID 0x320A, so the
#              libusb-based rkdeveloptool can't open it (device enumerates,
#              CLI sees nothing).
#   Theory 2 - The android_winusb (ADB) driver isn't installed for
#              PID 0x0006/0x0011, so `adb devices` is empty and the
#              deterministic `adb reboot loader` entry is unavailable.
#
# Nothing here writes, binds, or elevates - it only reports. Run it with the
# device in whatever state you've got (Android booted, recovery, or Loader
# caught) and read the verdict at the bottom.
#
#   .\scripts\diagnose-usb.ps1
#
# -Watch polls the PnP table for ~30s so you can plug in / power on the tablet
# and let it CATCH whatever appears - including the transient ~10s Loader
# window - instead of racing a manual re-run:
#
#   .\scripts\diagnose-usb.ps1 -Watch
#   .\scripts\diagnose-usb.ps1 -Watch -TimeoutSec 60
#
# -Guided walks you through the physical boot sequence Kendrick uses - press
# PWRON to cold-boot, then power on while HOLDING the ADKEY/recovery short -
# and watches the bus during EACH action so you can see exactly which button
# step (if any) makes a USB device appear. This is the test for the two
# "boot state / button-hold" theories:
#
#   .\scripts\diagnose-usb.ps1 -Guided

[CmdletBinding()]
param(
    [switch] $Watch,
    [switch] $Guided,
    [int]    $TimeoutSec = 30,
    [int]    $PollMs     = 400
)

$ErrorActionPreference = 'Continue'

$Root  = Split-Path -Parent $PSScriptRoot
$RkExe = Join-Path $Root 'tools\rkdeveloptool\rkdeveloptool.exe'

# Mabu/Rockchip USB IDs we care about.
$VID = '2207'
$PidMap = @{
    '320A' = 'Rockchip Loader (u-boot) - rkdeveloptool target, needs WinUSB'
    '0006' = 'Android (Esper/main)     - adb target, needs android_winusb'
    '0011' = 'Android recovery/MTP+ADB - adb target, needs android_winusb'
}

function Hr($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function OK($m)   { Write-Host "  [OK]    $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [MISS]  $m" -ForegroundColor Red }
function Note($m) { Write-Host "  [note]  $m" -ForegroundColor Yellow }

function Get-Prop($id, $key) {
    (Get-PnpDeviceProperty -InstanceId $id -KeyName $key -ErrorAction SilentlyContinue).Data
}

function Get-PidFromId($id) {
    if ($id -match 'PID_([0-9A-Fa-f]{4})') { return $Matches[1].ToUpper() }
    return $null
}

# ---------------------------------------------------------------------------
# Watch-Arrivals: baseline-diff the USB tree for $Seconds, printing each NEW
# device the instant it attaches. Catches VID_2207 (good), VID_0000 / Unknown
# USB Device (descriptor-fail), and anything else. Returns a summary with
# .Rk/.Fail/.Other booleans so callers can react.
# ---------------------------------------------------------------------------
function Watch-Arrivals {
    param([int] $Seconds, [int] $Poll = $PollMs)

    $baseline = @{}
    foreach ($d in (Get-PnpDevice | Where-Object { $_.InstanceId -match '^USB\\' })) { $baseline[$d.InstanceId] = $d.Status }

    $deadline = (Get-Date).AddSeconds($Seconds)
    $reported = @{}
    $sawRk = $false; $sawFail = $false; $sawOther = $false
    while ((Get-Date) -lt $deadline) {
        foreach ($d in (Get-PnpDevice | Where-Object { $_.InstanceId -match '^USB\\' })) {
            $id  = $d.InstanceId
            $key = "$id|$($d.Status)"
            $isNew      = -not $baseline.ContainsKey($id)
            $wasGhost   = ($baseline.ContainsKey($id) -and $baseline[$id] -eq 'Unknown' -and $d.Status -ne 'Unknown')
            if (($isNew -or $wasGhost) -and (-not $reported.ContainsKey($key))) {
                $reported[$key] = $true
                $stamp  = (Get-Date).ToString('HH:mm:ss')
                $pidHex = Get-PidFromId $id
                $svc    = (Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue).Data
                if ($id -match "VID_$VID") {
                    $sawRk = $true
                    $mode  = if ($pidHex -and $PidMap.ContainsKey($pidHex)) { $PidMap[$pidHex] } else { "PID $pidHex (unknown mode)" }
                    Write-Host ("`n  [{0}] ROCKCHIP  PID_{1}  Status={2}  Service={3}" -f $stamp,$pidHex,$d.Status,("$svc").Trim()) -ForegroundColor Green
                    Write-Host ("              -> {0}" -f $mode) -ForegroundColor Green
                } elseif ($id -match 'VID_0000' -or $d.FriendlyName -match 'Unknown USB Device|Descriptor Request Failed' -or $d.Status -eq 'Error') {
                    $sawFail = $true
                    Write-Host ("`n  [{0}] DESCRIPTOR-FAIL  {1}  Status={2}" -f $stamp,$d.FriendlyName,$d.Status) -ForegroundColor Red
                    Write-Host ("              -> {0}" -f $id) -ForegroundColor Red
                } else {
                    $sawOther = $true
                    Write-Host ("`n  [{0}] other USB  {1}  ({2})" -f $stamp,$d.FriendlyName,$id) -ForegroundColor DarkGray
                }
            }
        }
        Write-Host -NoNewline '.'
        Start-Sleep -Milliseconds $Poll
    }
    Write-Host ''
    return [PSCustomObject]@{ Rk = $sawRk; Fail = $sawFail; Other = $sawOther }
}

function Show-WatchVerdict($r, $secs) {
    if ($r.Rk) {
        OK 'A Rockchip (VID_2207) device enumerated - good. See details above + snapshot below.'
    } elseif ($r.Fail) {
        Bad 'A USB device tried to attach but FAILED descriptor negotiation (VID_0000 / Unknown USB Device).'
        Note 'The device IS electrically connecting but the host could not read its descriptors.'
        Note 'Host-side, non-harness culprits: a flaky/over-aggressive xHCI port (try a rear'
        Note '  motherboard USB 2 port), USB selective-suspend / link power mgmt, or a wedged stack.'
    } elseif ($r.Other) {
        Note 'Some non-Rockchip USB device arrived, but nothing Rockchip and no descriptor failure.'
        Note 'Inspect the "other USB" lines above - did the tablet enumerate as something unexpected?'
    } else {
        Bad "NOTHING attached to USB at all during the ${secs}s window - not even a failure node."
        Note 'Windows saw no device-attach event whatsoever. Interpret by what the TABLET did:'
        Note '  - If the screen/LED did NOT come on -> it did not power/boot (PWRON / DCIN).'
        Note '  - If the screen DID come on but USB stays silent -> the board booted but its'
        Note '    USB-OTG never entered DEVICE mode. The RK3288 only enumerates as a peripheral'
        Note '    when it senses VBUS (5V) from the host on the OTG VBUS line; that VBUS comes'
        Note '    from the PC port. A port not supplying VBUS (selective-suspend, unpowered'
        Note '    front-panel header, off hub) leaves it booted-but-silent. Decisive check:'
        Note '    plug a known USB stick into the EXACT same PC port - if IT does not show,'
        Note '    that port is the problem; move to a rear motherboard port.'
    }
}

# ---------------------------------------------------------------------------
# -Watch: single passive window. Plug in / power on and let it catch whatever
# appears, then fall through to the one-shot diagnostic.
# ---------------------------------------------------------------------------
if ($Watch) {
    Hr "Watching for ANY USB arrival for ${TimeoutSec}s"
    Note 'Now: connect the harness and power on / boot the tablet. Ctrl+C to stop early.'
    Note 'Catches VID_2207 (good) AND VID_0000 / "Unknown USB Device" (descriptor-fail).'
    $res = Watch-Arrivals -Seconds $TimeoutSec
    Show-WatchVerdict $res $TimeoutSec
    Hr 'Now taking a one-shot snapshot of the current state'
}

# ---------------------------------------------------------------------------
# -Guided: walk the operator through Kendrick's button sequence, watching the
# bus during EACH action so we can correlate a specific button step with a
# device appearing. Tests the "boot state / button-hold" theories directly.
# ---------------------------------------------------------------------------
if ($Guided) {
    Hr 'Guided boot-sequence capture (correlate each button action with the bus)'
    Note 'Header pins (see Mabu/README.md pinout): PWRON = pin 19, ADKEY = pin 28, GND = pin 30.'
    Note 'Harness should be connected to the PC the whole time. Read each prompt, do the action,'
    Note 'then watch the dots - any device that attaches will print immediately.'
    Write-Host ''

    # Phase 0 - make sure we start from a true power-off so PWRON causes a real
    # cold-boot transition (the only thing that re-opens the ~10s Loader window).
    Read-Host 'PHASE 0: Fully power the board OFF (hold PWRON >7s if unsure). Press Enter when off'

    # Phase 1 - PWRON cold-boot (Theory 1): does a plain power-on present a USB gadget?
    Hr 'PHASE 1 - PWRON cold-boot (no mode button held)'
    Note 'When the dots start: PULSE PWRON to power the board on. Do NOT hold any other pin.'
    Read-Host '  Press Enter to begin watching, THEN pulse PWRON'
    $p1 = Watch-Arrivals -Seconds 20
    if ($p1.Rk)        { OK 'PHASE 1: a Rockchip device appeared from a plain PWRON cold-boot.' }
    elseif ($p1.Fail)  { Bad 'PHASE 1: device attached but descriptor-failed (see above).' }
    elseif ($p1.Other) { Note 'PHASE 1: only a non-Rockchip device appeared (see above).' }
    else               { Note 'PHASE 1: nothing on a plain PWRON boot - try the held-button phase next.' }

    # Phase 2 - PWRON + held ADKEY/recovery (Theory 2): force the boot mode.
    Hr 'PHASE 2 - PWRON while HOLDING ADKEY/recovery (force the mode)'
    Read-Host '  First power the board OFF again. Press Enter when off'
    Note 'When the dots start: SHORT ADKEY (pin 28) to GND (pin 30) AND pulse PWRON, and KEEP'
    Note '  ADKEY held through boot. Release only once a device appears below.'
    Read-Host '  Press Enter to begin watching, THEN power on with ADKEY held'
    $p2 = Watch-Arrivals -Seconds 25
    if ($p2.Rk)        { OK 'PHASE 2: holding ADKEY/recovery during boot made a Rockchip device appear.' }
    elseif ($p2.Fail)  { Bad 'PHASE 2: device attached but descriptor-failed (see above).' }
    elseif ($p2.Other) { Note 'PHASE 2: only a non-Rockchip device appeared (see above).' }
    else               { Note 'PHASE 2: still nothing even with ADKEY held.' }

    # Guided verdict - which boot action (if any) produced a device.
    Hr 'GUIDED VERDICT'
    if ($p1.Rk -or $p2.Rk) {
        if (-not $p1.Rk -and $p2.Rk) {
            OK 'Confirmed Theory 2: a HELD button during boot is required to expose the USB gadget.'
            Note 'This machine sees nothing on a plain power-on; Kendrick catches it because he holds'
            Note '  the recovery/ADKEY button during boot. Make that step part of every session.'
        } else {
            OK 'A PWRON cold-boot alone exposed the gadget (Theory 1: just needed a real power-on).'
            Note 'The missing step on this machine was triggering an actual PWRON cold-boot to open'
            Note '  the ~10s Loader window; no held mode button was needed.'
        }
        Note 'Now check the PID/Service in the lines above and the snapshot below: PID_320A with'
        Note '  Service=WinUSB means rkdeveloptool can flash; anything else is the next thing to fix.'
    } else {
        Bad 'Neither a plain PWRON boot nor a held-ADKEY boot put any device on the bus.'
        Note 'With hardware confirmed good, re-verify the PWRON pulse actually powers the board'
        Note '  (screen/LED), the ADKEY short hits the right pins, and the PC port is live.'
    }
    Hr 'Now taking a one-shot snapshot of the current state'
}

# State we accumulate for the verdict.
$loaderPresent   = $false; $loaderWinUsb = $false
$androidPresent  = $false; $androidAdbDrv = $false
$ghosts = @()

# ---------------------------------------------------------------------------
Hr 'All Rockchip (VID_2207) USB devices - present and ghost'
# ---------------------------------------------------------------------------
$all = Get-PnpDevice | Where-Object { $_.InstanceId -match "VID_$VID" }
if (-not $all) {
    Note "No VID_$VID devices in the PnP database at all (present or ghost)."
    Note "Either nothing is plugged in / powered, or the device has never enumerated on this PC."
} else {
    foreach ($d in $all) {
        $pidHex  = Get-PidFromId $d.InstanceId
        $mode    = if ($pidHex -and $PidMap.ContainsKey($pidHex)) { $PidMap[$pidHex] } else { "PID $pidHex (unknown mode)" }
        $present = $d.Status -ne 'Unknown'   # ghost/non-present devices report Status 'Unknown'
        $svc     = Get-Prop $d.InstanceId 'DEVPKEY_Device_Service'
        $inf     = Get-Prop $d.InstanceId 'DEVPKEY_Device_DriverInfPath'

        $tag = if ($present) { 'PRESENT' } else { 'GHOST  ' }
        $col = if ($present) { 'White' } else { 'DarkGray' }
        Write-Host ("  [{0}] PID_{1}  Status={2}  Class={3}  Service={4}  Inf={5}" -f `
            $tag, $pidHex, $d.Status, $d.Class, ($svc | Out-String).Trim(), ($inf | Out-String).Trim()) -ForegroundColor $col
        Write-Host ("            -> {0}" -f $mode) -ForegroundColor $col

        if (-not $present) { $ghosts += $d; continue }

        if ($pidHex -eq '320A') {
            $loaderPresent = $true
            if ("$svc" -match 'WinUSB' -or $d.Class -match 'WinUSB|libusb') { $loaderWinUsb = $true }
        } elseif ($pidHex -in @('0006','0011')) {
            $androidPresent = $true
            # ADB driver binds the composite child as an "Android ... Interface".
            if ("$($d.FriendlyName)" -match 'ADB|Android' -or "$svc" -match 'WinUSB') { $androidAdbDrv = $true }
        }
    }
}

# ---------------------------------------------------------------------------
Hr 'Problem-state devices (yellow-bang / descriptor failures)'
# ---------------------------------------------------------------------------
$prob = Get-PnpDevice -PresentOnly | Where-Object { $_.Status -ne 'OK' -and $_.Status -ne 'Unknown' }
if ($prob) {
    $prob | Select-Object FriendlyName, Status, Class, InstanceId | Format-Table -AutoSize -Wrap
    if ($prob | Where-Object { $_.InstanceId -match 'VID_0000|VID_$VID' }) {
        Note "A Rockchip/descriptor-failed node here usually means a driver bind problem, not wiring."
    }
} else {
    OK 'No problem-state devices.'
}

# ---------------------------------------------------------------------------
Hr 'Driver store - is the Android ADB (android_winusb) driver installed?'
# ---------------------------------------------------------------------------
$infText = & pnputil /enum-drivers 2>&1 | Out-String
$records = $infText -split "`r?`n`r?`n"
$adbInfs = @()
foreach ($r in $records) {
    if ($r -match 'android_winusb|androidwinusb|Android (Bootloader|ADB|Composite)|WinUSB') {
        if ($r -match 'Published Name:\s*(\S+)') {
            $name = $Matches[1]
            # Only flag ones that look Android/Google/Rockchip ADB related.
            if ($r -match 'android|Google|Rockchip|WinUSB') { $adbInfs += "$name :: " + (($r -split "`n" | Where-Object { $_ -match 'Original Name|Provider|Class' }) -join '  ') }
        }
    }
}
if ($adbInfs) {
    OK 'Found WinUSB/Android-class INF(s) in the driver store:'
    $adbInfs | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
} else {
    Bad 'No android_winusb / Android-ADB INF found in the driver store (Theory 2 indicator).'
}

# ---------------------------------------------------------------------------
Hr 'rkdeveloptool ld  (can the libusb CLI open the Loader?)'
# ---------------------------------------------------------------------------
if (Test-Path $RkExe) {
    # No 2>&1 on the native exe: in PS 5.1 that wraps stderr in an error record.
    $ld = (& $RkExe ld | Out-String)
    Write-Host "    $($ld.Trim())" -ForegroundColor DarkGray
    if ($ld -match 'Pid=0x320a') {
        OK 'rkdeveloptool sees the Loader (WinUSB binding is working).'
        $loaderWinUsb = $true
    } else {
        Note 'rkdeveloptool sees no Loader. Either Loader not caught right now, or WinUSB not bound.'
    }
} else {
    Bad "rkdeveloptool.exe not found at $RkExe"
}

# ---------------------------------------------------------------------------
Hr 'adb devices  (can adb see a booted tablet for `adb reboot loader`?)'
# ---------------------------------------------------------------------------
# Repo-relative copy first (install-tools.ps1 puts it there, and it is the one
# location that survives an elevation switching user accounts), then PATH, then
# the SDK location.
$adb = $null
$repoAdb = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\platform-tools\adb.exe'
if (Test-Path $repoAdb) { $adb = $repoAdb }
if (-not $adb) { $adb = (Get-Command adb -ErrorAction SilentlyContinue).Source }
if (-not $adb) {
    $adb = Get-ChildItem -Path "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -Expand FullName
}
if ($adb) {
    OK "adb found: $adb"
    $dev = (& $adb devices | Out-String)
    Write-Host "    $($dev.Trim())" -ForegroundColor DarkGray
    if ($dev -match '\bdevice\b') {
        OK 'adb sees a device -> the deterministic `adb reboot loader` entry is available.'
        $androidAdbDrv = $true
    } else {
        Note 'adb sees no device. If the tablet is booted + connected, the ADB driver is the gap.'
    }
} else {
    Bad 'adb not found on PATH or in the default SDK location (install Google.PlatformTools).'
}

# ---------------------------------------------------------------------------
Hr 'VERDICT - what this machine needs'
# ---------------------------------------------------------------------------
if ($ghosts.Count) {
    Note "$($ghosts.Count) ghost VID_$VID node(s) present - stale bindings can hijack the PID and block a clean rebind."
    Note 'Clear them (elevated): pnputil /enum-devices, then /remove-device on each non-present VID_2207 instance.'
}

if ($loaderPresent -and -not $loaderWinUsb) {
    Bad 'THEORY 1 CONFIRMED: Loader (320A) enumerates but is NOT bound to WinUSB.'
    Write-Host '         Fix: RKDevTool v2.92 -> Read Flash Info (latches Loader),' -ForegroundColor White
    Write-Host '              then Zadig -> replace 320A driver with WinUSB.' -ForegroundColor White
} elseif ($loaderWinUsb) {
    OK 'Theory 1 clear: Loader path can be opened by rkdeveloptool.'
} else {
    Note 'Theory 1 inconclusive: Loader not caught during this run. Re-run with Loader latched'
    Note '  (power tablet off, run latch-loader.ps1, power on) to test the WinUSB binding.'
}

# Before the generic "no ADB binding" verdict: check for the specific, much more
# confusing version of it -- the adb interface present and reported as working
# properly, but bound to a driver that adb cannot see through. That is what Zadig
# leaves behind when it is aimed at the tablet in Android mode instead of at the
# Loader, and it looks like a healthy device from every angle except adb's.
$misbound = @()
try {
    . (Join-Path $PSScriptRoot 'lib\MabuTools.ps1')
    $misbound = @(Get-MabuMisboundAdbNode -Vid $VID)
} catch {
    Note "Could not run the driver-misbinding check: $($_.Exception.Message)"
}
if ($misbound.Count) {
    Bad 'ZADIG MISBINDING CONFIRMED: the tablet is on the bus but adb cannot see it.'
    foreach ($m in $misbound) {
        Write-Host "         $($m.Name)  [$($m.InstanceId)]" -ForegroundColor White
        Write-Host "           $($m.Reason)" -ForegroundColor White
        Write-Host "           service='$($m.Service)'  provider='$($m.Provider)'" -ForegroundColor White
    }
    Write-Host '         Fix: Device Manager -> right-click that node -> Uninstall device,' -ForegroundColor White
    Write-Host '              tick "Delete the driver software for this device", unplug/replug,' -ForegroundColor White
    Write-Host '              then run scripts\install-android-driver.ps1.' -ForegroundColor White
    Write-Host '         Zadig is ONLY ever for the Loader (2207 320A), never for 2207 0006/0010-0015.' -ForegroundColor White
} elseif (-not $adbInfs -or ($androidPresent -and -not $androidAdbDrv)) {
    Bad 'THEORY 2 LIKELY: no working android_winusb ADB binding for PID 0006/0011.'
    Write-Host '         Fix: install the Google USB driver (android_winusb.inf) via Device Manager' -ForegroundColor White
    Write-Host '              Have Disk, or winget install Google.PlatformTools + OEM driver.' -ForegroundColor White
    Write-Host '              Then `adb reboot loader` becomes the easy 1-second Loader entry.' -ForegroundColor White
} elseif ($androidAdbDrv) {
    OK 'Theory 2 clear: adb can see the tablet (deterministic Loader entry available).'
} else {
    Note 'Theory 2 inconclusive: no Android-mode device enumerated during this run.'
    Note '  Boot the tablet normally and re-run to test the ADB driver.'
}

Write-Host ''
Write-Host 'Re-run in each device state (Android booted, and Loader caught) for a complete picture.' -ForegroundColor Cyan

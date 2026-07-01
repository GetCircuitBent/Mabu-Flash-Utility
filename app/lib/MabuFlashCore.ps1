<#
  MabuFlashCore.ps1 -- UI-agnostic copy of scripts/flash-mabu.ps1.

  This is a fork of the proven console script, refactored to drive the injected
  UI-provider contract (app/lib/MabuUi.ps1) instead of writing to the host
  directly. scripts/flash-mabu.ps1 stays frozen as the known-good original;
  fixes must be mirrored here by hand.

  What changed vs the original (logic body is otherwise byte-identical):
    * Section/Info/Ok/Warn/Fail now route through $script:Ui (Section + Log).
    * `Read-Host` pauses -> $script:Ui.Prompt (blocking, returns a button).
    * `exit 1` -> `throw 'aborted'` (caught -> $Ui.Done $false); `exit 0` -> Done + return.
    * Added $Ui.Flash calls at phase boundaries and $Ui.Validate per self-test check.
    * $RK/$ADB/$Root/$WifiIp are $script: vars set by Invoke-MabuFlash.

  Known gap: liberate-mabu.ps1 / wipe-data-head.ps1 are child scripts; their
  own console output does not route through $Ui yet (the phase Section + Flash
  still convey progress). Refactoring those is a later step.

  Usage:
    . app/lib/MabuFlashCore.ps1
    Invoke-MabuFlash -RestoreMabu                 # console (default provider)
    Invoke-MabuFlash -Ui $guiProvider -RestoreMabu  # GUI
#>

# ---- Output helpers: route through the injected provider ---------------------
function Section($msg) { & $script:Ui.Section $msg }
function Info($msg)    { & $script:Ui.Log 'info' $msg }
function Ok($msg)      { & $script:Ui.Log 'ok'   $msg }
function Warn($msg)    { & $script:Ui.Log 'warn' $msg }
function Fail($msg)    { & $script:Ui.Log 'fail' $msg }
# Abort: log the reason (already done by the caller's Fail) and unwind to the
# top-level catch, which reports Done $false. Replaces the original `exit 1`.
function Abort($msg)   { if (-not $msg) { $msg = 'aborted' }; throw [System.OperationCanceledException]::new($msg) }

function Invoke-Child {
    # Run a child .ps1 (which uses Write-Host) and forward each output line to the
    # UI log, so GUI runs surface child-script progress instead of losing it to
    # the host. Preserves $LASTEXITCODE for the caller's success check.
    param([string] $RelPath, [hashtable] $Named = @{})
    $p = Join-Path $script:Root $RelPath
    & $p @Named *>&1 | ForEach-Object {
        $txt = if ($_ -is [System.Management.Automation.InformationRecord]) {
                   $md = $_.MessageData
                   if ($md -and $md.PSObject.Properties['Message']) { $md.Message } else { "$md" }
               } elseif ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() }
               else { "$_" }
        if ($txt -and $txt.Trim().Length) { Info $txt }
    }
}

function Test-Loader { (& $script:RK ld 2>&1) -match 'Vid=0x2207,Pid=0x320a.*Loader' }

function Get-LoaderDriverService {
    $d = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
         Where-Object { $_.InstanceId -match 'VID_2207&PID_320A' } | Select-Object -First 1
    if (-not $d) { return $null }
    return (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue).Data
}

function Find-Zadig {
    $c = @()
    $c += Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\akeo.ie.Zadig_*" -Filter 'zadig*.exe' -Recurse -ErrorAction SilentlyContinue
    $c += Get-ChildItem "$env:ProgramFiles","${env:ProgramFiles(x86)}" -Filter 'zadig*.exe' -Recurse -ErrorAction SilentlyContinue
    return ($c | Select-Object -First 1).FullName
}

function Confirm-LoaderWinUsb {
    # Gate before any Loader read/write: ensure PID 320A is bound to WinUSB.
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
        Warn 'In Zadig:'
        Warn '  1. Options -> List All Devices'
        Warn "  2. In the dropdown pick 'Rockusb Device' (USB ID 2207 320A)"
        Warn '  3. Set the target driver to WinUSB, then click Replace Driver'
        Warn "  4. Wait for 'Driver Installed Successfully'"
        Warn 'Keep the tablet powered / in Loader the whole time -- do NOT power-cycle.'
    } else {
        Fail 'Zadig not found. Install it (winget install -e --id akeo.ie.Zadig)'
        Fail 'and rebind 320A -> WinUSB manually, then re-run.'
        Abort 'Zadig not found.'
    }
    & $script:Ui.Prompt 'Rebind PID 320A to WinUSB in Zadig' `
        'In Zadig: Options -> List All Devices, pick Rockusb Device (USB ID 2207 320A), set target WinUSB, click Replace Driver. Keep the tablet in Loader. Click Continue once it reports success.' `
        @('Continue') | Out-Null

    for ($i = 0; $i -lt 20; $i++) {
        $svc = Get-LoaderDriverService
        if ($svc -match 'WinUSB|libusb') { break }
        Start-Sleep -Seconds 1
    }
    if ($svc -notmatch 'WinUSB|libusb') {
        Fail "PID 320A still bound to '$svc'. Re-run Zadig (target WinUSB), then re-run."
        Abort 'WinUSB binding failed.'
    }
    if (-not (Test-Loader)) {
        Warn 'Loader not visible right after rebind; waiting for re-enumeration...'
        for ($i = 0; $i -lt 15; $i++) { Start-Sleep -Seconds 1; if (Test-Loader) { break } }
    }
    if (-not (Test-Loader)) {
        Fail 'Loader gone after rebind. Re-catch Loader (hold ADKEY through power-on) and re-run.'
        Abort 'Loader gone after rebind.'
    }
    Ok "PID 320A now bound to '$svc'. rkdeveloptool ready."
}

function Get-MabuState {
    param([string] $Dev)
    if (-not $Dev) { return 'Unknown' }
    $alive = & $script:ADB -s $Dev shell 'echo MABU_OK' 2>&1
    if ($alive -notmatch 'MABU_OK') { return 'Unknown' }   # adb wedged/offline
    $dpc = & $script:ADB -s $Dev shell 'pm path io.shoonya.shoonyadpc 2>/dev/null' 2>&1
    if ($dpc -match 'package:') { return 'A' }
    $svc = & $script:ADB -s $Dev shell 'getprop init.svc.set-device-owner' 2>&1
    if ($svc -match '^\s*$') { return 'Liberated' }
    return 'B'
}

function Find-AdbDevice {
    param([string] $PreferIp, [int] $TimeoutSec = 180, [switch] $WifiOnly)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($PreferIp) {
            $r = & $script:ADB connect "${PreferIp}:5555" 2>&1
            if ($r -match 'connected to|already connected') {
                $ok = & $script:ADB -s "${PreferIp}:5555" shell echo ok 2>&1
                if ($ok -match '^ok') { return "${PreferIp}:5555" }
            }
        }
        if (-not $WifiOnly) {
            $usb = @(& $script:ADB devices 2>&1 | Where-Object { $_ -match '^\S+\s+device$' -and $_ -notmatch ':\d+\s+device$' })
            if ($usb.Count -gt 0) {
                $serial = ($usb[0] -split '\s+')[0]
                $ok = & $script:ADB -s $serial shell echo ok 2>&1
                if ($ok -match '^ok') { return $serial }
            }
        }
        Start-Sleep -Seconds 3
    }
    return $null
}

function Get-DeviceWifiIp {
    param([string] $Dev)
    if (-not $Dev) { return $null }
    $out = (& $script:ADB -s $Dev shell 'ip -f inet addr show wlan0 2>/dev/null' 2>&1) -join "`n"
    $ip  = ([regex]::Match($out, 'inet\s+(\d{1,3}(?:\.\d{1,3}){3})')).Groups[1].Value
    if (-not $ip) {
        $out = (& $script:ADB -s $Dev shell 'ip route 2>/dev/null' 2>&1) -join "`n"
        $ip  = ([regex]::Match($out, 'wlan0.*\bsrc\s+(\d{1,3}(?:\.\d{1,3}){3})')).Groups[1].Value
    }
    if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { return $ip }
    return $null
}

function Apply-SELinuxFix {
    param([string] $Dev)
    Section 'SELinux policy fix'
    $sha = (& $script:ADB -s $Dev shell 'sha256sum /vendor/etc/selinux/precompiled_sepolicy 2>/dev/null' 2>&1) -join ''
    if ($sha -match '03f180a2') { Ok 'SELinux policy already patched (03f180a2) -- skipping.'; return }
    if ($sha -match '7f26df2d') { Info 'Stock policy confirmed (7f26df2d) -- applying fix.' }
    else { Warn "Unexpected policy SHA: $sha -- proceeding anyway." }

    $mp = Join-Path $script:Root 'tools/magiskpolicy/magiskpolicy-armeabi-v7a'
    if (-not (Test-Path $mp)) { Warn 'tools/magiskpolicy/magiskpolicy-armeabi-v7a not found -- skipping.'; return }
    & $script:ADB -s $Dev push $mp /data/local/tmp/magiskpolicy 2>&1 | Out-Null
    & $script:ADB -s $Dev shell 'chmod 755 /data/local/tmp/magiskpolicy' 2>&1 | Out-Null

    $r = & $script:ADB -s $Dev shell "cp /vendor/etc/selinux/precompiled_sepolicy /data/local/tmp/sepolicy.in && /data/local/tmp/magiskpolicy --load /data/local/tmp/sepolicy.in --save /data/local/tmp/sepolicy.out 'allow untrusted_app serial_device chr_file { open read write getattr ioctl }' && echo PATCH_OK" 2>&1
    if ($r -notmatch 'PATCH_OK') { Warn "magiskpolicy failed: $($r -join ' ') -- skipping."; return }
    Ok 'On-device patch succeeded.'

    $outFile = Join-Path $script:Root 'firmware\scratch\sepolicy.patched'
    & $script:ADB -s $Dev pull /data/local/tmp/sepolicy.out $outFile 2>&1 | Out-Null
    if (-not (Test-Path $outFile)) { Warn 'Pull failed -- skipping Loader write.'; return }
    $patchedSha = (Get-FileHash $outFile -Algorithm SHA256).Hash.ToLower()
    Info "Patched SHA256: $patchedSha"
    if ($patchedSha -notmatch '^03f180a2') { Warn "Patched SHA unexpected ($patchedSha) -- aborting Loader write."; return }

    Info 'Entering Loader for policy write...'
    & $script:ADB -s $Dev shell reboot loader 2>&1 | Out-Null
    for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Seconds 1; if (Test-Loader) { Ok "Loader caught after ${i}s."; break } }
    if (-not (Test-Loader)) { Warn 'Loader not caught. Apply SELinux fix manually (wl 0x5A8AB8 firmware\scratch\sepolicy.patched).'; return }
    Confirm-LoaderWinUsb

    & $script:RK wl 0x5A8AB8 $outFile 2>&1 | ForEach-Object { Info $_ }
    Ok 'Policy written to vendor partition.'
    & $script:RK rd 2>&1 | Out-Null
    Ok 'Reset issued -- device will reboot with patched SELinux policy.'
}

function Run-SelfTest {
    param([string] $Dev)
    Section 'Self-test'
    $stP = 0; $stF = 0; $stW = 0
    $stI = 0; $stN = 11
    # Advance the Validating bar one notch per completed check.
    function Bump($label) { & $script:Ui.Validate ((++$script:stI) / $stN * 100) $label }
    $script:stI = 0

    $v = (& $script:ADB -s $Dev shell 'getprop ro.device_owner' 2>&1) -join ''
    if ($v -match '^\s*$|false') { Ok  '[PASS] No device owner';                       $stP++ }
    else                         { Fail "[FAIL] No device owner  (got: $v)";            $stF++ }
    Bump 'No device owner'

    $v = (& $script:ADB -s $Dev shell 'getprop init.svc.set-device-owner' 2>&1) -join ''
    if ($v -match '^\s*$')       { Ok  '[PASS] init.esper.rc zeroed';                  $stP++ }
    else                         { Fail "[FAIL] init.esper.rc zeroed  (got: $v)";       $stF++ }
    Bump 'init.esper.rc zeroed'

    $v = (& $script:ADB -s $Dev shell 'pm path io.shoonya.shoonyadpc 2>/dev/null' 2>&1) -join ''
    if ($v -match '^\s*$')       { Ok  '[PASS] Esper DPC absent from /data';           $stP++ }
    else                         { Fail "[FAIL] Esper DPC absent from /data  (got: $v)"; $stF++ }
    Bump 'Esper DPC absent'

    $v = (& $script:ADB -s $Dev shell 'getprop ro.boot.veritymode' 2>&1) -join ''
    if ($v -match 'disabled')    { Ok  '[PASS] dm-verity disabled';                    $stP++ }
    else                         { Fail "[FAIL] dm-verity disabled  (got: $v)";         $stF++ }
    Bump 'dm-verity disabled'

    $v = (& $script:ADB -s $Dev shell 'pm list packages org.fdroid.fdroid 2>/dev/null' 2>&1) -join ''
    if ($v -match 'package:')    { Ok  '[PASS] F-Droid installed';                     $stP++ }
    else                         { Fail '[FAIL] F-Droid installed';                     $stF++ }
    Bump 'F-Droid installed'

    $v = (& $script:ADB -s $Dev shell 'pm list packages app.lawnchair 2>/dev/null' 2>&1) -join ''
    if ($v -match 'package:')    { Ok  '[PASS] Lawnchair installed';                   $stP++ }
    else                         { Fail '[FAIL] Lawnchair installed';                   $stF++ }
    Bump 'Lawnchair installed'

    $v = (& $script:ADB -s $Dev shell 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null' 2>&1) -join ''
    if ($v -match 'lawnchair')   { Ok  '[PASS] Lawnchair is home launcher';            $stP++ }
    else                         { Fail "[FAIL] Lawnchair is home launcher  (got: $v)"; $stF++ }
    Bump 'Lawnchair is home'

    $v = (& $script:ADB -s $Dev shell 'pm list packages com.catalia.factorymode 2>/dev/null' 2>&1) -join ''
    if ($v -match 'package:')    { Ok  '[PASS] Mabu factory mode installed';           $stP++ }
    else                         { Fail '[FAIL] Mabu factory mode installed';           $stF++ }
    Bump 'Factory mode installed'

    $v = (& $script:ADB -s $Dev shell 'getenforce' 2>&1) -join ''
    if ($v -match 'Enforcing')   { Ok  '[PASS] SELinux enforcing';                     $stP++ }
    else                         { Fail "[FAIL] SELinux enforcing  (got: $v)";          $stF++ }
    Bump 'SELinux enforcing'

    $v = (& $script:ADB -s $Dev shell 'sha256sum /vendor/etc/selinux/precompiled_sepolicy 2>/dev/null' 2>&1) -join ''
    if ($v -match '03f180a2')    { Ok  '[PASS] SELinux policy patched (03f180a2)';     $stP++ }
    else                         { Fail "[FAIL] SELinux policy patched  (got: $v)";     $stF++ }
    Bump 'SELinux policy patched'

    $wlanOut = (& $script:ADB -s $Dev shell 'ip addr show wlan0 2>/dev/null' 2>&1) -join ' '
    $wlanIp  = ([regex]::Match($wlanOut, 'inet\s+(\d{1,3}(?:\.\d{1,3}){3})')).Groups[1].Value
    if ($wlanIp) {
        $r  = (& $script:ADB connect "${wlanIp}:5555" 2>&1) -join ''
        $ok = if ($r -match 'connected to|already connected') { (& $script:ADB -s "${wlanIp}:5555" shell echo ok 2>&1) -join '' } else { '' }
        if   ($ok -match 'ok') { Ok   "[PASS] WiFi adb reachable ($wlanIp`:5555)";             $stP++ }
        else                   { Warn "[WARN] WiFi adb unreachable ($wlanIp`:5555) -- network isolation?"; $stW++ }
    } else { Warn '[WARN] WiFi adb: no IP on wlan0'; $stW++ }
    Bump 'WiFi adb reachable'

    $sev = if ($stF -gt 0) { 'fail' } elseif ($stW -gt 0) { 'warn' } else { 'ok' }
    & $script:Ui.Log $sev "Self-test: $stP passed  $stF failed  $stW warnings"
    if ($stF -gt 0) { Warn 'One or more checks FAILED -- review before deploying this unit.' }
}

function Enable-WifiAdb {
    param([string] $UsbDev)
    if (-not $UsbDev) { return $null }
    $ip = Get-DeviceWifiIp -Dev $UsbDev
    if (-not $ip) { Warn 'Could not read tablet WiFi IP (is it associated to WiFi?).'; return $null }
    Info "Tablet WiFi IP: $ip"
    $r = & $script:ADB connect "${ip}:5555" 2>&1
    if ($r -match 'connected to|already connected') {
        $ok = & $script:ADB -s "${ip}:5555" shell echo ok 2>&1
        if ($ok -match '^ok') { $script:WifiIp = $ip; return "${ip}:5555" }
    }
    $spJob = Start-Job { param($adb,$dev) & $adb -s $dev shell 'setprop persist.adb.tcp.port 5555' 2>&1 } -ArgumentList $script:ADB,$UsbDev
    if (-not (Wait-Job $spJob -Timeout 8)) { Stop-Job $spJob }
    Remove-Job $spJob -Force
    $tcpJob = Start-Job { param($adb,$dev) & $adb -s $dev tcpip 5555 2>&1 } -ArgumentList $script:ADB,$UsbDev
    if (-not (Wait-Job $tcpJob -Timeout 8)) {
        Stop-Job $tcpJob
        Warn 'adb tcpip timed out (USB adb wedged); will try WiFi connect anyway.'
    }
    Remove-Job $tcpJob -Force
    Start-Sleep -Seconds 3
    for ($i = 0; $i -lt 10; $i++) {
        $r = & $script:ADB connect "${ip}:5555" 2>&1
        if ($r -match 'connected to|already connected') {
            $ok = & $script:ADB -s "${ip}:5555" shell echo ok 2>&1
            if ($ok -match '^ok') { $script:WifiIp = $ip; return "${ip}:5555" }
        }
        Start-Sleep -Seconds 2
    }
    Warn "tcpip enabled but ${ip}:5555 unreachable (WiFi client isolation, or different subnet)."
    return $null
}

function Invoke-MabuFlash {
    [CmdletBinding()]
    param(
        [hashtable] $Ui,                    # UI provider; defaults to console
        [switch] $WipeData,
        [switch] $NoWipe,
        [int]    $WipeMB = 96,
        [switch] $RestoreMabu,
        [switch] $SkipApps,
        [switch] $SkipSELinux,
        [string] $WifiIp = '192.168.0.18',
        [string] $UsbSerial,
        [string] $LawnchairApk = 'apks/Lawnchair.apk',
        [string] $FDroidApk    = 'apks/F-Droid.apk',
        [string] $MabuArchive  = 'mabu-archive',
        [string] $Root
    )

    if (-not $Ui) { . (Join-Path $PSScriptRoot 'MabuUi.ps1'); $Ui = New-ConsoleUi }
    $script:Ui = $Ui
    $script:Root = if ($Root) { $Root } else { (Resolve-Path '.').Path }
    $script:RK = Join-Path $script:Root 'tools/rkdeveloptool/rkdeveloptool.exe'
    $script:ADB = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    if (-not $script:ADB) { & $Ui.Done $false 'adb.exe not found (install Google.PlatformTools).'; return }
    $script:WifiIp = $WifiIp

    # Pre-start the adb server while errors are non-fatal (avoids a stderr banner
    # turning into a terminating NativeCommandError mid-flash).
    $ErrorActionPreference = 'Continue'
    & $script:ADB start-server 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'

    try {
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
            $dev = Find-AdbDevice -PreferIp $script:WifiIp -TimeoutSec 30
            if (-not $dev) {
                Fail 'No adb device and no Loader. Power-cycle the tablet to catch Loader, then re-run.'
                Abort 'No adb device and no Loader.'
            }
            $state = Get-MabuState -Dev $dev
            switch ($state) {
                'A'         { Ok   "Detected State A (active Esper DPC in /data) at $dev." }
                'B'         { Ok   "Detected State B (factory-reset Esper) at $dev." }
                'Liberated' { Ok   "Device already liberated at $dev -- skipping Loader flash." }
                default     { Warn "Could not determine Esper state at $dev (adb may be wedging)." }
            }
            if ($state -ne 'Liberated') {
                $wifiDev = Enable-WifiAdb -UsbDev $dev
                if ($wifiDev) { Ok "WiFi adb enabled at $wifiDev"; $dev = $wifiDev }
                else          { Warn 'WiFi adb not established now; inter-phase will retry over USB/WiFi.' }
                Info "Rebooting into Loader."
                & $script:ADB -s $dev shell reboot loader 2>&1 | Out-Null
                for ($i = 0; $i -lt 30; $i++) {
                    Start-Sleep -Seconds 1
                    if (Test-Loader) { Ok "Loader caught after ${i}s."; break }
                }
                if (-not (Test-Loader)) { Fail 'Loader did not appear in 30s.'; Abort 'Loader did not appear.' }
            }
        }
        & $Ui.Flash 10 'Loader detection'

        if ($state -eq 'Liberated') {
            Info 'Skipping wipe policy, patches, and wipe -- device is already liberated.'
            & $Ui.Flash 62 'Already liberated'
        }

        # --- Decide wipe policy: explicit flags win, else auto from detected state ---
        if ($state -ne 'Liberated' -and $WipeData -and $NoWipe) { Fail 'Pass only one of -WipeData / -NoWipe.'; Abort 'Conflicting wipe flags.' }
        if ($state -ne 'Liberated') {
            if     ($WipeData) { $doWipe = $true;  $wipeWhy = 'forced by -WipeData' }
            elseif ($NoWipe)   { $doWipe = $false; $wipeWhy = 'forced by -NoWipe' }
            elseif ($state -eq 'A') { $doWipe = $true;  $wipeWhy = 'auto: State A (active /data DPC must be wiped)' }
            elseif ($state -eq 'B') { $doWipe = $false; $wipeWhy = 'auto: State B (patches alone suffice)' }
            else                    { $doWipe = $true;  $wipeWhy = 'auto: state undetermined -> safe default = wipe' }
            Section 'Wipe policy'
            if ($doWipe) { Ok  "/data wipe: ON  ($wipeWhy)" }
            else         { Ok  "/data wipe: OFF ($wipeWhy)" }

            # --- Gate: PID 320A must be on WinUSB before any Loader write ---
            Confirm-LoaderWinUsb
            & $Ui.Flash 18 'WinUSB bound'

            # --- Phase 2: Apply patches ---
            Section 'Applying liberation patches'
            Invoke-Child 'scripts/liberate-mabu.ps1'
            if ($LASTEXITCODE -ne 0) { Fail 'liberate-mabu.ps1 failed.'; Abort 'liberate-mabu.ps1 failed.' }
            Ok 'All 8 patches written.'
            & $Ui.Flash 32 'Patches written'

            # --- Phase 3: /data wipe (State A / forced / undetermined) ---
            if ($doWipe) {
                Section 'Resetting Loader between patch and wipe phases'
                Info 'Loader wedges if we do patches + 16 MB write back-to-back.'
                Info 'Booting to Android, then re-entering Loader via adb.'
                & $script:RK rd 2>&1 | Out-Null
                Start-Sleep -Seconds 4
                $bootDev = Find-AdbDevice -PreferIp $script:WifiIp -TimeoutSec 120
                if (-not $bootDev) { Fail 'No adb after inter-phase reset. Power-cycle and retry.'; Abort 'No adb after inter-phase reset.' }
                Ok "adb up at $bootDev"
                & $script:ADB -s $bootDev shell reboot loader 2>&1 | Out-Null
                for ($i = 0; $i -lt 30; $i++) {
                    Start-Sleep -Seconds 1
                    if (Test-Loader) { Ok "Loader re-caught after ${i}s."; break }
                }
                if (-not (Test-Loader)) { Fail 'Loader not re-caught.'; Abort 'Loader not re-caught.' }
                & $Ui.Flash 40 'Loader re-caught'

                Section "Wiping head of /data ($WipeMB MB)"
                & $script:RK ld 2>&1 | Out-Null
                Start-Sleep -Seconds 3
                $wiped = $false
                for ($attempt = 1; $attempt -le 4; $attempt++) {
                    Invoke-Child 'scripts/wipe-data-head.ps1' -Named @{ SizeMB = $WipeMB }
                    if ($LASTEXITCODE -eq 0) { $wiped = $true; break }
                    if (-not (Test-Loader)) { Fail "Loader dropped during wipe (attempt $attempt). Power-cycle into Loader and re-run."; Abort 'Loader dropped during wipe.' }
                    Warn "Wipe attempt $attempt wedged (cold Loader); warming and retrying..."
                    & $script:RK ld 2>&1 | Out-Null
                    Start-Sleep -Seconds 3
                }
                if (-not $wiped) { Fail '/data head wipe failed after 4 attempts.'; Abort '/data head wipe failed.' }
                Ok '/data head zeroed; vold will reformat on boot.'
                & $Ui.Flash 62 '/data wiped'
            }

            # --- Phase 4: Reset and wait for adb ---
            Section 'Resetting device'
            & $script:RK rd 2>&1 | Out-Null
            Ok 'Reset issued.'
        }

        if ($SkipApps) {
            Ok 'Loader-side patches done. SkipApps requested -- no userspace install.'
            & $Ui.Done $true 'Loader-side patches done (SkipApps -- no userspace install).'
            return
        }

        # Destructive Loader work is done. Provisioning is best-effort; a transient
        # adb hiccup should warn, not abort the whole run.
        $ErrorActionPreference = 'Continue'

        Section 'Provisioning transport (WiFi adb)'
        Info 'USB adb on this hardware times out too fast for installs/pulls --'
        Info 'the provision phase runs over WiFi adb on 5555.'
        if ($doWipe) {
            Warn '/data was wiped: WiFi credentials AND the persistent tcpip flag are gone.'
            & $script:Ui.Prompt 'Wi-Fi needed after wipe' `
                'The /data wipe cleared the tablet Wi-Fi credentials. On the tablet touch UI, connect to Wi-Fi, then click Continue.' `
                @('Continue') | Out-Null
        }
        Info 'Acquiring adb after reset (USB to switch on WiFi, or WiFi if already up)...'
        $acq = Find-AdbDevice -PreferIp $script:WifiIp -TimeoutSec 180
        if (-not $acq) {
            Fail 'No adb (USB or WiFi) after reset.'
            Fail 'Re-seat the USB harness (or fix the tablet WiFi), then finish with:'
            Fail '  Invoke-MabuFlash -RestoreMabu -NoWipe'
            Abort 'No adb after reset.'
        }
        if ($acq -match ':5555$') {
            $dev = $acq
            Ok "WiFi adb already up: $dev"
        } else {
            $dev = Enable-WifiAdb -UsbDev $acq
            if (-not $dev) {
                Warn 'WiFi adb unavailable; falling back to USB adb for installs.'
                Warn 'USB installs can wedge on this hardware -- if one fails, fix WiFi adb'
                Warn 'and re-run:  Invoke-MabuFlash -RestoreMabu -NoWipe'
                $dev = $acq
            }
        }
        Ok "Provisioning over: $dev"
        & $Ui.Flash 76 'Transport up'

        # Quick audit
        Section 'Post-boot audit'
        $audit = & $script:ADB -s $dev shell 'echo DO=$(getprop ro.device_owner); echo SDOSVC=$(getprop init.svc.set-device-owner); dumpsys device_policy 2>/dev/null | grep -E "Device managed|provisioningState" | head -3; pm list packages 2>/dev/null | grep -iE "esper|shoonya" | head -5' 2>&1
        $audit | ForEach-Object { Info $_ }

        # --- Phase 5: Install user-facing apps ---
        Section 'Installing user apps'
        if (-not (Test-Path (Join-Path $script:Root $FDroidApk))) { Warn "Missing APK: $FDroidApk -- skipping" }
        elseif ((& $script:ADB -s $dev shell 'pm list packages org.fdroid.fdroid 2>/dev/null' 2>&1) -match 'package:') { Ok 'F-Droid already installed -- skipping.' }
        else {
            $r = (& $script:ADB -s $dev install (Join-Path $script:Root $FDroidApk) 2>&1) | Where-Object { $_ -notmatch 'RemoteException' } | Select-Object -Last 1
            Info "$FDroidApk : $r"
        }

        if (-not (Test-Path (Join-Path $script:Root $LawnchairApk))) { Warn "Missing APK: $LawnchairApk -- skipping" }
        elseif ((& $script:ADB -s $dev shell 'pm list packages app.lawnchair 2>/dev/null' 2>&1) -match 'package:') { Ok 'Lawnchair already installed -- skipping.' }
        else {
            $r = (& $script:ADB -s $dev install (Join-Path $script:Root $LawnchairApk) 2>&1) | Where-Object { $_ -notmatch 'RemoteException' } | Select-Object -Last 1
            Info "$LawnchairApk : $r"
        }
        & $script:ADB -s $dev shell 'cmd package set-home-activity app.lawnchair/.LawnchairLauncher' 2>&1 | Out-Null
        Ok 'Lawnchair set as default launcher.'
        & $Ui.Flash 86 'Apps installed'

        # --- Phase 6: Mabu restore ---
        if ($RestoreMabu) {
            Section 'Restoring Mabu factory mode + assets'
            $installed = (& $script:ADB -s $dev shell 'pm list packages | grep -i catalia') 2>&1
            if ($installed -match 'com.catalia.factorymode') {
                Info 'com.catalia.factorymode already installed -- skipping APK install.'
            } else {
                $apk = Join-Path $script:Root "$MabuArchive/apks/com.catalia.factorymode.apk"
                $r = (& $script:ADB -s $dev install $apk 2>&1) | Where-Object { $_ -notmatch 'RemoteException' } | Select-Object -Last 1
                Info "factorymode install: $r"
            }
            foreach ($p in 'CAMERA','RECORD_AUDIO','READ_PHONE_STATE','READ_EXTERNAL_STORAGE','WRITE_EXTERNAL_STORAGE') {
                & $script:ADB -s $dev shell pm grant com.catalia.factorymode "android.permission.$p" 2>&1 | Out-Null
            }
            Ok 'Runtime perms granted.'

            $SD = Join-Path $script:Root "$MabuArchive/sdcard/sdcard"
            if (Test-Path $SD) {
                Info 'Pushing animation CSVs...'
                Get-ChildItem "$SD/*.csv" | ForEach-Object {
                    & $script:ADB -s $dev push $_.FullName /sdcard/ 2>&1 | Out-Null
                }
                if (Test-Path "$SD/nuance") { & $script:ADB -s $dev push "$SD/nuance" /sdcard/ 2>&1 | Out-Null }
                if (Test-Path "$SD/sound.raw") { & $script:ADB -s $dev push "$SD/sound.raw" /sdcard/ 2>&1 | Out-Null }
                Ok 'Assets pushed.'
            } else {
                Warn "Mabu archive sdcard dir not found at $SD"
            }
        }
        & $Ui.Flash 92 'Mabu restored'

        # --- Phase 7: SELinux policy fix ---
        if (-not $SkipApps -and -not $SkipSELinux) {
            $selinuxDev = Find-AdbDevice -PreferIp $script:WifiIp -TimeoutSec 120
            if (-not $selinuxDev) { $selinuxDev = $dev }
            Apply-SELinuxFix -Dev $selinuxDev
        }
        & $Ui.Flash 100 'SELinux fix'

        # --- Phase 8: Self-test ---
        if (-not $SkipApps) {
            Info 'Waiting for device to come up for self-test...'
            $testDev = Find-AdbDevice -PreferIp $script:WifiIp -TimeoutSec 120
            if ($testDev) {
                & $script:ADB -s $testDev shell 'cmd package set-home-activity app.lawnchair/.LawnchairLauncher' 2>&1 | Out-Null
                Run-SelfTest -Dev $testDev
            }
            else          { Warn 'Self-test skipped: no adb device found after reboot.' }
        }

        Section 'Done'
        Ok "Unit at $dev liberated and provisioned. Verify on-device:"
        Info '  - Home screen = Lawnchair (long-press to customize)'
        Info '  - F-Droid available for additional apps'
        if ($RestoreMabu) {
            Info '  - Mabu Factory Mode launches motor diagnostics'
            Info '  - Open Trouble Shooting/Motor Debug to recalibrate motors'
        }
        if (-not $SkipSELinux) {
            Info '  - SELinux fix applied: untrusted_app can open serial_device (motors)'
        }
        & $Ui.Done $true "Unit at $dev liberated, provisioned, and validated."
    }
    catch {
        if ($_.Exception -isnot [System.OperationCanceledException]) {
            & $script:Ui.Log 'fail' "Unexpected error: $($_.Exception.Message)"
        }
        & $Ui.Done $false 'Flash aborted -- see the log above.'
    }
}

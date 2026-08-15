<#
.SYNOPSIS
    Undo set-as-home.ps1: hand the home screen back to the normal launcher.

.DESCRIPTION
    Clears Signboard's preferred-activity registration and lists what is left,
    so you can confirm a real launcher (Lawnchair, on a unit flashed with the
    Mabu Flash Utility) has the home role again.

    Worth knowing: if Signboard is the ONLY home-capable app installed and you
    clear it, the device has no home screen. It will still boot, and ADB still
    works, so you can always recover with 'adb shell am start'. But do not
    uninstall your only launcher on a device you cannot reach.

.PARAMETER Ip
    The Mabu's IP address. Omit to use the already-connected device.
#>
[CmdletBinding()]
param([string] $Ip)

$ErrorActionPreference = 'Stop'

$Pkg = 'com.getcircuitbent.mabu.signboard'

if ($Ip) { & adb connect "${Ip}:5555" | Out-Host; $Serial = "${Ip}:5555" }
else {
    $Serial = (& adb devices | Select-String -Pattern '^\S+\s+device$' |
               Select-Object -First 1).ToString().Split()[0]
    if (-not $Serial) { throw 'No adb device. Pass -Ip <address>.' }
}

function Adb { & adb -s $Serial @args }

Write-Host '[*] Clearing preferred-activity registration' -ForegroundColor Cyan
Adb shell "pm clear-package-preferred-activities $Pkg" 2>&1 | Out-Host

Write-Host '[*] Home-capable apps now installed:' -ForegroundColor Cyan
Adb shell "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME" | Out-Host

Write-Host ''
Write-Host '[OK] Done. Press the home button on the tablet; you should get the' -ForegroundColor Green
Write-Host '     launcher chooser, or your normal launcher.' -ForegroundColor Green

<#
.SYNOPSIS
    Make Mabu Signboard the home launcher, so the robot boots straight into it.

.DESCRIPTION
    INDEX ROW 21, as an opt-in step rather than something the app does to you
    on install.

    A signboard usually wants to come up on its own after a power cut, with no
    laptop and nobody to tap anything. That means being the HOME activity.

    This is deliberately NOT in the manifest by default. An app that grabs HOME
    when you install it is an app you have to fight to get rid of, and a sample
    should never do that to someone evaluating it. Run this once you are happy
    the app works, and run unset-as-home.ps1 to undo it.

    HOW IT WORKS
    Android picks the HOME activity from whatever is registered for
    android.intent.category.HOME. Since the app does not declare it, this
    script uses the device-owner / preferred-activity mechanism instead:
    'cmd package set-home-activity' tells the package manager which of the
    installed home-capable apps to prefer.

    LIMITATION, READ THIS BEFORE RUNNING
    set-home-activity only chooses between apps that already declare the HOME
    category. Signboard does not, so on most units this will report that it
    cannot be set. To genuinely autostart, uncomment the HOME intent-filter in
    AndroidManifest.xml, rebuild, and then run this script.

    That is a deliberate two-step: making the robot boot into your app is a
    real decision about the device, so it takes an edit and a rebuild rather
    than one command you might run by accident.

.PARAMETER Ip
    The Mabu's IP address. Omit to use the already-connected device.
#>
[CmdletBinding()]
param([string] $Ip)

$ErrorActionPreference = 'Stop'

$Pkg      = 'com.getcircuitbent.mabu.signboard'
$Activity = "$Pkg/.MainActivity"

if ($Ip) { & adb connect "${Ip}:5555" | Out-Host; $Serial = "${Ip}:5555" }
else {
    $Serial = (& adb devices | Select-String -Pattern '^\S+\s+device$' |
               Select-Object -First 1).ToString().Split()[0]
    if (-not $Serial) { throw 'No adb device. Pass -Ip <address>.' }
}

function Adb { & adb -s $Serial @args }

Write-Host "[*] Current home activities:" -ForegroundColor Cyan
Adb shell "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME" | Out-Host

Write-Host "[*] Setting $Activity as home" -ForegroundColor Cyan
$result = Adb shell "cmd package set-home-activity $Activity" 2>&1
$result | Out-Host

if ($result -match 'Error|Failure|not found') {
    Write-Host ''
    Write-Host '[!] Could not set it. Almost certainly because the app does not' -ForegroundColor Yellow
    Write-Host '    declare android.intent.category.HOME. Uncomment that filter in' -ForegroundColor Yellow
    Write-Host '    app/src/main/AndroidManifest.xml, rebuild, reinstall, retry.' -ForegroundColor Yellow
} else {
    Write-Host ''
    Write-Host '[OK] Signboard is now the home app. It will start on boot.' -ForegroundColor Green
    Write-Host '     Undo with scripts/unset-as-home.ps1' -ForegroundColor Gray
}

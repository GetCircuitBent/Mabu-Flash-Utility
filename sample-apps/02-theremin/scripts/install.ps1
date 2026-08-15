<#
.SYNOPSIS
    Build, install and launch Mabu Theremin on a Mabu over Wi-Fi ADB.

.DESCRIPTION
    Does the whole sequence, in the order that actually works:

      1. Connect over Wi-Fi ADB.
      2. Free the serial port by stopping anything else that might own it.
      3. Force-stop this app BEFORE installing over it. This one matters:
         'install -r' on a live process leaves the old code running, and the
         subsequent 'am start' merely resumes it, so your new APK silently
         does not load and you debug a change that was never on the device.
      4. Build and install.
      5. Pre-grant the storage permission and create /sdcard/theremin/.
      6. Launch, and optionally tail the logs.

.PARAMETER Ip
    The Mabu's IP address. Omit to use whatever device adb already has.
    Find it on the app's admin screen, in your router's DHCP table, or with
    'nmap -p 5555 192.168.0.0/24'.

.PARAMETER NoBuild
    Install the existing APK without rebuilding.

.PARAMETER Logcat
    Tail the app's logs after launching. Ctrl-C to stop.

.EXAMPLE
    ./scripts/install.ps1 -Ip 192.168.0.180 -Logcat
#>
[CmdletBinding()]
param(
    [string] $Ip,
    [switch] $NoBuild,
    [switch] $Logcat
)

$ErrorActionPreference = 'Stop'

$Pkg      = 'com.getcircuitbent.mabu.theremin'
$Activity = "$Pkg/.MainActivity"
$Apk      = Join-Path $PSScriptRoot '..\app\build\outputs\apk\debug\app-debug.apk'
$ProjDir  = Join-Path $PSScriptRoot '..'

# Apps known to hold /dev/ttyS1. Only one process can usefully own the port,
# and factorymode ships on every flashed unit with a boot receiver.
$PortHogs = @('com.catalia.factorymode')

function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }

# --- 1. Connect ------------------------------------------------------------
if ($Ip) {
    Info "Connecting to ${Ip}:5555"
    & adb connect "${Ip}:5555" | Out-Host
    $Serial = "${Ip}:5555"
} else {
    $Serial = (& adb devices | Select-String -Pattern '^\S+\s+device$' |
               Select-Object -First 1).ToString().Split()[0]
    if (-not $Serial) {
        throw "No adb device. Pass -Ip <address>, or check the unit is on Wi-Fi."
    }
    Info "Using already-connected device $Serial"
}

function Adb { & adb -s $Serial @args }

# --- 2. Free the serial port ----------------------------------------------
foreach ($hog in $PortHogs) {
    Adb shell am force-stop $hog 2>$null | Out-Null
}
Info "Stopped known holders of /dev/ttyS1"

# --- 3. Stop our own app before installing over it -------------------------
Adb shell am force-stop $Pkg 2>$null | Out-Null

# --- 4. Build and install --------------------------------------------------
if (-not $NoBuild) {
    Info 'Building debug APK'
    Push-Location $ProjDir
    try {
        & .\gradlew.bat assembleDebug | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Gradle build failed.' }
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path $Apk)) { throw "APK not found at $Apk. Build first (drop -NoBuild)." }

Info 'Installing'
# -r replace, -d allow downgrade (so a rebuild with the same versionCode
# always lands, which it will while you are iterating).
Adb install -r -d $Apk | Out-Host

# --- 5. Permissions and the media directory --------------------------------
# Pre-granting means the app never has to show a permission dialog, which
# matters on a device you may be driving entirely over ADB.
Adb shell pm grant $Pkg android.permission.CAMERA 2>$null | Out-Null
Adb shell pm grant $Pkg android.permission.READ_EXTERNAL_STORAGE 2>$null | Out-Null
# RECORD_AUDIO is deliberately NOT granted: the recorder add-on is opt-in and
# the permission is commented out in the manifest. See SampleRecorder.kt.
Adb shell mkdir -p /sdcard/theremin 2>$null | Out-Null
Ok 'Permission granted, /sdcard/theremin ready'

# --- 6. Launch -------------------------------------------------------------
Info 'Launching'
Adb shell am start -n $Activity | Out-Host
Ok 'Running'

Write-Host ''
Write-Host 'Drop your own sample onto the device with:' -ForegroundColor Gray
Write-Host '  adb push mysample.wav /sdcard/theremin/   (16-bit WAV)' -ForegroundColor Gray
Write-Host ''

if ($Logcat) {
    Info 'Tailing logs (Ctrl-C to stop)'
    Adb logcat -c
    Adb logcat MabuSerial:* MabuTween:* MabuIdle:* MabuCamera:* MabuFace:* MabuTone:* MabuAudio:* MabuControl:* AndroidRuntime:E '*:S'
}

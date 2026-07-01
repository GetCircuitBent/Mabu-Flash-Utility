# Mabu Android Build Guide

> **Reference for building and deploying Android apps to Mabu.**
> Covers the build environment, Gradle workflow, deployment, app lifecycle quirks,
> remote control via ADB, and all known gotchas for this unit.

---

## 1. Environment

### Device Facts
- **Android 8.1.0 (API 27)**: many newer Android APIs are unavailable
- **Build type:** `user` (not `userdebug`); `adb root` fails
- **ADB connection:** WiFi only at `192.168.0.180:5555`; no USB, no physical buttons
- **ADB path (PC):** `X:\Claude\android platform-tools\adb.exe`

### Build Environment (PC)
- **Java:** `C:\Program Files\Android\Android Studio\jbr`
- **Gradle wrapper:** `./gradlew` in project root
- **Active project:** `X:\Claude\Mabu\facetrackadb\` (package `com.mabu.facetrackadb`)
- **Legacy project:** `X:\Claude\Mabu\MabuFaceTrack\` (package `com.mabu.facetrack`, TCP-bridge era, kept for reference)

### Setting JAVA_HOME for Gradle
The system `JAVA_HOME` is not set. Always prefix Gradle calls with the JBR path:
```bash
JAVA_HOME="C:/Program Files/Android/Android Studio/jbr" ./gradlew assembleDebug
```
Or in PowerShell from the project directory:
```powershell
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
.\gradlew assembleDebug
```

---

## 2. Build

```powershell
cd X:\Claude\Mabu\facetrackadb
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
.\gradlew.bat assembleDebug
```

Output APK: `app\build\outputs\apk\debug\app-debug.apk`

First build (~2 min) compiles the native `libmabuserial.so` (armeabi-v7a) via CMake/NDK.
Incremental builds (Kotlin-only changes) take ~3–5s; CMake is skipped if `serial.c` is unchanged.

---

## 3. Install and Deploy

```powershell
$adb = "X:\Claude\android platform-tools\adb.exe"
& $adb install -r "X:\Claude\Mabu\facetrackadb\app\build\outputs\apk\debug\app-debug.apk"
```

`-r` = reinstall over existing app. **No bridge setup required**: `facetrackadb` opens
`/dev/ttyS1` directly via JNI and self-initializes motors on startup.

### After Install: Restart the App

```powershell
$adb = "X:\Claude\android platform-tools\adb.exe"
& $adb shell "am force-stop com.mabu.facetrackadb"
Start-Sleep -Seconds 1
& $adb shell "am start -n com.mabu.facetrackadb/.MainActivity"
```

The app opens `/dev/ttyS1` in its `MabuMotors.open()` call, sends the 5× cold-boot
wake-up, and centers all motors. Expect ~2s before motors move.

### Full Deploy Sequence (Copy-Paste)

```powershell
$adb = "X:\Claude\android platform-tools\adb.exe"
& $adb install -r "X:\Claude\Mabu\facetrackadb\app\build\outputs\apk\debug\app-debug.apk"
Start-Sleep -Seconds 1
& $adb shell "am force-stop com.mabu.facetrackadb"
Start-Sleep -Seconds 1
& $adb shell "am start -n com.mabu.facetrackadb/.MainActivity"
# Watch logcat to confirm: "Native serial opened fd=XX" then "Motors initialized via native serial"
& $adb logcat -s MabuSerial:I MabuMotors:I AndroidRuntime:E
```

---

## 4. App Lifecycle Quirks

### The Home Launcher
`com.mabu.facetrackadb` **is** the Android HOME launcher; it auto-starts on every boot
and relaunches after force-stop. After `am force-stop`, wait ~2s for the launcher to
restart before sending further commands.

### No Bridge Dependency
`facetrackadb` opens `/dev/ttyS1` via JNI directly. There is no `motor-bridge.sh` process
to worry about. Force-stop and restart are clean.

### NEVER Reboot via `adb reboot`
Running `adb reboot` has caused WiFi to not reconnect after boot on this unit, leaving the
device permanently unreachable (no USB, no physical buttons). **Always ask the user to
power-cycle the hardware instead.**

---

## 5. Remote Control via ADB Broadcast

The app registers a `BroadcastReceiver` for `com.mabu.facetrackadb.PAUSE_TRACKING`.
This is the primary way to stop motor output from the PC during testing.

### Pause Face Tracking (Motors Hold Last Position)
```powershell
& "X:\Claude\android platform-tools\adb.exe" shell "am broadcast -a com.mabu.facetrackadb.PAUSE_TRACKING --ez paused true -p com.mabu.facetrackadb"
```

### Resume Face Tracking
```powershell
& "X:\Claude\android platform-tools\adb.exe" shell "am broadcast -a com.mabu.facetrackadb.PAUSE_TRACKING --ez paused false -p com.mabu.facetrackadb"
```

When paused, the overlay shows `*** TRACKING PAUSED ***`. When resumed it shows `tracking active`.

### Verify the Broadcast Was Received
```powershell
& "X:\Claude\android platform-tools\adb.exe" logcat -d -s MabuFaceTrack:I
```
Look for: `I MabuFaceTrack: trackingPaused=true`

---

## 6. Logcat

```powershell
# All MabuFaceTrack logs (verbose)
& "X:\Claude\android platform-tools\adb.exe" shell "logcat -d MabuFaceTrack:D *:S"

# INFO and above only (startup events, broadcasts)
& "X:\Claude\android platform-tools\adb.exe" shell "logcat -d MabuFaceTrack:I *:S"

# Crash logs
& "X:\Claude\android platform-tools\adb.exe" shell "logcat -d MabuFaceTrack:V AndroidRuntime:E *:S"
```

**NEVER run `logcat -c` (clear logcat) on this unit.** It causes ADB to go offline and requires a reconnect.

---

## 7. Known API 27 (Android 8.1) Gotchas

### `RECEIVER_EXPORTED` / `RECEIVER_NOT_EXPORTED` Do Not Exist
These `Context` constants were added in API 33. On this device (API 27), calling
`registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)` will silently fail
(the 3-argument form with flags doesn't exist in API 27).

**Fix:** Use the 2-argument form:
```kotlin
@Suppress("UnspecifiedRegisterReceiverFlag")
registerReceiver(receiver, IntentFilter("your.action"))
```

### Background Broadcast Restrictions (Android 8+)
Apps in the background cannot receive implicit broadcasts registered in the manifest.
Dynamically registered receivers (in `onCreate`) still work while the app is in the
foreground. Since `com.mabu.facetrack` is the HOME launcher it is always in the foreground.

### Camera: Use Camera1 API Only
Mabu's camera HAL is a Camera1 shim. CameraX fails on this hardware. Use `Camera1Source.kt`.

### SELinux and Serial Port Access
SELinux denies `getattr` for `untrusted_app → serial_device`, but allows `open/read/write`.
Java `FileOutputStream` calls `stat()` first (needs `getattr`) and fails. Native C `open()`
bypasses `stat()` and succeeds. **Use JNI (`serial.c`); never Java I/O for `/dev/ttyS1`.**
The TCP motor bridge workaround is no longer needed. See `MABU_MOTOR_GUIDE.md` Section 9.

---

## 8. ADB Connection Management

```powershell
# Connect
& "X:\Claude\android platform-tools\adb.exe" connect 192.168.0.180:5555

# If device goes offline (happens after some logcat commands)
& "X:\Claude\android platform-tools\adb.exe" disconnect 192.168.0.180:5555
Start-Sleep -Seconds 3
& "X:\Claude\android platform-tools\adb.exe" connect 192.168.0.180:5555

# Check device is connected
& "X:\Claude\android platform-tools\adb.exe" devices
```

WiFi ADB sometimes enters power-save and stops responding. The disconnect/reconnect
cycle wakes it up without requiring a reboot.

---

## 9. Manual Motor Testing Workflow

When testing motor positions manually (sending raw frames from PowerShell), tracking
must be paused to prevent the app fighting your commands:

```powershell
$adb = "X:\Claude\android platform-tools\adb.exe"

# 1. Pause tracking
& $adb shell "am broadcast -a com.mabu.facetrackadb.PAUSE_TRACKING --ez paused true -p com.mabu.facetrackadb"

# 2. Send your motor test commands (see MABU_MOTOR_GUIDE.md)
# ...

# 3. Resume when done
& $adb shell "am broadcast -a com.mabu.facetrackadb.PAUSE_TRACKING --ez paused false -p com.mabu.facetrackadb"
```

The overlay will confirm the state. Motors hold their last commanded position while paused.

---

## 10. Telemetry Capture (logcat)

Capture motor and face-tracking telemetry to a file for offline analysis:

```powershell
$adb = "X:\Claude\android platform-tools\adb.exe"
$out = "X:\Claude\Mabu\telemetry\session_YYMMDDx.log"

# Start capture in background (runs until killed)
$job = Start-Job { & $using:adb shell "logcat -s MabuFaceTrack:D -v time 2>&1" | Out-File $using:out -Encoding utf8 }

# ... let it run for 2 minutes ...

# Stop capture
Get-Process adb | Sort-Object StartTime | Select-Object -Last 1 | Stop-Process -Force

# Analyse: count IoU match events and reversal rates
$lines = Get-Content $out
($lines | Select-String "IoU match:").Count        # ML Kit ID swaps absorbed without freeze
($lines | Select-String "new face ID").Count        # genuine new face acquisitions (slew fired)
```

Key log lines to watch:
- `IoU match: ID X -> Y (IoU=0.xx, no hysteresis)`: same face, ML Kit changed ID, no motor freeze
- `new face ID N confirmed (IoU=0.00, slew 10f)`: genuine new face, slew window fired
- `perf n=50 inference avg=...`: HAL and inference timing (every ~5s)
- `hal n=50 arrival avg=...`: camera HAL cadence (should be ~100ms / 10fps)

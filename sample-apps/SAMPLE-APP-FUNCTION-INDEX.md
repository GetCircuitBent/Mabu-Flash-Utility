# Sample App Function Index

Every Mabu capability we have driven on real hardware, in the order a new
developer should meet them. Each row is a function a sample app should cover.
The **Sample App** column links to the app that demonstrates it once that app
exists; `TBD` means nothing covers it yet.

This index is the map. The sample apps are the territory: small, heavily
commented, copy-pasteable Android projects that sit alongside the
[Mabu Flash Utility](../README.md) for people who have just freed a unit and
want to make it do something.

**In progress:** [Sample App 1: Mabu Signboard](01-signboard/SPEC.md), covering
Tier 0, Tier 1 and Tier 4.

## Conventions for Every Sample App

- **One scrolling page.** All demos live on a single scrolling screen, section
  by section, in the order of this index. No tabs, no nested navigation, no
  hunting through a file tree to find the bit you want.
- **Comments over cleverness.** Assume the reader knows Android but has never
  seen a Mabu. Every constant that came from hardware testing says so.
- **Copy-paste units.** A section's code should survive being lifted out on its
  own, without dragging in a framework.
- **Per-unit calibration is called out, not hidden.** Motor polarity and
  neutrals differ between units. Anything unit-specific gets a comment saying
  "recalibrate this on your unit".

Protocol details behind these rows live in
[MABU_MOTOR_GUIDE.md](../guides/MABU_MOTOR_GUIDE.md).

## Tier 0: Foundation

Everything else depends on these five. A sample app that covers Tier 0 and
nothing else is still useful.

| # | Function | What the Sample Must Show | Sample App |
|---|---|---|---|
| 1 | Open the serial link | Native JNI `open("/dev/ttyS1", O_RDWR\|O_NOCTTY)` at 57600 8N1. Java `FileOutputStream` **always** fails here: Java calls `stat()` first and SELinux denies `getattr` to `untrusted_app`. Native `open()` skips the `stat()` and succeeds. Ship `serial.c` plus the Kotlin shim. | TBD |
| 2 | Build a frame | `FA 00 <len> <payload> <s2> <s1>`, Fletcher-8 **mod 255** over the whole frame including the `FA 00` header. Include the rounding trap: `50 * 2.55` is 127.499 in IEEE 754, so round-half-up gives 127, not 128. Assert `wire(50) == 0x80`. | TBD |
| 3 | Wake the motor board | Power-on frame `FA 00 02 4F 7F 0B CB` five times at 200 ms spacing, then wait 1 s, all on one open fd. A single power-on after a cold boot is silently ignored. This is the number one cause of "my motors do nothing". | TBD |
| 4 | Motor map, neutrals, ranges, directions | The seven motors (LDL, LDR, ELR, EUD, NE, NR, NT) as live constants with their bitmasks, neutral values, soft limits, and which way each one moves. Includes the per-unit sign flips (EUD inverted, eyelid scale, neck rotation). | TBD |
| 5 | Send a move | Single-motor and atomic seven-motor frames. A wrong bitmask is discarded silently by the board: no error, no movement, no clue. Values are listed in MSB-first bitmask order. | TBD |

## Tier 1: Motion

| # | Function | What the Sample Must Show | Sample App |
|---|---|---|---|
| 6 | Manual slider panel | Seven sliders, one per motor, driving live. The "hello world" of Mabu, and the tool you use to calibrate a new unit. | TBD |
| 7 | Named poses | Neutral, rest, sleep, look left / right / up / down. Composing a whole pose into one frame. | TBD |
| 8 | Blink and wink | The simplest timed sequence: close, hold, open. Introduces the sequencer pattern. | TBD |
| 9 | Gestures | Nod yes, shake no, head tilt, look away. Keyframe list plus interpolation. | TBD |
| 10 | Smooth motion architecture | The decoupled tween: detection or input writes targets only, a dedicated 25 Hz thread low-pass filters toward them and owns all serial I/O, and a send-side deadband drops frames that would not move a servo. Without this the servos audibly rattle. | TBD |
| 11 | Read motor telemetry | The board talks back: idle heartbeat `FA 00 01 00 ED FB` versus position reports `FA 00 09 01 00 <7 bytes>`. A camera-free way to confirm a move landed. Needs a `readBytes()` added to the JNI shim (so far we have only ever read from an adb shell). Warning belongs here: never open `/dev/ttyS1` from adb while an app holds it, because termios is shared and you will clobber the app's settings. | TBD |

## Tier 2: Sensing

| # | Function | What the Sample Must Show | Sample App |
|---|---|---|---|
| 12 | Camera preview | Camera1 API at 320x240. CameraX and Camera2 do not work: the HAL is a Camera1 shim. The camera advertises 24 fps and delivers 10; that ceiling is hardware and no userland change lifts it. | TBD |
| 13 | Face detection | ML Kit bundled face detector with a bounding-box overlay. It is the only current vision library still shipping `armeabi-v7a` that does not need Play Services, which matters because a freed Mabu has no Google services. `PERFORMANCE_MODE_FAST`, roughly 35 ms per frame. | TBD |
| 14 | Face following | Face position mapped to eye and neck targets: eye / neck coordination thresholds, fixation deadzones, edge-clip freeze, and a face-loss grace period that drifts back to neutral instead of snapping. | TBD |
| 15 | Puppet mirroring | Head yaw / pitch / roll driving the neck, eye-open probability driving the eyelids. A second, very different use of the same detector. | TBD |

## Tier 3: Audio

| # | Function | What the Sample Must Show | Sample App |
|---|---|---|---|
| 16 | Speak | Android `TextToSpeech`. Volume has to go through `STREAM_MUSIC` because the bundled Pico engine ignores its own volume parameter, and the Mabu has no physical volume rocker, so an on-screen control is not optional. | TBD |
| 17 | Listen | `AudioRecord` at 16 kHz mono int16 with a level meter. The raw capture path every speech-recognition option sits on top of. | TBD |
| 18 | Play audio | `AudioTrack` PCM playback. What every remote or streaming voice path feeds into. | TBD |

## Tier 4: Device and Integration

| # | Function | What the Sample Must Show | Sample App |
|---|---|---|---|
| 19 | Device status | Battery percentage and temperature from `ACTION_BATTERY_CHANGED`, uptime, and the current IP address. The IP matters because Wi-Fi ADB is the only way onto the device. | TBD |
| 20 | Control over ADB | A `BroadcastReceiver` that lets you drive the app headlessly from a PC. Broadcasts must target the package (`-p com.example.app`) or Android 8.0 and up drops them. Makes the whole sample scriptable. | TBD |
| 21 | Autostart as the home launcher | How your app becomes the thing the robot boots into. Includes the rule that only one process may hold `/dev/ttyS1`, so whatever launcher is already installed has to be stopped first. | TBD |
| 22 | Build and deploy | `minSdk 24`, `targetSdk 28`, `compileSdk 34`, `abiFilters = ["armeabi-v7a"]`, an install script that goes over Wi-Fi ADB, and pre-granting runtime permissions with `pm grant`. | TBD |
| 23 | Safety card | Short and prominent. Never run `adb reboot` (it has left units with no Wi-Fi and no recovery path). One owner of the serial port at a time. The limp-versus-stiff test for diagnosing a dead motor board, and the two stuck states with their different recovery paths. | TBD |
| 24 | Display media full-screen | Stills and animated GIF on the 1024x600 panel: immersive mode, keep-screen-on, fit modes, and playback rate. GIF goes through `android.graphics.Movie`, which is deprecated at API 28 but alive at 27 and needs no library. Its manual `setTime()` clock gives exact rate control for free. | TBD |
| 25 | Play video | Looping video on the panel. `MediaPlayer` with `setLooping`. RK3288 has hardware H.264 decode, but the codec set beyond H.264/MP4 is unverified and `setPlaybackParams` is frequently ignored or throws on embedded decoders, so this needs its own hardware pass. Deliberately held out of sample 1. | TBD |

## Deliberately Out of Scope

Not because they are uninteresting, but because we do not understand them well
enough to teach them yet.

| Area | Why Not |
|---|---|
| CSV animation playback | The bundled `/sdcard/*.csv` format is decoded (`Time(ms), MCB1, MCB2, DATA1, DATA2`), but the original playback path in `libsercomm.so` has never been confirmed, so we cannot say what the four channels actually drive. |
| LEDs, screen brightness, GPIO | The `gpio_control` interface is Catalia-custom and root-only. No sample can use it on a stock freed unit. |
| Anything requiring root | Root is a separate, still-in-progress track. Samples target a normally flashed unit. |
| NDI, RTP-MIDI, on-device LLM, WebRTC voice | All working in other projects, none of it basic. These belong in their own showcase, not a first sample. |

## Getting Started

Everything you need to get a sample app off your PC and onto a Mabu, plus the
handful of rules that keep the unit recoverable. This covers rows 20, 22 and 23,
and the parts of row 21 you cannot avoid. Read the [safety rules](#safety-rules)
before your first run; two of them can leave a unit unreachable.

### Before You Start

You need a unit that has already been through the
[Mabu Flash Utility](../README.md). A stock, Esper-locked Mabu will not accept
an app install and its ADB is suppressed. Flash first, then come back here.

You also need the Mabu and your PC **on the same Wi-Fi network**, with client
isolation off. Wi-Fi ADB on port 5555 is the only way onto the device once it is
buttoned up: there is no external USB port, and the programming harness only
plugs into an internal header.

### Step 1: Connect over Wi-Fi ADB

Find the tablet's IP address. In order of least effort:

1. The flasher prints it in the self-check summary at the end of a flash.
2. Your router's DHCP client table.
3. Scan the subnet: `nmap -p 5555 192.168.0.0/24` (adjust to your subnet).

Then connect:

```powershell
adb connect 192.168.0.180:5555
adb devices
```

A flashed unit's ADB is **already authorized**: the liberation patches remove
the authorization requirement from `adbd`, so there is no "Allow USB debugging
from this computer?" dialog to tap. If `adb devices` reports `unauthorized`
anyway, the unit is not fully flashed. Re-run the flasher.

**If nothing is listening on 5555.** The flasher sets
`persist.adb.tcp.port 5555` so the listener survives reboots, but two things
undo that: a `/data` wipe clears the property along with the Wi-Fi credentials,
and the patched `adbd` does not auto-listen on every unit. Re-enable it over the
USB harness:

```powershell
adb tcpip 5555
adb shell setprop persist.adb.tcp.port 5555
```

**If the connection drops mid-session.** Common and harmless. The usual causes
are the screen going to sleep or the robot physically moving and losing its
signal. Reconnect, and expect to try more than once:

```powershell
adb disconnect 192.168.0.180:5555
adb connect 192.168.0.180:5555
```

### Step 2: Set Up the Build Toolchain

Install **JDK 17**, the **Android SDK** with platform 28 and build-tools 34, and
**Gradle 8.4**. Android Studio bundles all three and is the easy path. A
portable, no-admin layout works equally well:

```
C:\Users\<you>\Tools\jdk-17\
C:\Users\<you>\Tools\android-sdk\
C:\Users\<you>\Tools\gradle-8.4\
```

Point the build at the SDK by setting `sdk.dir` in each sample's
`local.properties` (gitignored, so you create it once per clone).

Every sample pins the same four values, and all four matter on this hardware:

| Setting | Value | Why |
|---|---|---|
| `minSdk` | 24 | The Mabu is API 27. Anything higher than 27 will not install. |
| `targetSdk` | 28 | Keeps you out of the API 29+ scoped-storage and background-camera restrictions, which the samples do not need and which break the camera path. |
| `compileSdk` | 34 | Required by current AndroidX and ML Kit. Harmless at runtime. |
| `abiFilters` | `["armeabi-v7a"]` | The RK3288 is 32-bit ARMv7 only. An arm64 native library will not load, and shipping both just bloats the APK. |

### Step 3: Install and Launch

Each sample ships an `install.ps1` that does the whole sequence. Run it:

```powershell
./scripts/install.ps1 -Ip 192.168.0.180 -Logcat
```

What it does, and what to do by hand if you would rather:

```powershell
# 1. Free the serial port. Only ONE process may hold /dev/ttyS1 at a time, and
#    whatever is currently the home launcher may be holding it. See row 21.
adb shell am force-stop com.example.otherapp

# 2. Force-stop the sample itself BEFORE installing over it. `install -r` on a
#    live process leaves the old code running, and `am start` then merely
#    resumes it, so your new APK silently does not load.
adb shell am force-stop com.example.sample

# 3. Build and install.
./gradlew.bat assembleDebug
adb install -r -d app/build/outputs/apk/debug/app-debug.apk

# 4. Pre-grant runtime permissions so the app does not have to prompt.
#    Grant only what the sample declares.
adb shell pm grant com.example.sample android.permission.CAMERA
adb shell pm grant com.example.sample android.permission.RECORD_AUDIO
adb shell pm grant com.example.sample android.permission.READ_EXTERNAL_STORAGE

# 5. Launch.
adb shell am start -n com.example.sample/.MainActivity
```

With more than one device connected, set `ANDROID_SERIAL` (for example
`$env:ANDROID_SERIAL = '192.168.0.180:5555'`) so Gradle and ADB agree on which
one they are talking to.

### Step 4: Watch It Work

```powershell
# Tag-filtered logs. Every sample logs its serial link under MabuSerial.
adb logcat -c
adb logcat MabuSerial:* MabuSample:* AndroidRuntime:E '*:S'

# Screenshot, for when you are not next to the robot.
adb shell screencap -p /sdcard/shot.png
adb pull /sdcard/shot.png
```

### Driving a Sample Headlessly

Every sample registers a `BroadcastReceiver` so you can drive it from the PC
without touching the screen. This is how you script demos, and how you test a
change without walking over to the robot.

```powershell
adb shell "am broadcast -a com.example.sample.POSE -p com.example.sample --es pose neutral"
adb shell "am broadcast -a com.example.sample.MOVE -p com.example.sample --es motor NR --ef value 80"
adb shell "am broadcast -a com.example.sample.STOP -p com.example.sample"
```

**The `-p <package>` is not optional.** Android 8.0 and up drops implicit
broadcasts to manifest-registered receivers. Without it the command reports
success and nothing happens, which is a genuinely confusing way to lose an hour.

Extras use typed flags: `--es` for a string, `--ei` for an int, `--ef` for a
float, `--ez` for a boolean.

### Safety Rules

Five rules. The first two exist because breaking them has cost real units real
downtime.

1. **Never run `adb reboot`.** It has left units that came back up without
   Wi-Fi, and with no external USB port and no physical buttons, that means no
   way in short of opening the case and attaching the harness. If you genuinely
   need a reboot, power-cycle the hardware physically.

2. **One owner of `/dev/ttyS1` at a time.** In particular, do not open the
   serial port from an adb shell while an app is holding it. `termios` settings
   are shared across every file description on a character device, so a
   `busybox stty` from your shell overwrites the baud rate the app configured.
   The motors go silent and the only fix is to force-stop and restart the app.
   Read logcat instead while an app is running.

3. **Wake the board once per power cycle.** After a cold boot the motor board
   ignores a single power-on frame. Send it five times at 200 ms intervals, wait
   1 second, then send your first move, all on one open file descriptor. Row 3
   covers this. It is not optional and it is not superstition.

4. **Diagnose a dead board before rewriting code.** Gently push the head with a
   finger. **Limp** means the motor board is unpowered, which is a wiring or
   power fault and no amount of software will fix it. **Stiff** means the board
   is powered and holding position, so the problem is in the protocol, the wake
   sequence, or the port ownership. See the troubleshooting section of
   [MABU_MOTOR_GUIDE.md](../guides/MABU_MOTOR_GUIDE.md) for reading telemetry to
   tell the two stuck states apart, since they have different recovery paths.

5. **Suspect the factory app on a fresh boot.** `com.catalia.factorymode` ships
   with `RECEIVE_BOOT_COMPLETED` and references `/dev/ttyS1`. It is the leading
   suspect for a board that is stiff and streaming a heartbeat but ignoring
   every command right after boot. If that is what you are seeing, force-stop it
   and redo the wake sequence before assuming your frames are wrong. Not yet
   confirmed, but it costs nothing to rule out.

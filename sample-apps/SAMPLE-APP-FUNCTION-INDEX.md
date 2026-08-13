# Sample App Function Index

Every Mabu capability we have driven on real hardware, in the order a new
developer should meet them. Each row is a function a sample app should cover.
The **Sample App** column links to the app that demonstrates it once that app
exists; `TBD` means nothing covers it yet.

This index is the map. The sample apps are the territory: small, heavily
commented, copy-pasteable Android projects that sit alongside the
[Mabu Flash Utility](../README.md) for people who have just freed a unit and
want to make it do something.

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

## Deliberately Out of Scope

Not because they are uninteresting, but because we do not understand them well
enough to teach them yet.

| Area | Why Not |
|---|---|
| CSV animation playback | The bundled `/sdcard/*.csv` format is decoded (`Time(ms), MCB1, MCB2, DATA1, DATA2`), but the original playback path in `libsercomm.so` has never been confirmed, so we cannot say what the four channels actually drive. |
| LEDs, screen brightness, GPIO | The `gpio_control` interface is Catalia-custom and root-only. No sample can use it on a stock freed unit. |
| Anything requiring root | Root is a separate, still-in-progress track. Samples target a normally flashed unit. |
| NDI, RTP-MIDI, on-device LLM, WebRTC voice | All working in other projects, none of it basic. These belong in their own showcase, not a first sample. |

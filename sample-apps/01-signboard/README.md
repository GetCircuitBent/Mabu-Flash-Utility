# Mabu Signboard

The first Mabu sample app. Mabu as a living sign: a still image or looping
animation on the screen while the body keeps moving on its own.

It is also the app to read first. It covers the whole motor stack, from
opening the serial port to scripting gestures, with no camera and no audio in
the way. Every file is commented for someone who knows Android but has never
seen a Mabu.

Covers 16 of the 25 rows in the
[Sample App Function Index](../SAMPLE-APP-FUNCTION-INDEX.md): all of Tier 0
(foundation), all of Tier 1 (motion) except telemetry readback, and all of
Tier 4 (device and integration).

## Before You Start

You need a Mabu that has already been through the
[Mabu Flash Utility](../../README.md), and the Mabu and your PC on the same
Wi-Fi network. See
[Getting Started](../SAMPLE-APP-FUNCTION-INDEX.md#getting-started) in the index
for connecting over Wi-Fi ADB and setting up the build toolchain.

Then:

```powershell
./scripts/install.ps1 -Ip 192.168.0.180 -Logcat
```

That builds, frees the serial port, installs, grants the storage permission,
creates `/sdcard/signboard/`, launches, and tails the logs. Or open this
directory in Android Studio and press Run.

## What You Get

**The admin page** is one scrolling screen with everything on it:

| Section | What it does |
|---|---|
| Header | Serial link state, battery, temperature, uptime, IP address, frames sent |
| Idle | The master toggle plus six sliders that tune the idle behaviour live |
| Motors | All seven motors on sliders, with a hint under each saying which way is which |
| Poses | Neutral, Alert, Sleep, and the four look directions |
| Gestures | Blink, double blink, wink, nod, shake, tilt, look away, scan |
| The Sign | Pick media, choose a fit mode, set the GIF rate, and show it |
| Reference | The safety rules and the ADB command list, on the device where you need them |

**Show mode** is the sign full-screen. Double-tap anywhere to come back. A
single tap deliberately does nothing, so brushing the panel cannot change
anything.

The robot keeps moving the whole time. Show mode does not touch the motors at
all: the motion engine runs on its own thread and does not know the UI exists.

## Changing the Sign

Three ways, easiest first.

**Drop a file on the device.** Any PNG, JPEG, WebP or GIF:

```powershell
adb push mysign.gif /sdcard/signboard/
```

Then tap **From /sdcard** on the admin page. Pressing it again cycles through
everything in that directory.

**Swap it remotely** while the app is running, without touching the robot:

```powershell
adb shell "am broadcast -a com.getcircuitbent.mabu.signboard.SET_MEDIA -p com.getcircuitbent.mabu.signboard --es path /sdcard/signboard/promo.gif --ef rate 0.75"
```

**Bundle your own default.** Replace `app/src/main/assets/gcb-sign.png` (or
the `.gif`) and rebuild.

### What It Can Display

| Format | Notes |
|---|---|
| PNG, JPEG, WebP | Stills |
| GIF | Animated, looping, with adjustable playback rate |

The panel is **1024x600, landscape, 30 Hz**. Author at that size to fill it
exactly. Anything else is scaled by the fit mode, and the aspect ratio is
never distorted.

**Contain** shows the whole image, letterboxed. **Cover** fills the screen and
crops the edges. The bundled Get Circuit Bent brand assets are 700x438, so the
difference is visible on them straight away.

**Rate** applies to GIFs. 1.0 is as authored, 0.5 is half speed, 2.0 is
double, and 0 freezes on a frame. This works because the GIF decoder does not
run its own clock: the app tells it which frame to show on every draw. See the
comments in [SignView.kt](app/src/main/java/com/getcircuitbent/mabu/signboard/SignView.kt).

**Video is not supported**, on purpose. It needs a media surface, codec
verification this hardware has not had, and a playback-rate API that embedded
decoders often ignore. It is row 25 of the index and belongs in its own
sample.

## Writing Your Own Gestures

This is the part most people will want. A gesture is a list of steps read like
a storyboard, in
[Gestures.kt](app/src/main/java/com/getcircuitbent/mabu/signboard/Gestures.kt):

```kotlin
val NOD_YES = gesture("Nod Yes") {
    step(NE to 62f, overMs = 250)   // chin up
    step(NE to 38f, overMs = 350)   // chin down, slower: gravity reads as weight
    step(NE to 50f, overMs = 250)   // back to level
    hold(120)                       // a beat before whatever comes next
}
```

To add one: write it, add it to `Gestures.ALL`, and stop. The admin buttons and
the ADB command both come from that list. Add it to `Gestures.IDLE_POOL` as
well if you want the idle scene to fire it at random.

Two things that make gestures look right: only touch the motors you actually
need (so a blink can happen mid-sweep without fighting the head), and make
your timings asymmetric (equal in-and-out times look mechanical).

## Driving It From Your PC

Every command needs `-p com.getcircuitbent.mabu.signboard`. Without it,
Android 8 and up silently drops the broadcast and reports success.

```powershell
$P = "com.getcircuitbent.mabu.signboard"
adb shell "am broadcast -a $P.SHOW -p $P"
adb shell "am broadcast -a $P.IDLE -p $P --ez on false"
adb shell "am broadcast -a $P.POSE -p $P --es name Sleep"
adb shell "am broadcast -a $P.GESTURE -p $P --es name 'Nod Yes'"
adb shell "am broadcast -a $P.MOVE -p $P --es motor NR --ef value 80"
```

The same list is on the device, at the bottom of the admin page.

## Booting Straight Into the Sign

Opt-in, and it takes two steps on purpose, because making a robot boot into
your app is a real decision about that device:

1. Uncomment the `android.intent.category.HOME` filter in
   `app/src/main/AndroidManifest.xml`, then rebuild and reinstall.
2. Run `./scripts/set-as-home.ps1`.

`./scripts/unset-as-home.ps1` puts it back.

## Reading the Source

In dependency order, innermost first. Each file is a copy-paste unit.

| File | What it teaches |
|---|---|
| [`cpp/serial.c`](app/src/main/cpp/serial.c) | Why the serial port must be opened from C, not Kotlin. Read this one first |
| [`SerialPort.kt`](app/src/main/java/com/getcircuitbent/mabu/signboard/SerialPort.kt) | The three-call JNI shim |
| [`MabuProtocol.kt`](app/src/main/java/com/getcircuitbent/mabu/signboard/MabuProtocol.kt) | Frames, checksum, the motor table, and a self-test against known-good frames |
| [`MotorLink.kt`](app/src/main/java/com/getcircuitbent/mabu/signboard/MotorLink.kt) | Owning the port, and the cold-boot wake sequence everyone skips |
| [`MotorTween.kt`](app/src/main/java/com/getcircuitbent/mabu/signboard/MotorTween.kt) | The motion engine. Why the robot sounds smooth instead of chattering |
| [`Poses.kt`](app/src/main/java/com/getcircuitbent/mabu/signboard/Poses.kt) | Poses are data, not code |
| [`Gestures.kt`](app/src/main/java/com/getcircuitbent/mabu/signboard/Gestures.kt) | The scripting format, and a state machine that never sleeps |
| [`IdleScene.kt`](app/src/main/java/com/getcircuitbent/mabu/signboard/IdleScene.kt) | Continuous motion versus scheduled one-shots, and how they share motors |
| [`SignView.kt`](app/src/main/java/com/getcircuitbent/mabu/signboard/SignView.kt) | Media on the panel, and owning the animation clock |
| [`DeviceInfo.kt`](app/src/main/java/com/getcircuitbent/mabu/signboard/DeviceInfo.kt) | Battery, uptime, IP |
| [`ControlReceiver.kt`](app/src/main/java/com/getcircuitbent/mabu/signboard/ControlReceiver.kt) | The ADB control surface |
| [`MainActivity.kt`](app/src/main/java/com/getcircuitbent/mabu/signboard/MainActivity.kt) | The admin page and the show overlay |

## If It Does Not Work

| Symptom | Cause |
|---|---|
| Header says `Link FAILED: busy` | Another app owns `/dev/ttyS1`. Usually the factory app: `adb shell am force-stop com.catalia.factorymode` |
| Header says `protocol self-test FAILED` | The frame builder disagrees with frames captured from real hardware. The message names the failing case. Nothing was sent to the robot |
| Link opens, nothing moves, head is STIFF | The board missed its wake. Tap **Wake Board** |
| Link opens, nothing moves, head is LIMP | The motor board has no power. Wiring, not software |
| Motors were fine and went silent | Something opened `/dev/ttyS1` from an adb shell while the app held it. Restart the app, and read logcat instead |
| Sign is a black rectangle | A GIF drawn on a hardware-accelerated canvas. `SignView` already handles this; if you have modified it, check `setLayerType` |
| An `am broadcast` does nothing | Missing `-p <package>` |

**Never run `adb reboot` on a Mabu.** It has left units that came back without
Wi-Fi, and with no external USB port and no buttons that means no way in short
of opening the case. Power-cycle the hardware instead.

---

Copyright (C) 2026 Get Circuit Bent LLC. Licensed under the
[GNU General Public License v3.0](../../LICENSE).
Contact: info@getcircuitbent.com

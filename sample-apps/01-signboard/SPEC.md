# Sample App 1: Mabu Signboard

Locked design. Build to this; changes go through an edit here first.

Mabu as a living sign. The screen shows a still image or a looping animation
while the body keeps moving on its own, which is the robot equivalent of a shop
window display. Useful at a booth, a storefront or a reception desk, and every
function in it earns its place because the sign genuinely needs it.

It is also the first thing a new developer should read: it covers the whole
motor stack from the serial link up to scripted gestures, with no camera and no
audio in the way.

## Coverage

Against the [Sample App Function Index](../SAMPLE-APP-FUNCTION-INDEX.md).

| Tier | Rows | Status |
|---|---|---|
| 0: Foundation | 1, 2, 3, 4, 5 | Complete |
| 1: Motion | 6, 7, 8, 9, 10 | Complete |
| 1: Motion | 11 telemetry readback | **Excluded.** Needs a `readBytes()` on the JNI shim that has never been written. Deferred to its own sample |
| 2: Sensing | 12 to 15 | Not this app. No camera |
| 3: Audio | 16 to 18 | Not this app |
| 4: Device | 19, 20, 22, 23, 24 | Complete |
| 4: Device | 21 autostart as HOME | Covered as an **opt-in script**, not the default. See [Autostart](#autostart) |
| 4: Device | 25 video playback | **Excluded.** Deferred to a later sample. See [Media](#media) |

16 of 25 rows.

## Device Facts

Everything below is confirmed from device dumps or hardware sessions. These are
the numbers the app is built against.

| Fact | Value |
|---|---|
| SoC | Rockchip RK3288, 32-bit ARMv7, 2 GB RAM |
| Android | 8.1, API 27 |
| Panel | 1024x600, upright landscape, 30 fps |
| Density | 180 dpi (`ro.sf.lcd_density`) |
| Serial | `/dev/ttyS1`, 57600 8N1 |
| Play Services | None. Anything depending on GMS is out |

## Layout

One Activity. One scrolling admin page, per the index conventions. Show mode is
a full-screen overlay on the same Activity, not a second screen to navigate to.

```
+- ADMIN (scrolls) ----------------------------+   +- SHOW MODE ----------------+
| Mabu Signboard                               |   |                            |
| Link open (fd 42)   Board awake              |   |                            |
| Batt 87% 31.2C - up 4h12m - 192.168.0.180    |   |      Get Circuit           |
| [ Wake Board ]                               |   |      Bent      /\ /\       |
+----------------------------------------------+   |                (  =  )     |
| IDLE       ( ON )  off                       |-->|                            |
+----------------------------------------------+   |                            |
| MOTORS                                       |   |   (double-tap to exit)     |
| LDL 0x40 Eyelid L  [====|=====] 20  0=open   |   +----------------------------+
| LDR 0x20 Eyelid R  [====|=====] 20  0=open   |     immersive - screen stays on
| ELR 0x10 Eyes L/R  [=====|====] 50  hi=right |     body keeps moving
| EUD 0x08 Eyes U/D  [=====|====] 50  INVERTED |
| NE  0x04 Neck Elev [=====|====] 50  hi=up    |
| NR  0x02 Neck Rot  [=====|====] 50  hi=left  |
| NT  0x01 Neck Tilt [=====|====] 50  hi=right |
| [ All to Neutral ]                           |
+----------------------------------------------+
| POSES    [Neutral][Rest][Sleep]              |
|          [Look L][Look R][Look Up][Look Dn]  |
+----------------------------------------------+
| GESTURES [Blink][Wink][Nod Yes][Shake No]    |
|          [Tilt][Look Away]                   |
+----------------------------------------------+
| IDLE SCENE                                   |
| Blink every    [===|======] 3 to 7 s         |
| Sweep width    [====|=====] +/-15            |
| Sweep period   [=====|====] 8 s              |
| Random gesture [==|=======] 20 to 45 s       |
+----------------------------------------------+
| SIGN                                         |
| Media: (bundled GCB still) (/sdcard/...)     |
| Fit: (Contain) (Cover)   Rate: [===|====]    |
| [           SHOW SIGN           ]            |
+----------------------------------------------+
| ABOUT - safety rules - ADB command list      |
+----------------------------------------------+
```

## Motion Model

**One toggle: `IDLE [on|off]`, on by default.** There is no separate hold state.
Servos hold whatever position they were last commanded to, so "not animating" is
already "holding". Poses, gestures and sliders are all just ways of writing
targets; idle-on means the loop keeps writing over them.

Two rules fall out of that, and both are load-bearing:

1. **Sliders mirror the engine, not the other way round.** They track the tween's
   live target values while idle runs, so you can watch the sweep move them.
   Without this they show stale numbers and the first touch after idle stops
   snaps the head somewhere unexpected. It also demonstrates the right pattern:
   the UI reads engine state, the engine owns it.
2. **Poses and sliders switch idle off. Gestures do not.** Touching a slider or
   pressing "Look Left" while idling means you want control, and without auto-off
   the loop overwrites you within one 40 ms tick and the button looks broken.
   Gestures stay non-destructive: they take priority, play, and idle resumes.
   That is machinery idle already needs for its own random gestures.

Show mode never touches the motion model. It changes what is on screen and
nothing else, which is why "movement continues as defined by the admin scene"
needs no special case: the engine does not know or care whether the admin page
is visible.

## Idle Scene

The behavior that runs while the sign is up. Defaults, all exposed as sliders so
tuning needs no rebuild:

| Element | Default | Motors |
|---|---|---|
| Blink | Both lids, every 3 to 7 s randomized, about 120 ms | LDL, LDR |
| Side-to-side sweep | +/-15 units around neutral, 8 s period, eyes leading the head slightly | NR, ELR |
| Random gesture | Every 20 to 45 s, picked from the gesture list, then back to the sweep | varies |

The loop does two structurally different things at once, and the comments must
make the distinction explicit because it is where people go wrong:

- **Continuous motion is a function of time**, not a sequence. The sweep is
  `sin(t)`, evaluated fresh every tick. Nothing to schedule, nothing to cancel.
- **One-shots are scheduled events** that temporarily claim the motors they
  touch, then hand them back.

Layering is per-motor, which is *why* a blink can happen mid-sweep without the
two fighting: the sweep writes ELR and NR continuously, blink owns LDL and LDR
only, and a random gesture claims whatever it lists and releases it on finish.

**The idle loop never blocks.** No `Thread.sleep` between keyframes, ever. It is
a state machine ticked at 25 Hz because the same thread owns the serial port,
and a sleeping thread is a robot that has stopped responding. Sleeping between
keyframes is the obvious first instinct and it works right up until it does not,
so this gets a paragraph of its own in the source.

### Gesture Format

A gesture is a list of steps read top to bottom like a storyboard. This format is
a deliverable of the sample: someone should be able to add their own without
reverse-engineering anything.

```kotlin
// A gesture is a list of steps. Each step says "put these motors at these
// values, take this long getting there, then wait before the next step."
// Values are 0-100 logical units (see MabuProtocol.kt for per-motor meaning).
val NOD_YES = gesture("Nod Yes") {
    step(NE to 62, overMs = 250)   // chin up
    step(NE to 38, overMs = 350)   // chin down, slower: gravity reads as weight
    step(NE to 50, overMs = 250)   // back to level
    hold(120)                      // a beat before whatever comes next
}
```

Adding one is four steps, and the comment block above the gesture list spells
them out: define the gesture, add it to `ALL_GESTURES`, and the button plus the
ADB broadcast action appear automatically because both are generated from that
list. There is no third place to forget.

## Media

**In scope for this sample: still images and animated GIF. Video is excluded**
and tracked as row 25 for a later sample, because a `MediaPlayer` surface, codec
verification and playback-rate support that this hardware may not honor are more
complexity than sample 1 should carry.

| Type | How | Rate control |
|---|---|---|
| Stills (PNG, JPEG, WebP) | `BitmapFactory` into an `ImageView` | n/a |
| Animated GIF | `android.graphics.Movie` | Exact, free |

`Movie` is deprecated as of API 28 but fully alive on this device's API 27, and
needs no third-party library. It does not animate itself: you tell it which frame
to show on every draw, which means playback rate is not a feature to implement,
it is the line you were already writing.

```kotlin
// elapsed * rate = "GIF time". rate 0.5 = half speed, 2.0 = double, 0.0 = frozen.
val gifTime = ((SystemClock.uptimeMillis() - startMs) * rate).toLong()
movie.setTime((gifTime % movie.duration()).toInt())   // % duration = the loop
movie.draw(canvas, x, y)
```

That is the whole animation engine, and it is the same "you own the clock" idea
as the motor tween one screen over. Rate slider range 0.25x to 2.0x.

### Sizing

The panel is 1024x600. Bundled defaults come from the
[GCB style guide](https://github.com/GetCircuitBent/GitHub-Style-Guide):
`boot-logo.png` (the still, wordmark and cat on Bluewood) and
`boot-animation.gif` (700x438, the same composition with sparkles) as the GIF
example. At 700x438 the animation pillarboxes slightly under Contain, which is
useful: the fit modes are visible on the shipped example rather than abstract.

Guidance the comments give: author at 1024x600 to fill the panel exactly, keep
stills under about 2 MP (a 1024x600 ARGB_8888 bitmap is about 2.4 MB and this
device has 2 GB of RAM with a 32-bit address space that fragments), and keep GIFs
modest since `Movie` holds the whole file in memory.

### Changing the Media

Three ways, presented in this order:

1. Drop a file in `app/src/main/assets/` and change one constant. The "building
   my own" path.
2. Push to `/sdcard/signboard/` and pick it in the admin. No rebuild. The file
   extension decides the player.
3. Swap it remotely while it is running:
   `adb shell "am broadcast -a ...SET_MEDIA -p ... --es path /sdcard/signboard/promo.gif --ef rate 0.75"`

### Show Mode Gotchas

These are comments in the source, not discoveries for the reader to make:

- **A GIF rendering as a black rectangle** means the view needs
  `setLayerType(LAYER_TYPE_SOFTWARE, null)`. `Movie.draw` does not reliably
  survive a hardware-accelerated canvas.
- **Double-tap must be caught at `dispatchTouchEvent` on the root**, not with a
  listener on the media view, or a future `SurfaceView` swallows it and show mode
  becomes a trap with no way out. Single tap deliberately does nothing.
- **`FLAG_KEEP_SCREEN_ON` plus immersive sticky**, or the sign goes dark on the
  display timeout, which also drops the Wi-Fi ADB connection.

## Autostart

A signboard wants to boot straight into show mode, so this is the natural app for
row 21. But a sample that grabs HOME on install is hostile: it is sticky and
annoying to undo on someone's unit.

The manifest pieces ship present but inert. `scripts/set-as-home.ps1` and
`scripts/unset-as-home.ps1` turn it on and off as a documented, opt-in step after
the app is already running and proven. Row 21 gets covered; nobody gets ambushed.

## File Map

Each file is a copy-paste unit, and each one maps to index rows.

| File | Rows |
|---|---|
| `cpp/serial.c`, `SerialPort.kt` | 1 JNI open, write, close |
| `MabuProtocol.kt` | 2 framing and Fletcher-8, 4 motor table, neutrals, directions |
| `MotorLink.kt` | 3 wake sequence, 5 single and atomic 7-motor sends |
| `MotorTween.kt` | 10 25 Hz thread, low-pass filter, send deadband |
| `Poses.kt`, `Gestures.kt` | 7 named poses, 8 blink and wink, 9 gesture sequencer |
| `IdleScene.kt` | 8, 9, 10 composed into a behavior |
| `SignView.kt` | 24 full-screen media, `Movie` GIF loop, fit modes, rate |
| `MainActivity.kt` | 6 sliders, show overlay, double-tap dismiss |
| `DeviceInfo.kt` | 19 battery, temperature, uptime, IP |
| `ControlReceiver.kt` | 20 broadcast surface |
| `scripts/install.ps1`, `README.md` | 22 build and deploy, 23 safety |

## Project Layout

```
sample-apps/01-signboard/
  SPEC.md              this file
  README.md            how to build, install and use it
  scripts/
    install.ps1        build, free the port, install, launch, tail logs
    set-as-home.ps1    opt-in autostart
    unset-as-home.ps1  undo
  gradlew, gradlew.bat, gradle/wrapper/
  app/src/main/
    cpp/               serial.c, CMakeLists.txt
    java/com/getcircuitbent/mabu/signboard/
    res/               GCB brand colors, layouts
    assets/            default sign media
```

Standalone Gradle project, not a module in a shared root. Duplicating the wrapper
costs nothing and buys the thing that matters: open the directory in Android
Studio and press Run. A reader can copy the whole folder out of the repo and it
still builds.

Package: `com.getcircuitbent.mabu.signboard`.

## Build Order

1. **Protocol, link, tween.** Rows 1 to 5 and 10. The part that has to be exactly
   right, since everything else stacks on it. Hardware check at the end of this
   step: wake sequence, framing, one deliberate move.
2. **Admin UI.** Sliders, status header, wiring to the tween.
3. **Poses, gestures, idle scene.** Rows 7 to 9 and the scripting format.
4. **Sign overlay.** Row 24, stills then GIF.
5. **Tier 4 wiring.** Device info, broadcasts, install scripts, README, safety
   card, autostart scripts.

Hardware checks happen with the operator watching, per the standing rule on
observed tests.

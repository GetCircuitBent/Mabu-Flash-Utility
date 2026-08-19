# Mabu Theremin

> **Status: in development, not yet hardware-validated.** Built, but not yet
> tested on a real Mabu. Sample App 1 (Signboard) is the validated one.

The second Mabu sample app. The camera watches your hands and maps their
height onto whatever you choose - volume, pitch, playhead position, a filter -
while the robot follows your face and blinks at you.

Where [Sample App 1](../01-signboard/) is the motor stack with no sensors,
this is the sensor and audio stack. It reuses app 1's motor code unchanged
(see [CORE.md](CORE.md)), which is the point: those files are meant to be
copied.

Covers Tier 2 (camera, face detection, face following), Tier 3 (audio out,
and mic as an opt-in add-on), and both Tier 5 rows of the
[Sample App Function Index](../SAMPLE-APP-FUNCTION-INDEX.md).

## Just Want to Run It?

Not yet: `mabu-theremin.apk` is **not published**, because this app has not been
run on real hardware and shipping a download of something untested is how you
waste someone's afternoon. Build it from source with the steps below. Once it is
hardware-validated it gets an APK on the releases page, and
[Install a Sample App](../INSTALL-A-SAMPLE-APP.md) becomes the way in.

## Getting It Running

You need a flashed Mabu on the same Wi-Fi as your PC. See
[Getting Started](../SAMPLE-APP-FUNCTION-INDEX.md#getting-started) if you have
not connected to one before.

```powershell
./scripts/install.ps1 -Ip 192.168.0.180 -Logcat
```

Builds, frees the serial port, installs, grants CAMERA and storage, creates
`/sdcard/theremin/`, launches, tails the logs.

Then stand in front of it and wave. It should make a noise.

## Playing It

**Sound only happens while a hand is visible.** That is deliberate and it is
not a volume mapping: no hands, no sound, whatever the dropdowns say. A real
theremin is silent until you enter its field. There is also an **ARMED**
button and a master gain, so you can shut it up without waving at it.

Two dropdowns choose what each hand does. **Height is the control**, and up
always means more.

| Parameter | What it does |
|---|---|
| Volume | Loudness |
| Pitch | Playback rate. Changes pitch **and** speed together, like a tape machine |
| Position | Scrubs the playhead through the sample |
| Low-pass | Opens and closes a filter |
| High-pass | The same filter, other output |
| None | Nothing |

Picking a parameter the other hand already has releases it there. Two hands
fighting over one value is miserable to play.

## The Two Trackers

The button marked **Tracking** switches between them. They are the most
interesting thing in this app, and they have opposite strengths.

| | Motion (default) | Tone |
|---|---|---|
| Setup | None | Calibrate first |
| Hand held still | **Fades away** | **Stays tracked** |
| Skin tone | Cannot matter - it only sees brightness change | No colour constants shipped; calibrates from you |
| Best with | Nothing | A brightly coloured glove |
| Good for | Waving about, demos | Sustained notes, installations |

**Motion** models what the room normally looks like and flags anything that
differs. Move the *adapt rate* slider while watching the hand boxes: fast, and
a held hand vanishes in about a second; slow, and you trail ghosts of where
you were. There is no correct setting, which is exactly why it is on screen.

**Tone** matches a colour you calibrate it to. Press **Calibrate**, hold a
hand or a coloured object in the orange box, and wait for it to sample. It
also self-calibrates from your face the first time you switch to it, so it
does something sensible if you skip that.

If you want to hold a note, use Tone with a glove. If you want it to work
instantly for anyone who walks up, use Motion.

**There is no real hand tracking here, and there cannot be.** MediaPipe
dropped 32-bit ARM, ML Kit has no hand API, and ML Kit Pose would eat the
entire 100 ms frame budget on its own. [HandTracker.kt](app/src/main/java/com/getcircuitbent/mabu/theremin/HandTracker.kt)
works through that arithmetic. It is the most useful page in the app.

## Testing It Without a Crowd

The tone tracker's behaviour depends on the colouring and lighting of whoever
is in front of it, which is awkward to verify properly: you would need a range
of people on hand. Two things in here get you most of the way without that.

**CAPTURE and REPLAY.** Capture saves the current frame, raw, to
`/sdcard/theremin/testframes/`. Replay runs saved frames through the same
pipeline instead of the camera, at the same 10 fps, drawing each frame under
the tracking boxes. Tuning a threshold against a live camera changes two things
at once - the setting and whatever your hands were doing. Against replayed
frames, only the setting moves.

It also compounds: capture anyone who happens to walk past, and the corpus
becomes a permanent regression test. Testing across a range of people stops
being an event you have to organise.

**scripts/tone-sweep.py.** Takes one captured frame and synthesises darker and
dimmer variants, modelling the drop in luminance and, importantly, the loss of
signal-to-noise that comes with it.

```powershell
adb pull /sdcard/theremin/testframes/cap-001.nv21
python scripts/tone-sweep.py cap-001.nv21 --out sweep/
adb push sweep/*.nv21 /sdcard/theremin/testframes/
```

Then switch to Tone, calibrate on step 00, and press REPLAY while watching the
quality line.

**This is a model, not a validation.** Real skin differs spectrally rather than
by a brightness scale, and a real camera's auto-exposure responds to the whole
scene. A clean sweep means the obvious failure is absent, not that the app
works for everyone. It has already earned its place though - it is what caught
the match window failing to adapt, and then caught the fix over-correcting.

**The quality line** is the same idea in live use. The tracker scores its own
last frame and says what to do: `GOOD`, `WEAK - recalibrate, or try a coloured
marker`, `TOO BROAD - window is catching the room`, `NOTHING MOVING - wave, or
use Tone to hold still`. When a thing cannot be verified for every user in
advance, the next best property is that it tells the user when it is not
working.

## Changing the Sample

```powershell
adb push mysample.wav /sdcard/theremin/
```

Then press **Load /sdcard**. Pressing it again cycles through the folder.

**16-bit PCM WAV**, mono or stereo, any sample rate. A few seconds, and it
should loop cleanly - the player loops it constantly, and a hard seam is a
click that no amount of filtering will hide.

To change the built-in default, replace `app/src/main/assets/sample.wav` and
rebuild. The one that ships is a generated placeholder.

## Changing the Watermark

Replace `app/src/main/assets/watermark.png`. Position, size and opacity are
four constants at the bottom of
[CameraOverlayView.kt](app/src/main/java/com/getcircuitbent/mabu/theremin/CameraOverlayView.kt).
Nothing else in the app refers to it.

## Recording Your Own Sample (Opt-In)

Off by default. The microphone permission is commented out in the manifest,
because a sample app that quietly holds RECORD_AUDIO is not one to trust.

1. Uncomment `RECORD_AUDIO` in `app/src/main/AndroidManifest.xml`
2. Rebuild and reinstall
3. `adb shell pm grant com.getcircuitbent.mabu.theremin android.permission.RECORD_AUDIO`
4. Wire a button to `SampleRecorder` in `MainActivity` (about ten lines)

## Driving It From Your PC

Every command needs `-p <package>`, or Android 8+ drops it silently while
reporting success.

```powershell
$P = "com.getcircuitbent.mabu.theremin"
adb shell "am broadcast -a $P.ARM -p $P --ez on false"
adb shell "am broadcast -a $P.MAP -p $P --es hand left --es param Pitch"
adb shell "am broadcast -a $P.TRACKER -p $P --es name tone"
adb shell "am broadcast -a $P.SAMPLE -p $P --es path /sdcard/theremin/loop.wav"
```

## Reading the Source

Start at the top two. They are the ones with something to teach.

| File | What it teaches |
|---|---|
| [`HandTracker.kt`](app/src/main/java/com/getcircuitbent/mabu/theremin/HandTracker.kt) | Why this device has no hand tracking, and how to structure a tracker so the technique is swappable |
| [`AudioEngine.kt`](app/src/main/java/com/getcircuitbent/mabu/theremin/AudioEngine.kt) | 10 Hz control driving 44.1 kHz audio without zipper noise. The same idea as the motor tween, one domain over |
| [`MotionMask.kt`](app/src/main/java/com/getcircuitbent/mabu/theremin/MotionMask.kt) | A background model in two lines, and the tradeoff it cannot escape |
| [`ToneMask.kt`](app/src/main/java/com/getcircuitbent/mabu/theremin/ToneMask.kt) | Chroma matching, and why there are no skin-colour constants in it |
| [`BlobExtractor.kt`](app/src/main/java/com/getcircuitbent/mabu/theremin/BlobExtractor.kt) | Mask to hand positions: flood fill, size filter, smoothing |
| [`SamplePlayer.kt`](app/src/main/java/com/getcircuitbent/mabu/theremin/SamplePlayer.kt) | Pitch **is** playback rate, and everything else that fact explains |
| [`Filter.kt`](app/src/main/java/com/getcircuitbent/mabu/theremin/Filter.kt) | One filter, two outputs, and the stability limit that will bite you |
| [`Camera1Source.kt`](app/src/main/java/com/getcircuitbent/mabu/theremin/Camera1Source.kt) | Why the deprecated camera API, and the 10 fps ceiling you cannot lift |
| [`FaceDetector.kt`](app/src/main/java/com/getcircuitbent/mabu/theremin/FaceDetector.kt) | ML Kit bundled and pinned, and why floating the version would break the robot |
| [`FaceFollow.kt`](app/src/main/java/com/getcircuitbent/mabu/theremin/FaceFollow.kt) | Face to motor targets, and the two sign traps that make the robot look away from you |
| [`Mapping.kt`](app/src/main/java/com/getcircuitbent/mabu/theremin/Mapping.kt) | Hand height to parameters, with exponential curves where ears expect them |
| [`SampleRecorder.kt`](app/src/main/java/com/getcircuitbent/mabu/theremin/SampleRecorder.kt) | AudioRecord, and two things that ruin musical recordings |
| [`CORE.md`](CORE.md) | What is shared with app 1 and why it is copied |

## If It Does Not Work

| Symptom | Cause |
|---|---|
| No sound at all | Are your hands visible? Check for green boxes. Then check ARMED and master gain |
| Sound cuts out when you hold still | You are in Motion mode. That is the documented limitation - switch to Tone |
| Hand boxes on the wrong things | Motion: something else in frame is moving. Tone: recalibrate, or use a marker colour nothing else in the room shares |
| No hand boxes in Tone mode | It is uncalibrated. Press Calibrate, or switch to Motion |
| Crackling, or `underruns` climbing | The audio buffer ran dry. Raise `BLOCK` in `AudioEngine.kt` and note what worked |
| Robot looks at the ceiling | Adjust **Y offset**. It is a per-unit calibration |
| Robot looks away from you | A sign flip. See the header of `FaceFollow.kt` |
| `Link FAILED: busy` | Something else owns the serial port: `adb shell am force-stop com.catalia.factorymode` |
| Preview is black | CAMERA permission. The install script grants it |

**Never run `adb reboot` on a Mabu.** Power-cycle instead.

---

Copyright (C) 2026 Get Circuit Bent LLC. Licensed under the
[GNU General Public License v3.0](../../LICENSE).
Contact: info@getcircuitbent.com

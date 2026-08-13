# Sample App 2: Mabu Theremin

Locked design. Build to this; changes go through an edit here first.

Mabu as a playable instrument. The camera tracks your hands and maps their
positions onto the parameters of a sample it is playing, the way a theremin
maps hand position onto pitch and volume. At the same time it tracks your face
and turns its head to follow you, blinking on its own, so the robot is looking
at the person playing it.

Where [Sample App 1](../01-signboard/SPEC.md) is the motor stack with no
sensors, this one is the sensor and audio stack. It reuses app 1's motor code
unchanged, which is the point: those files are meant to be copied.

## Coverage

Against the [Sample App Function Index](../SAMPLE-APP-FUNCTION-INDEX.md).

| Tier | Rows | Status |
|---|---|---|
| 0: Foundation | 1 to 5 | Reused from Signboard, unchanged |
| 1: Motion | 6 to 10 | Reused from Signboard, unchanged |
| 1: Motion | 11 telemetry readback | Still not covered by any sample |
| 2: Sensing | 12 camera, 13 face detection, 14 face following | Complete |
| 2: Sensing | 15 puppet mirroring | Not this app. Mirroring head pose is not part of playing an instrument |
| 3: Audio | 17 mic capture | Covered as an **opt-in add-on**, see [Sample Recorder](#sample-recorder-opt-in) |
| 3: Audio | 18 play audio | Complete, and then some |
| 3: Audio | 16 speak (TTS) | Not this app. Nothing to say |
| 4: Device | 19, 20, 22, 23 | Reused from Signboard |
| 4: Device | 25 video | Not this app |
| **New** | **26 hand tracking**, **27 real-time audio** | Both new to the index |

After apps 1 and 2, four rows remain uncovered: **11** (motor telemetry),
**15** (puppet mirroring), **16** (TTS), **25** (video). They have nothing in
common, so a third app should come from a concept that wants several of them,
not from working backwards through this list.

## Device Facts

Adds the audio and vision numbers to the hardware facts in the app 1 spec.

| Fact | Value |
|---|---|
| SoC | Rockchip RK3288, 32-bit ARMv7, 2 GB RAM |
| Android | 8.1, API 27 |
| Camera API | Camera1 only. The HAL is a Camera1 shim; CameraX and Camera2 fail enumeration |
| Camera delivery | **10 fps, hard ceiling.** It advertises 24 in `supportedPreviewFpsRange` and does not deliver it |
| Frame format | NV21 (YCbCr 4:2:0) at 320x240 |
| Face detection | ML Kit bundled, about 35 ms per frame, measured |
| Audio out | `AudioTrack`, 44.1 kHz mono 16-bit |
| Play Services | None. ML Kit must be the bundled model, not the Play-Services-backed one |

## The Hand Tracking Decision

This is the most instructive part of the app, and the reasoning belongs in the
source as much as in this spec.

### Why not actual hand tracking

**MediaPipe Hands** is the obvious tool and it is unavailable: modern MediaPipe
Tasks Vision AARs dropped `armeabi-v7a` around 0.10.x, and the RK3288 is armv7
only.

**ML Kit has no hand API at all.** Its only body option is Pose Detection,
which returns 33 landmarks including wrists. That would work in principle. The
frame budget says it will not work here:

| | Time |
|---|---|
| Camera delivers a frame every | 100 ms |
| Face detection consumes (measured) | ~35 ms |
| Left for hand tracking | **~65 ms** |
| ML Kit Pose on a Cortex-A17, estimated | 100 to 200 ms |

Pose alone would exceed the whole frame budget, and it has to share that budget
with face detection because this app wants both. It would also push control
latency past 200 ms. That is fine for a robot head and unplayable for a musical
instrument.

### What we do instead

**Chroma-match blob tracking.** A theremin needs two continuous numbers, not
twenty-one landmarks. Find the two largest regions matching a calibrated
colour, excluding the face, take their positions, done.

Note the framing: this is **not** a skin detector. The tracker has no built-in
idea what skin looks like. It matches whatever chroma it was calibrated to, and
by default it calibrates itself from the player. The reason for that is in
[Skin Tone](#skin-tone-a-requirement-not-a-caveat) below, and it is the single
most important design decision in this app.

Three things make it cheap and, on this hardware, right:

1. **The camera already gives us YCbCr.** NV21 *is* YCbCr, and colour is most
   separable from brightness in exactly that space. Converting NV21 to RGB in
   order to match a colour would be doing work to make the problem harder.
2. **The face is the calibration target.** Sample the mean Cb and Cr inside the
   detected face box and centre the match window on that. The player's own
   face, under the room's own lighting, sets the target for the player's own
   hands.
3. **We can subsample.** Every second pixel in each direction is 19,200 samples
   instead of 76,800, which is a few milliseconds of work.

Total: about 40 ms of the 100 ms budget for both detectors, with latency low
enough to play.

### Why Not Motion Instead

Motion energy and background subtraction are appealing here because they are
completely colour-independent. Both are ruled out by this specific robot:
**the camera is mounted on the head, and the head moves**, because it is
tracking the player's face. A moving camera means frame differencing sees
motion everywhere and a background model never stabilises.

Motion also fails a theremin on its own terms. A hand held still to sustain a
note produces no motion and would vanish.

So appearance-based matching is the correct family here, and it is a direct
consequence of the hardware rather than a preference. Worth a comment, because
on a fixed camera the answer would be different.

### Skin Tone: A Requirement, Not a Caveat

The textbook version of this technique uses fixed YCbCr bounds, usually
`77 <= Cb <= 127` and `133 <= Cr <= 173`. **Those constants are biased toward
light skin, and this app does not use them.**

Why the bias is real, stated in the source as well as here:

- The published ranges come from late-1990s work built on predominantly
  light-skinned datasets, and they carry that sampling forward as if it were
  physics.
- The usual defence, that chrominance is tone-stable because melanin mostly
  affects luminance, is directionally true and insufficient. Darker skin
  reflects less light, so Y is lower, so the signal-to-noise ratio in Cb and Cr
  is worse. NV21 already subsamples chroma 4:2:0, so there is less of it to
  begin with.
- Camera auto-exposure routinely underexposes darker faces, which pushes the
  chroma estimate further into the noise.

The result of shipping fixed thresholds would be an instrument that works
better for some players than others. That is a defect, and it is the kind that
does not show up in testing unless you go looking.

**What the app does instead:**

| Measure | Effect |
|---|---|
| **No shipped colour constants.** The match window comes entirely from measured face chroma | Removes the biased step rather than compensating for it |
| **Luminance-adaptive tolerance.** The window widens as Y falls | A fixed tolerance would reintroduce the bias through the back door, since low Y is exactly where the chroma estimate degrades |
| **Manual calibration.** Hold a hand in the on-screen box and tap | Covers a face the detector never found, and hands that differ from the face |
| **Marker mode.** Calibrate to a brightly coloured object instead of a hand | Costs zero extra code, because the tracker already just matches a calibrated chroma. A guaranteed path for any player in any lighting |
| **Visible calibration readout**, e.g. `window: Cb 108 +/-14, Cr 148 +/-16, from face` | Makes a failure diagnosable instead of mysterious |

**Acceptance gate.** Before this app ships, tracking must be validated across a
range of skin tones, in a bright room and a dim one. If acquisition is
materially worse for darker skin after face calibration, that is a bug to fix,
not a limitation to document. The fallbacks, in order, are a wider default
tolerance, manual calibration, and marker mode.

### What It Costs

Stated plainly, in the source, next to the code:

- Sensitive to lighting. Strong colour casts move Cb and Cr; face calibration
  absorbs most but not all of it.
- Long sleeves help, bare arms confuse it. The largest matching region may be a
  forearm rather than a hand.
- No left/right identity except by screen position, so crossing your hands
  swaps them.
- Anything matching the calibrated chroma is a candidate: wooden furniture and
  cardboard are the usual offenders. Face-box exclusion and a minimum-size
  threshold remove most of it.

This is a worked example of reading the hardware and choosing the technique
that fits it, rather than the technique that would be correct on a phone. That
lesson, and the calibration decision above, are why this app is worth writing.

## Layout

One Activity, one scrolling page, per the index conventions.

```
+------------------------------------------------+
|  camera feed 320x240, upscaled                 |
|   [L]                              [R]         |  <- hand blob boxes
|                  (face)                        |  <- face box
|                                     (o) logo   |  <- watermark
+------------------------------------------------+
| Left hand  [ Volume      v ]   Right [ Pitch v ]|
| ARMED   master [====|=====]   hands: L+R       |
+------------------------------------------------+
| SAMPLE                                          |
| gcb-loop.wav · 3.2 s · 44.1k mono               |
| gate: presence · grace 250 ms · fade 150 ms     |
| [ ] also require a face                         |
+------------------------------------------------+
| TRACKING                                        |
| skin window / blob min size / smoothing         |
| face follow + blink (reused from Signboard)     |
+------------------------------------------------+
| PERF · HAL 10.0 fps · face 34 ms · blobs 6 ms   |
| · audio underruns 0                             |
+------------------------------------------------+
| ABOUT · safety rules · ADB command list         |
+------------------------------------------------+
```

## Audio

### The Rate Problem

**The camera produces control data at 10 Hz. The audio runs at 44,100 Hz.**

Feeding hand positions straight into the synth produces a stairstep every
100 ms: audible as zipper noise on pitch and as clicks on volume.

The fix is the architecture app 1 already uses for motors. Producers write
targets; a consumer on its own clock interpolates toward them. In app 1 the
consumer is a 25 Hz motor tween; here it is the audio thread, ramping each
parameter linearly across each block. Same shape, different output stage, and
seeing it twice in two domains is what makes the pattern stick.

### Engine

| Setting | Value | Why |
|---|---|---|
| Sample rate | 44,100 Hz | Drop to 22,050 if the SoC struggles; the code reads it from one constant |
| Channels | Mono | Nothing here is stereo, and mono halves the work |
| Format | 16-bit PCM | |
| Block size | 1024 frames | About 23 ms. Small enough to feel responsive, large enough not to underrun |
| Buffer | max(`getMinBufferSize`, 4 blocks) | |
| Thread | Dedicated `mabu-audio` | Never the main thread, never the camera thread |

Per block, in order: read from the sample, filter, apply gain and gate, write.
Every parameter is ramped across the block from its previous value to its
current target. That ramp is the whole anti-zipper mechanism and gets a comment
saying so.

### Sample Playback

The sample is decoded to memory at startup. A playhead advances by a
per-sample increment, with linear interpolation between neighbouring samples
(cheap; loses a little high end; cubic is the upgrade if anyone cares) and
loops at the end.

**Pitch is playback rate, and that equivalence is the lesson.** There is no
pitch shifter here. Changing the playhead increment changes pitch and duration
together, which is a worse instrument (a held note drifts through the sample)
and much better example code: the entire pitch control is one line.

The comment on that line earns its place by naming what else the same identity
gets you. Varispeed tape, the chipmunk and slow-motion effects, a classic
sampler mapping one recording across a whole keyboard, and sample-rate
conversion itself are all this operation. Granular pitch shifting, which
separates the two at the cost of two read heads and a window function, is named
as the upgrade and deliberately not built.

### Filter

One **state-variable filter** (Chamberlin form) producing low-pass and
high-pass from the same three lines:

```
low  += f * band
high  = input - low - q * band
band += f * high
```

The dropdown selects which output to take. One structure, two options, and a
comment on the stability limit: `f = 2 * sin(pi * fc / fs)` misbehaves as `fc`
approaches `fs / 6`, so the cutoff is clamped well below it. That limit is a
classic thing to get bitten by.

### The Gate: How It Stops Screaming

Playback is gated on **hand presence**, not on a volume mapping. If neither
hand is tracked there is no sound, whatever the dropdowns say. A real theremin
is silent until you are in its field; this is the same idea and it cannot be
misconfigured.

| Layer | Behaviour |
|---|---|
| Presence gate | At least one hand tracked, or silence |
| Grace | 250 ms before gating off. Blob tracking drops frames when you turn a palm, and cutting instantly stutters. Same reasoning as app 1's face-loss grace |
| Fade | 150 ms ramp on every gate transition. Gating amplitude instantly is a discontinuity, and a discontinuity is a click |
| Arm / disarm | An explicit button, so it can be silenced without waving at it |
| Master gain | Always present, even when no hand is mapped to volume |
| Face gate | Optional, off by default. No player in frame, no sound. Right for an unattended installation, wrong while you are learning to play it |

## Mapping

Each hand gets a dropdown. The control axis is the blob's **vertical position**,
because with blob tracking Y is the most reliable: X is confounded by which side
of the face the hand is on. Blob *area* approximates distance from the camera
and is the truer theremin axis, so switching to it is a documented one-line
change with the tradeoff written out.

| Option | Parameter |
|---|---|
| None | Unmapped |
| Volume | Amplitude |
| Pitch | Playback rate. Changes pitch and duration together; see [Sample Playback](#sample-playback) |
| Position | Scrub the playhead. Heavily smoothed, or it is unusable |
| Low-pass | SVF, low output |
| High-pass | SVF, high output |

**Duplicates:** selecting a parameter the other hand already owns flips that
other hand to None. Two hands fighting over one value is confusing to play and
worse to debug.

## Media

**The sample.** WAV, 16-bit mono, 22.05 or 44.1 kHz, a few seconds, bundled in
`assets/`. Swapping it is one constant, and the app also reads
`/sdcard/theremin/` the way Signboard reads its sign directory, so
`adb push loop.wav /sdcard/theremin/` works with no rebuild. A generated
placeholder tone ships until the real sample is supplied, so the app always
runs.

**The watermark.** `assets/watermark.png`, defaulting to the Get Circuit Bent
cat logo, drawn over the camera feed. It gets its own commented block with
constants for corner, margin and opacity, because it is the first thing any
integrator changes and it should take thirty seconds to find.

## Face Tracking and Blink

The robot watches the player. Face centre maps to eye and neck targets through
the same tween app 1 uses, with the same fixation deadzone, face-loss grace and
drift-back-to-neutral. Blinking comes straight from Signboard's `IdleScene` and
`Gestures`, unmodified.

Deliberately simpler than a dedicated tracking app would be: no IoU
cross-frame tracker, no multi-face arbitration, no puppet mirroring. This app's
subject is audio, and an over-built tracker would bury it.

## Sample Recorder (Opt-In)

Row 17, shipped the same way app 1 ships kiosk mode: present but inert.

Hold a button, Mabu records a few seconds through its microphone, and that
becomes the sample being played. `AudioRecord` at 16 kHz mono, resampled into
the engine's rate.

`RECORD_AUDIO` stays **commented out** in the manifest. Enabling it is
uncomment, rebuild, `pm grant`, all documented in the README. Same two-step
shape as autostart in app 1, and for the same reason: turning on a microphone
is a decision someone should make deliberately.

## File Map

Copied from `01-signboard` **verbatim**, and listed in `CORE.md` with the rule
that a change to one is a change to both:

`cpp/serial.c`, `SerialPort.kt`, `MabuProtocol.kt`, `MotorLink.kt`,
`MotorTween.kt`, `Poses.kt`, `Gestures.kt`, `IdleScene.kt`, `DeviceInfo.kt`

Copying rather than sharing a module is deliberate: every sample must build
after being dragged out of the repo on its own. That is worth more than
avoiding duplication.

New in this app:

| File | Rows |
|---|---|
| `Camera1Source.kt` | 12. Camera1 wrapper, NV21 frames, dedicated thread, buffer pool |
| `FaceDetector.kt` | 13. ML Kit bundled detector, FAST mode |
| `ChromaBlobTracker.kt` | **26.** The star. Face-calibrated YCbCr match window with luminance-adaptive tolerance, blob extraction, frame-to-frame association, manual and marker calibration |
| `CameraOverlayView.kt` | 13, 26. Preview, face box, hand boxes, watermark |
| `FaceFollow.kt` | 14. Face centre to motor targets |
| `AudioEngine.kt` | 18, 27. AudioTrack thread, block loop, parameter ramps, gate |
| `SamplePlayer.kt` | 27. Resampling, playhead position, pitch as rate |
| `Filter.kt` | 27. State-variable filter |
| `Mapping.kt` | Hand to parameter mapping and the dropdown options |
| `SampleRecorder.kt` | 17, opt-in |
| `ControlReceiver.kt` | 20. Adapted: arm, disarm, set mapping, set sample |
| `MainActivity.kt` | The page |

## Project Layout

```
sample-apps/02-theremin/
  SPEC.md, README.md, CORE.md
  scripts/install.ps1
  gradlew, gradlew.bat, gradle/wrapper/
  app/src/main/{cpp,java,res,assets}
```

Standalone Gradle project. Package `com.getcircuitbent.mabu.theremin`.
ML Kit pinned at `com.google.mlkit:face-detection:16.1.7`, which is known to
ship `armeabi-v7a` and to work on this device. The pin gets a comment: a newer
release dropping armv7 is exactly how this would break silently, and MediaPipe
has already done it once.

## Build Order

1. **Core transplant.** Copy app 1's motor files, confirm the robot still moves.
2. **Camera and face.** Rows 12 and 13, with the overlay. Verify the 10 fps
   ceiling and the inference time on hardware rather than trusting this spec.
3. **Blob tracker.** Row 26. Needs hardware and several people; tolerances and
   minimum blob size cannot be tuned from a desk, and the skin-tone acceptance
   gate is part of this step, not a later check.
4. **Audio engine.** Rows 18 and 27, driven by on-screen sliders first, so the
   synth can be proven before hands are in the loop.
5. **Join them.** Hands to mapping to audio, plus the gate.
6. **Face follow and blink.** Row 14.
7. **Watermark, README, scripts, safety card.**
8. **Recorder add-on.** Row 17.

Steps 2, 3 and 5 need the operator present. Step 3 in particular is a tuning
session, not a test.

## Open Items

- **The sample file.** Supplied by the operator. A generated placeholder ships
  until then.
- **Blob tolerances.** Every default in `ChromaBlobTracker` is a starting guess
  until step 3.
- **Skin-tone validation.** Tracking must be exercised across a range of skin
  tones, bright and dim, before the app is called done. Needs several people
  and cannot be faked from a desk. See the acceptance gate above.
- **Audio buffer size.** 1024 frames is an estimate. If underruns show up in
  the perf line, it goes up, and the README records the number that worked.

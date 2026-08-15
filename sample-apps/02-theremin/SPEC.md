# Sample App 2: Mabu Theremin

> **Status: in development, not yet hardware-validated.** The design is locked
> and the app is built, but it has not been tested on a real Mabu. Sample App 1
> (Signboard) is the hardware-validated one; this is next in line.

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
| Camera location | **Chest tablet, static, angled up.** It does NOT move with the head. `MABU_MOTOR_GUIDE.md` said otherwise until this app corrected it; the `Y_OFFSET = -0.70` calibration is the giveaway, since it exists to shift the tracking centre up for a camera mounted below the eye axis |
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

### What We Do Instead: Two Trackers, One Interface

A theremin needs two continuous numbers, not twenty-one landmarks. So: find
the two largest interesting regions that are not the face, take their
positions, done.

There are two good ways to decide what "interesting" means, they have opposite
strengths, and **the app ships both behind a toggle**. That is the best
structural idea in this sample, and it is worth more than either technique on
its own.

**The camera is static.** It sits in the chest tablet, angled up, and it does
not move when the head turns. No part of the robot enters its field of view,
so there is nothing to mask out. That single fact is what puts motion tracking
back on the table: with a fixed camera, anything that changes between frames is
a thing that moved in the room, not the camera moving past the room. On a
head-mounted camera this whole option would be dead.

#### The Structure

The two trackers differ in **exactly one function**: how they turn a frame into
a binary mask of interesting pixels. Everything after that is shared.

```
    Frame (NV21)
         |
         +--> MotionMask  (luminance changed?)     \
         |                                          }--> mask
         +--> ToneMask    (chroma matches target?)  /
                                    |
                     [ shared from here down ]
                     exclude the face box
                     extract connected blobs
                     drop blobs below minimum size
                     take the largest two
                     associate with last frame, smooth
                     assign left/right by X
                                    |
                              Hand positions
```

`HandTracker` is an interface with one method. `MotionMask` and `ToneMask`
implement it. `BlobExtractor` does everything below the line and never knows
which one produced the mask. Swapping techniques at runtime is a field
assignment.

This is the lesson: a tracker is an *interface*, and the technique is an
implementation detail you should be able to change your mind about. Most
computer-vision sample code welds the two together and is impossible to
experiment with as a result.

#### MotionMask (the default)

A running-average background model on the luminance plane:

```
background = background * (1 - adaptRate) + frame * adaptRate
mask = |frame - background| > threshold
```

| | |
|---|---|
| Cost | ~3 ms subsampled. The cheapest thing in the app |
| Calibration | **None.** Works the moment the app opens |
| Skin tone | **Irrelevant.** It only looks at luminance change |
| Weakness | A hand held perfectly still dissolves into the background |
| Weakness | Anything else moving is a candidate, and shadows count as motion |

`adaptRate` is a slider, and it is the most instructive control in the app
because it exposes a real tradeoff with no right answer: adapt fast and a held
hand vanishes in a second; adapt slowly and you get ghosts trailing your last
few positions. Playing with it teaches more about background modelling than a
page of prose.

The held-hand weakness is the honest reason this mode is "easier to demo, less
accurate": waving works instantly, sustaining a note fights the algorithm.

#### ToneMask (the accurate one)

Match chroma against a calibrated target:

```
mask = |Cb - targetCb| < tolCb && |Cr - targetCr| < tolCr
```

| | |
|---|---|
| Cost | ~6 ms subsampled |
| Calibration | Required. Tap a marker, or derive from the face |
| Skin tone | See below. No fixed constants are shipped |
| Strength | **A still hand stays tracked indefinitely** |
| Strength | With a coloured glove or marker, very precise and very robust |
| Weakness | Lighting shifts move the target; needs recalibration across rooms |

**A brightly coloured glove or marker is the recommended way to use this
mode.** A saturated colour that nothing else in the room shares gives a tight
match window, no confusion with furniture, and reliable tracking of a
motionless hand. It costs a prop and buys the accuracy that motion mode cannot
give you.

Since NV21 *is* YCbCr, matching chroma needs no colour conversion at all.
Converting to RGB to compare colours would be doing extra work to make the
problem harder.

#### Which To Use

| | Motion | Tone |
|---|---|---|
| Works instantly, no setup | Yes | No |
| Tracks a motionless hand | No | Yes |
| Unaffected by skin tone | Inherently | By design, see below |
| Needs props for best results | No | A coloured glove |
| Best for | Demos, gestural playing | Sustained notes, installations |

**Motion is the default**, because a sample app should do something the second
it opens, for anybody, with nothing in their hands. Tone is the upgrade you
switch to when you want to hold a note.

Budget either way: face detection (~35 ms) plus a tracker (3 to 6 ms) fits
inside the 100 ms frame with room to spare.

### Skin Tone: A Requirement, Not a Caveat

Applies to `ToneMask` only. `MotionMask` reads the luminance *change* between
frames and never looks at colour, so it is unaffected by skin tone. That is a
large part of why it is the default.

The textbook version of chroma tracking uses fixed YCbCr bounds, usually
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
| **A small luminance allowance.** The window widens slightly as Y falls | Covers sensor noise. Deliberately small: measurement showed that widening aggressively is self-defeating, because dim light compresses everyone's chroma toward neutral, so a wider window catches the background as readily as the hand. See [Dim Light](#dim-light-is-a-limit-not-a-bug) |
| **Manual calibration.** Hold a hand in the on-screen box and tap | Covers a face the detector never found, and hands that differ from the face |
| **Marker mode.** Calibrate to a brightly coloured object instead of a hand | Costs zero extra code, because the tracker already just matches a calibrated chroma. A guaranteed path for any player in any lighting |
| **Visible calibration readout**, e.g. `window: Cb 108 +/-14, Cr 148 +/-16, from face` | Makes a failure diagnosable instead of mysterious |

### Dim Light Is a Limit, Not a Bug

Established with `scripts/tone-sweep.py` over a synthetic luminance sweep, and
worth stating plainly because the first version of this spec claimed otherwise:

**Widening the match window in dim light does not help.** Low light does not
merely add noise to the chroma estimate, it compresses the chroma of the whole
scene toward neutral. The background approaches the target colour at the same
rate the target does, so separation shrinks and a more forgiving window admits
the wall along with the hand. Measured over the sweep, a widening factor of 1.5
took the matched fraction of the frame from 14 percent to 96 percent; a factor
of 0 held it flat at 14 percent.

The widening is therefore kept small (0.25) as an allowance for sensor noise
and nothing more. Dim light is a regime the tone tracker cannot be tuned out
of. The honest responses are the two the app already has: the quality readout
names the condition, and motion tracking is unaffected by light level because
it never looks at colour.

This matters for the skin-tone question specifically. Adaptive tolerance was
listed as a mitigation in an earlier draft; it is a weak one. The mitigations
that actually carry weight are: motion as the default, marker calibration,
shipping no colour constants, and reporting quality honestly.

**Acceptance gate.** Before this app ships, tone tracking must be validated
across a range of skin tones, in a bright room and a dim one. If acquisition is
materially worse for darker skin after face calibration, that is a bug to fix,
not a limitation to document. The fallbacks, in order, are motion mode (which
sidesteps the question entirely), a marker or glove, manual calibration, and a
wider default tolerance.

### What It Costs

Stated plainly, in the source, next to the code.

Both trackers:

- No left/right identity except by screen position, so crossing your hands
  swaps them.
- Long sleeves help, bare arms confuse things. The largest region may be a
  forearm rather than a hand.
- Only the two largest blobs survive, so a third moving object can displace a
  hand.

Motion only:

- A hand held still fades at a rate set by `adaptRate`. This is the mode's
  defining limitation, not a bug to be fixed.
- Shadows are motion. So is a curtain, a screen, or someone walking behind you.

Tone only:

- Lighting shifts move the target chroma; a room change means recalibrating.
- Anything matching the calibrated colour is a candidate. With skin
  calibration, wooden furniture and cardboard are the usual offenders; with a
  saturated marker, almost nothing is.

This is a worked example of reading the hardware and choosing the technique
that fits it, rather than the technique that would be correct on a phone. That,
the two-implementations-one-interface structure, and the calibration decision
above are why this app is worth writing.

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
| TRACK  ( MOTION )  tone      [ calibrate ]      |
| ARMED   master [====|=====]   hands: L+R       |
+------------------------------------------------+
| SAMPLE                                          |
| gcb-loop.wav · 3.2 s · 44.1k mono               |
| gate: presence · grace 250 ms · fade 150 ms     |
| [ ] also require a face                         |
+------------------------------------------------+
| TRACKING                                        |
| adapt rate / threshold / blob min size / smooth |
| face follow + blink (reused from Signboard)     |
+------------------------------------------------+
| PERF · HAL 10.0 fps · face 34 ms · track 3 ms   |
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
| `HandTracker.kt` | **26.** The interface, one method: frame in, mask out. The whole point of the app's vision layer |
| `MotionMask.kt` | **26.** Running-average background model on luminance. Default tracker, no calibration, tone-independent |
| `ToneMask.kt` | **26.** Chroma match against a calibrated target, luminance-adaptive tolerance, face and marker calibration. Ships no colour constants |
| `BlobExtractor.kt` | **26.** Shared: face exclusion, connected blobs, size filter, association, smoothing, left/right assignment |
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
3. **Hand tracking.** Row 26. `HandTracker` plus `BlobExtractor` first, then
   `MotionMask` (which needs no calibration and so proves the pipeline), then
   `ToneMask`. Needs hardware and several people; tolerances and minimum blob
   size cannot be tuned from a desk, and the skin-tone acceptance gate on tone
   mode is part of this step, not a later check.
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
- **Tracker tolerances.** Every default in `MotionMask` and `ToneMask` is a
  starting guess until step 3.
- **Skin-tone validation.** Tone tracking must be exercised across a range of
  skin tones, bright and dim, before the app is called done. See the acceptance
  gate above.

  Where live testing is not available, `scripts/tone-sweep.py` plus the
  in-app replay harness get part of the way: capture one real frame, synthesise
  darker and dimmer variants that model the luminance drop AND the loss of
  signal-to-noise that comes with it, and replay them through the real pipeline
  on the real hardware. That is what found the tolerance bug above, so it is
  not a token gesture - but it is a MODEL. It cannot certify that the app works
  for real people, because real skin differs spectrally rather than by a
  brightness scale, and a real camera's auto-exposure responds to the whole
  scene. A pass means "the obvious failure is absent". The gate stays open.
- **Audio buffer size.** 1024 frames is an estimate. If underruns show up in
  the perf line, it goes up, and the README records the number that worked.

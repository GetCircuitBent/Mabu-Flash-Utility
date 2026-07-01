# Mabu animation calibration

How we systematically verify and tune the whole **face → motor** pipeline, so
the robot's eyes/head track you correctly and feel alive, not by guessing the
"magic numbers" but by deriving them from data, bottom-up.

This is a living document: the **procedure** is fixed, the **per-unit values**
at the bottom get updated whenever a robot is (re)calibrated.

---

## Guiding principles

1. **Calibrate bottom-up.** Each stage assumes the one below it is correct.
   Tuning the *feel* (smoothing/jitter) on top of a wrong *mapping* is building
   on sand: that's how "head tilt doesn't match" survives a dozen jitter tweaks.
2. **Mirror, not copy.** Mabu is face-to-face with you, so it moves like your
   reflection: you turn your head to *your* right → Mabu turns to *its* left.
   Signs are chosen to achieve this.
3. **Fill the range; exaggerate for life.** We are NOT matching physical angles
   degree-for-degree. A motor's `0`/`100` are just hard-stops at whatever physical
   extent that unit has (not 180°, not symmetric). The goal: map your *comfortable*
   input range onto Mabu's *full* motor range, slightly exaggerated, so normal
   movement uses Mabu's whole range and it never looks static. "Gain/range" really
   means *"what input saturates the motor"*; smaller input-range = more animated.
4. **Eyeball ground truth is fine.** We want it to *look* matched/lively, not to
   pass a protractor test. Use the reported sensor values as the reference and
   your eye as the judge.
5. **One source of truth per number.** Every magic number lives in exactly one
   place (a `MabuMotors` const, a `TuningSettings` field, or a mapping formula)
   and is documented here with which stage owns it.

---

## The pipeline: 4 stages, each with its own transfer function

```
camera ─► ML Kit ──[1 SENSE]──► yaw/pitch/roll°, pupilΔxy, eyeOpenL/R, faceBox(screen xy)
                  ──[2 MAP]─────► neck / eye / lid TARGETS    (signs, ranges, gains, neutrals)
                  ──[3 DYNAMICS]► tween + deadband + gates     (alphas, deadbands, latches)
                  ──[4 ACTUATE]─► motor cmd 0–100 → wire byte → physical motor (neutral/range/dir)
```

Calibrate in the order **ACTUATE → SENSE → MAP → DYNAMICS** (4→1→2→3): the
hardware first (what does a value physically do), then the sensor (what does the
camera report), then the mapping that joins them, then the feel.

### Where every magic number lives

| Stage | Numbers | Home |
|---|---|---|
| ACTUATE | per-motor neutral, min/max, direction | `MabuMotors` consts + this doc's per-unit table |
| SENSE | sensor sign, resting bias, usable range | derived (Stage-2 capture), not stored in code |
| MAP | `neckAngleRange`, `eyeGazeGain`, `neckRotSign/ElevSign/TiltSign`, `gazeYOffset`, screen-xy scale | `TuningSettings` + `updatePuppetFrom` |
| DYNAMICS | `smoothAlpha*`, `eyeGazeInputAlpha/Deadband`, `eyelid*` (coupling, winkOpen, closeLevel, holdMs, pose gate) | `TuningSettings` |

---

## Stage 4: ACTUATE (motor hardware)

**Goal:** know, per motor, the value that is *visually neutral*, the values that
hit the *clean hard-stops* (no grinding), and the *direction* (does a higher
value move the part which way).

**Ground truth:** physical observation (eyeball).

**Procedure (motor exerciser, tooling TODO):** drive ONE motor at a time through
`neutral → low extreme → neutral → high extreme → neutral`, pausing at each, and
confirm:
- neutral looks centered/relaxed,
- each extreme is a clean hard-stop (no grinding, no buzz),
- direction matches the label below.

**Note:** neutral is NOT always 50. Eyelids rest near "mostly open", which is a
low value, not the mid-point. Record the *defined* neutral per motor.

Current unit-4 truth (from the motor guide; verify on exercise):

| Motor | Neutral | 0 = | 100 = | Notes |
|---|---|---|---|---|
| LDL/LDR (eyelids) | ~20–25 † | max open (hard stop) | fully closed | †code const vs guide mismatch; see open issues |
| ELR (eyes L/R) | 50 | max LEFT | max RIGHT | |
| EUD (eyes U/D) | 50 | max UP | max DOWN | **inverted**; EUD=0 oscillation bug (≥2 s settle) |
| NE (neck elev) | 50 | max DOWN | max UP | higher = look up |
| NR (neck rot) | 50 | max RIGHT | max LEFT | |
| NT (neck tilt) | 50 | tilt RIGHT | tilt LEFT | |

---

## Stage 1: SENSE (what ML Kit reports)

**Goal:** for each signal, learn its **sign**, **resting bias** (what it reads
when you're neutral; this is where a stray "47" hides), and **usable range**
(how far it swings in normal use). Do NOT assume ML Kit's sign conventions:
measure them.

**Ground truth:** *you*, in named reference poses.

**Procedure (sense-capture protocol, tooling TODO):** the harness prompts a
pose, you hold ~3 s, it logs the median of every telemetry field:

| Pose | Reads out | Establishes |
|---|---|---|
| Face straight, eyes center | yaw/pitch/roll, pupilΔ, faceBox center | **resting bias** (should be ~0 / centered; biases found here) |
| Turn head right (comfortable) | yaw sign + magnitude | yaw sign; comfortable yaw range |
| Turn head left | yaw | symmetry |
| Tilt head right / left | roll sign + magnitude | **roll sign (the head-tilt fix)**; tilt range |
| Nod up / down | pitch sign + magnitude | pitch sign; pitch range |
| Eyes far left / right (head still) | pupilΔx | pupil x sign + swing |
| Eyes up / down | pupilΔy | pupil y sign + swing |
| Blink, then wink each eye | eyeOpenL/R | open/closed/partial levels; L-vs-R labels |

Output: a table of `(signal: restingBias, sign, usableRange)`, the inputs Stage 2
needs. The resting-bias column is what surfaces the mystery "47".

---

## Stage 2: MAP (sensor → motor target)

**Goal:** turn a sensed value into a motor target that **mirrors** you and
**fills Mabu's range with exaggeration**.

**General transfer (per degree-of-freedom):**

```
target = neutral  +  sign * clamp( (sensed - restingBias) / inputRange , -1, +1 ) * outHalf
```

- `restingBias`, `sign`, and the natural `inputRange` come from Stage 1.
- `inputRange` = the input magnitude that should drive the motor to its extreme.
  **Set it SMALLER than your true range to exaggerate** (e.g. if you comfortably
  turn ±25° but we set `inputRange = 18°`, a normal turn already saturates Mabu:
  lively, not static).
- `sign` is flipped to mirror (Stage-1 sign ⊕ desired mirror direction).
- `outHalf` = how far from neutral we allow (≤ the motor's safe half-range).
- `neutral`, hard-stops from Stage 4.

**Today this is `motorFromAngle(angle * sign)` with a single `neckAngleRange`
for all neck axes**: a simplification. Calibration may split it per-axis
(`yawRange`, `pitchRange`, `rollRange`) and add per-axis `outHalf` so each DOF
fills its own range. Eyes use `eyeGazeGain` on the pupil offset; that's the same
formula with `inputRange = 0.5/eyeGazeGain`.

**Mirror cheat-sheet (to verify after setting signs):**

| You do | Mabu should | Drives |
|---|---|---|
| turn head to your right | turn to ITS left (toward your right hand) | NR |
| tilt head to your right | tilt to ITS left | NT |
| look up | look up | NE / EUD |
| eyes dart right | eyes dart to your right | ELR |

**Screen-space note:** the preview is mirrored (selfie). Pin the convention ONCE
here so FOLLOW (face-box position) and PUPPET (pupil offset) agree on which way
is "right". Document the chosen origin/axis/mirror so the two paths can't drift.

---

## Stage 3: DYNAMICS (the feel)

Only meaningful once 4/1/2 are right. Tuned with `pc-brain/mabu_tune.py` against
the telemetry. Params + what we've learned:

| Param | Effect | Notes |
|---|---|---|
| `smoothAlphaEyes/Neck` | output tween speed | lower = smoother, more lag |
| `eyeGazeInputAlpha` | low-pass on noisy pupil | |
| `eyeGazeDeadband` | fixation hold | eyes steady at rest; too high = frozen/laggy |
| `eyeGazeGain` | eye exaggeration | **keep ≤ 1.5**: 2.0 amplifies noise past the deadband |
| `eyelidCoupling` / `eyelidWinkOpen` | two-eye blink vs wink | high coupling + winkOpen ~0.8 closes both on a real blink, keeps winks |
| `eyelidCloseLevel` / `eyelidBlinkHoldMs` | crisp full blink | latch a full closure through a 1-frame blink |
| `eyelidOpenInputAlpha` | partial-closure (squint) smoothing | |
| `eyelidPoseSoftDeg` / `eyelidPoseLimitDeg` | head-pose reliability gate | past these angles the far eye is occluded → bias lids open (stops "wink when looking away") |

**Measured so far:** properly framed, eye rest-jitter is ~0 at defaults; the big
jitter (~11) was Mabu off to the side (occlusion): the same root as the eyelid
issue. Candidate next step: extend the **pose-reliability gate to eye gaze** (when
turned, freeze eyes toward center instead of chasing the unreliable pupil).

---

## Open issues to resolve during calibration

- **The "47" offset**: a resting reading of ~47 where ~50/neutral is expected.
  Identify which signal (motor pos? target? a head angle?) and trace it; the
  Stage-1 resting-bias capture surfaces all of them at once.
- **Head-tilt mismatch**: roll→NT sign/scale and/or NT motor direction; resolve
  with the Stage-1 roll sign + the Stage-4 NT direction, then set `neckTiltSign`.
- **Eyelid neutral discrepancy**: `MabuMotors.EYELID_NEUTRAL = 25` but the guide
  records 20. Pick one (Stage 4) and make code + guide agree.
- **Single `neckAngleRange` for all 3 neck axes**: yaw/pitch/roll likely want
  different input ranges; consider per-axis.
- **Screen-space mirror consistency** between FOLLOW and PUPPET.

---

## Tooling roadmap (build against this doc)

1. **Motor exerciser** (calibration mode): step one motor through known values on
   command, for Stage 4.
2. **Telemetry additions**: expose the raw sensing the mapping hides: face-box
   center (screen xy), eye-landmark positions, and resting/neutral values, so
   "sensor says X, motor does Y" is visible. (`/status` already has head angles,
   pupil raw/filtered, eye-open, motor positions, pose reliability.)
3. **Harness protocols** in `mabu_tune.py`: `calibrate sense` (reference-pose
   capture → derived signs/biases/ranges), `calibrate map` (suggest gains/ranges
   to fill the motor range), and `validate` (re-run a fixed suite, flag drift).
4. **This doc's per-unit table**, kept current.

---

## Validation suite (run after any calibration change)

- [ ] Each motor: neutral centered, both extremes clean, direction correct.
- [ ] Mirror check (the cheat-sheet table) passes for all 4 head/eye moves.
- [ ] Resting biases ≈ 0 / neutral (no stray offsets).
- [ ] Normal head movement drives Mabu near its range extremes (not static).
- [ ] Two-eye blink closes both lids; wink closes one; partial = steady squint.
- [ ] Looking away does NOT false-close an eye (pose gate engages).
- [ ] Eye rest-jitter < ~1 motor unit when framed and still.

---

## Per-unit calibration record

### Unit 4 (10.0.0.69)

_Mapping params (`TuningSettings`), current; update as calibrated:_

| Param | Value | Stage | Status |
|---|---|---|---|
| neckRotSign / ElevSign / TiltSign | -1 / 1 / 1 | MAP | to verify for **mirror** |
| neckAngleRange | 30 | MAP | to set for range-fill/exaggeration |
| eyeGazeGain | 1.5 | MAP/DYN | ≤1.5 confirmed |
| gazeYOffset | 0.10 | MAP (calib) | was scrambled to 0.3; reset to 0.10 |
| eyeGazeInputAlpha / Deadband | 0.35 / 0.06 | DYN | |
| eyelidCoupling / WinkOpen | 0.8 / 0.8 | DYN | blink test pending |
| eyelidCloseLevel / BlinkHoldMs | 0.30 / 120 | DYN | |
| eyelidOpenInputAlpha | 0.45 | DYN | |
| eyelidPoseSoftDeg / LimitDeg | 15 / 32 | DYN | |

_Motor truth: see the Stage-4 table above; reconcile EYELID_NEUTRAL._

#### Stage-1 SENSE capture (first run)

| signal | resting bias | sign | usable span | notes |
|---|---|---|---|---|
| yaw | +0.9 | **+ = head LEFT** | ~129 (L+53 / R−76) | clean |
| pitch | **+18.5** | suspect | ~14 | kiosk-tilt bias; nod-up lost tracking → RECAPTURE |
| roll | +1.7 | **+ = tilt RIGHT** | ~36 | left-tilt was shallow (+5.8) → recapture left |
| pupil_x | +0.02 | **+ = eyes LEFT** | 0.79 | clean |
| pupil_y | **+0.43** | **+ = eyes DOWN** | 0.62 | big rest bias (kiosk / close distance) |
| eye_open | L 0.95 / R 0.86 | N/A | closed L 0.06 / R 0.23 | right-eye closed only reaches 0.23 |
| face_ctr | (0.54, 0.55) | N/A | N/A | ~centered; the "47" wasn't here |

**Conclusions / action items from this capture:**
1. **MAP must subtract resting bias.** The current `motorFromAngle(angle*sign)` has no
   bias term, so pitch **+18.5°** and pupil_y **+0.43** push neck-elev and eye-Y off
   neutral *while looking straight*. Add the `(sensed − restingBias)` term: top priority.
2. **Kiosk look-up.** The tablet is mounted tilted up; when the user is close their
   face sits high in the FOV and Mabu should **look up**. Drive eye/neck-Y from
   `face_center_y` (and maybe `face_width_frac` as a proximity proxy) instead of a
   static `gazeYOffset`. Design in Stage 3.
3. **Recapture pitch (nod) and left-roll**: both were unreliable this run (nod-up lost
   the face; left-tilt was shallow). The new in-line retry should make the redo clean.
4. **Mirror signs** (derivable now): yaw `+`=left, roll `+`=tilt-right, pupil_x `+`=left,
   pupil_y `+`=down. Set `*Sign` so Mabu reflects the user.
5. Right-eye closed prob bottoms at 0.23 → keep `eyelidCloseLevel` ≥ ~0.30 with margin,
   or rely on coupling so the left eye (0.06) drives both.

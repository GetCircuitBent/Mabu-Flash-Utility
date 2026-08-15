# Mabu Motor Guide

> **CRITICAL REFERENCE: load this document at the start of every Mabu session.**
> Covers the motor protocol, wire encoding, per-motor limits and neutrals, movement directions,
> serial access, and known gotchas. Mistakes here cause silent failures or grinding.

## Current State (as of 2026-06-04, End-of-Session Tuning Pass)

**Known remaining issue:** faint EUD rattle persists when the face is hovering at the
bottom edge of the frame. Send rate is down to roughly 0–5 sends/sec at the edge
(see diagnostic in `MabuMotors.moveAll`); the residual is the unavoidable cost of
the tween still emitting periodic 1–3 wire-step updates as the face position
drifts inside the deadzone band. Further reduction would require either bigger
deadzones (visible step-jumps) or a heartbeat-style send strategy that holds the
servo command stable for fixed intervals. Left for the next session.



**Motor control: WORKING via native JNI, no bridge required.**

- App: `facetrackadb` (`com.mabu.facetrackadb`) at `X:\Claude\Mabu\facetrackadb\`
- `facetrackadb` is the **sole home launcher**: auto-starts on every boot.
- Serial access: native C `open("/dev/ttyS1")` via JNI. No SELinux denial, no bridge.
- **Decoupled tween architecture** (2026-06-04): detection thread (10 Hz) writes targets only; a dedicated 25 Hz `mabu-tween` HandlerThread LP-filters position toward targets and owns ALL motor I/O. Kendrick-pattern, see Section 14.
- **`SEND_DEADBAND` in MabuMotors (1.0 motor units)**: `moveAll` skips the wire frame if no motor has changed by ≥ ~2.5 wire steps from what was last sent. Load-bearing fix for servo rattle: collapses each LP-tween convergence into one or two wire frames rather than a stream of micro-updates.
- **Per-axis fixation deadzones (`TARGET_DEADZONE = 0.5` horizontal, `TARGET_DEADZONE_UD = 2.5` vertical)**: `updateTargets` only commits a new target if it differs from the current target by more than the threshold for that axis. Wider UD band absorbs the heavier bbox jitter at the top/bottom edges of the frame.
- **Persistent input EMA across face drops (`TARGET_SMOOTH = 0.4`)**: `smoothedXNorm/YNorm` are NOT reset on grace expiry or new-face confirm; re-seeding caused the eye to snap to ML Kit's first re-acquire frame which was often a hallucinated edge-clipped position. Keeping state means the first new sample blends 40/60 with the pre-drop position.
- **In-frame face selection**: when ML Kit returns multiple faces (common on fresh boot during autoexposure settle), prefer the confirmed-ID face, then the face with highest IoU vs predicted bbox, then the largest face WHOSE CENTER IS INSIDE THE IMAGE, then last-resort largest-overall. Old "biggest area" heuristic locked onto phantoms whose bbox extended off-screen.
- **Zero-overlap IoU rejection**: when the tracker is alive but the new bbox shares ZERO pixels with the predicted position, reject the detection entirely. It's almost certainly a different physical face or a phantom; eye holds, no target update, no tracker poisoning.
- **IoU cross-frame tracker** (session 19): maintains bbox + velocity estimate independent of ML Kit IDs. When ML Kit reassigns an ID to the same physical face, IoU with the predicted position is high → accepted immediately with no hysteresis. See Section 14.
- **FACE_LOSS_GRACE_MS = 1000 ms**: within grace, targets hold; past grace, the tween pulls targets toward neutrals via `RETURN_ALPHA = 0.05` for a gentle drift.
- **Camera on dedicated `mabu-camera-vision` HandlerThread** (session 18) at `THREAD_PRIORITY_BACKGROUND - 5` (nice +5).
- **4 callback buffers**: reduces backpressure drops to ~1/50 frames.
- **Debug overlay rate-limited to 4 Hz**: main-thread TextView re-layout per frame was preempting the camera thread.
- **Three-tier perf instrumentation**: HAL arrival cadence, ML Kit inference time + histogram, end-to-end pipeline interval. Logged every 50 frames. See Section 15.

**Removed 2026-06-04** (now replaced by the decoupled tween + send-deadband, do not re-introduce):
slew window (`ID_TRANSITION_FRAMES`/`MAX_RATE`), EUD/NE asymmetric rate caps, `SMOOTH`/`DEADBAND`/`SEND_INTERVAL_MS`, the inline `motors.moveAll` in the empty-faces grace path, and `deadbandSmooth()`. See Section 14 for rationale.

---

## 1. Physical Motors

| Motor | Bitmask | Name               | Controls                    |
|-------|---------|--------------------|-----------------------------|
| LDL   | `0x40`  | Eyelid Left        | Left eyelid open/close      |
| LDR   | `0x20`  | Eyelid Right       | Right eyelid open/close     |
| ELR   | `0x10`  | Eyes Left/Right    | Both eyes pan horizontally  |
| EUD   | `0x08`  | Eyes Up/Down       | Both eyes tilt vertically   |
| NE    | `0x04`  | Neck Elevation     | Head pitch (up/down)        |
| NR    | `0x02`  | Neck Rotation      | Head yaw (left/right)       |
| NT    | `0x01`  | Neck Tilt          | Head roll (side lean)       |

All-motors mask: `0x7F`

---

## 2. Value Encoding

Logical values are **0–100** (50 = nominal center for most motors).

```
wire_byte = clamp(round(logical * 2.55), 0, 255)
```

### Critical: Floating-Point Trap
`50 * 2.55` in IEEE 754 double = **127.4999…**, not 127.5.
Standard "round half up" gives **127**, not 128.
Always verify: `wire(50) = 128 (0x80)`, `wire(25) = 64 (0x40)`.

**PowerShell gotcha:** `[math]::Round(50 * 2.55)` returns `127` due to FP representation.
Safe formula: `[byte][math]::Floor($v * 255.0 / 100.0 + 0.5)`

---

## 3. Serial Frame Format

```
FA 00 <payload_len> <payload_bytes…> <fletcher_s2> <fletcher_s1>
```

- Header is always `FA 00`
- `payload_len` = number of payload bytes (1 byte)
- Checksum is **Fletcher-8 mod 255** (not 256) over the **entire frame including the `FA 00` header**

### Fletcher-8 Algorithm
```
s1 = 0, s2 = 0
for each byte b in frame (including FA 00 header):
    s1 = (s1 + b) % 255
    s2 = (s2 + s1) % 255
append s2, then s1
```

### Multi-Motor Payload (Preferred, One Atomic Frame)
```
[0x01, bitmask, 0x01, val_motor_MSB, val_motor_next, …]
```
Values are listed in **MSB-first bitmask order**: LDL → LDR → ELR → EUD → NE → NR → NT.
Only include values for bits set in the bitmask.

**Wrong bitmask = silent discard by motor board.** No error, no movement.

### Single-Motor Payload
```
[0x01, single_bitmask, 0x01, wire_value]
```

### Power-On Frame (Hardcoded)
```
FA 00 02 4F 7F 0B CB
```

#### Cold-Boot Wake-Up Sequence (CRITICAL: Confirmed 2026-05-29)
After a fresh Mabu boot, **sending power-on ONCE is not enough.** The motor board
will silently ignore subsequent commands even though bytes are reaching `/dev/ttyS1`
and the motors are clearly powered (head stiff, holding position).

**Working wake-up sequence, must do this once per cold boot:**
```
1. Send power-on (FA 00 02 4F 7F 0B CB)
2. Wait 200 ms
3. Repeat steps 1-2 a total of 5 times
4. Wait 1000 ms
5. Send the first movement command
```
All of the above MUST happen inside a single TCP connection to the bridge (or a
single open of `/dev/ttyS1`). Splitting it across multiple connections has been
observed to fail.

Once the board has been woken this way, subsequent connections only need a single
power-on (or none at all); the board stays alive until the next cold boot.

**Why this is needed:** Empirically determined. Likely the motor-board MCU has a
post-boot init period during which it drops UART bytes, so the first few power-on
frames are lost. Multiple repetitions ensure at least one lands after the MCU is
ready to receive.

### Wait ~500 ms after Power-On before Sending Movement Commands
(only applies once the board is already awake, not for the cold-boot sequence above)

---

## 4. Neutral Positions (This Unit, Visually Confirmed 2026-05-29)

| Motor | Neutral | Notes |
|-------|---------|-------|
| LDL   | 20      | **Updated 2026-05-29, approved by operator.** wire=0x33=51. Mostly open. For max open drive to 0. Previous value of 25 was incorrect. |
| LDR   | 20      | **Updated 2026-05-29, approved by operator.** wire=0x33=51. Matches LDL. For max open drive to 0. Previous value of 25 was incorrect. |
| ELR   | 50      | **Confirmed 2026-05-29, approved by operator.** wire=0x80=128. |
| EUD   | 50      | Confirmed |
| NE    | 50      | **Updated 2026-05-29, approved by operator.** wire=0x80=128. Head level at 50. Previous value of 25 was incorrect. |
| NR    | 50      | **Updated 2026-05-29, approved by operator.** wire=0x80=128. Head straight at 50. Previous value of 42 was incorrect. |
| NT    | 50      | **Updated 2026-05-29, approved by operator.** wire=0x80=128. Head level at 50. Previous value of 45 was incorrect. Direction: lower=right tilt, higher=left tilt. |

Test: from a fresh-boot "head-back + neck-turned-left + eyelids-half + eyes-up"
rest pose, sending all 7 motors at the above neutrals returns the head to
straight-and-centered. Confirmed visually by user 2026-05-29.

---

## 5. Motor Ranges (This Unit)

| Motor | Soft Min | Soft Max | Notes |
|-------|----------|----------|-------|
| LDL   | 0        | 100      | Full 0–100 confirmed 2026-05-29, approved by operator. 0 = max open hard stop, 100 = fully closed. No grinding at either extreme. |
| LDR   | 0        | 100      | Full 0–100 confirmed 2026-05-29, approved by operator. Matches LDL. 0 = max open hard stop, 100 = fully closed. No grinding at either extreme. |
| ELR   | 0        | 100      | Full 0–100 confirmed 2026-05-29, approved by operator. No grinding at either extreme. |
| EUD   | 0        | 100      | Full 0–100 confirmed 2026-05-29, approved by operator. No grinding at either extreme. 0 = max up, 100 = max down (inverted). Oscillation bug root-caused and fixed 2026-06-02 via EUD_MAX_RATE cap; see Section 12. |
| NE    | 0        | 100      | Full 0–100 confirmed 2026-05-29, approved by operator. No grinding at either extreme. Community docs say 50 max, WRONG for this unit. Previous lower limit of 18 was also wrong. |
| NR    | 0        | 100      | Full 0–100 confirmed 2026-05-29, approved by operator. No grinding at either extreme. |
| NT    | 0        | 100      | Full 0–100 confirmed 2026-05-29, approved by operator. 0 = fully right, 100 = fully left. No grinding at either extreme. |

> **Community docs warning:** Many online references state NE hard-stops at logical 50, and earlier testing on this unit suggested a lower limit of 18. Both are wrong: full range [0, 100] confirmed 2026-05-29, approved by operator.

---

## 6. Movement Directions (This Unit)

| Motor | Higher value → | Lower value → |
|-------|---------------|---------------|
| LDL   | Eyelid CLOSES   | Eyelid OPENS (0 = max open hard stop) |
| LDR   | Eyelid CLOSES   | Eyelid OPENS (0 = max open hard stop) |
| ELR   | Eyes look RIGHT (100 = max right hard stop) | Eyes look LEFT (0 = max left hard stop) | Both extremes confirmed 2026-05-29, approved by operator |
| EUD   | Eyes look DOWN (100 = max down hard stop) | Eyes look UP ← **INVERTED** (0 = max up hard stop) | Both extremes confirmed 2026-05-29, approved by operator |
| NE    | Head tilts UP (100 = max up) | Head tilts DOWN (0 = max down) | Both extremes + direction confirmed 2026-05-29, approved by operator |
| NR    | Head turns LEFT (100 = max left hard stop) | Head turns RIGHT (0 = max right hard stop) | Both extremes confirmed 2026-05-29, approved by operator |
| NT    | Head tilts RIGHT (0 = max right hard stop) | Head tilts LEFT (100 = max left hard stop) | Both extremes confirmed 2026-05-29, approved by operator |

**Eyelid hold-test result (2026-05-29):** 4s holds at logical 0, 25, 50, 80, 100.
0 visibly most open; eyelids progressively close as the value increases; 100
fully closed. The max-open position at 0 looks slightly less wide than a human's
fully-open eye; this is the mechanical hard stop, not a software limit.

**EUD is inverted on this unit.** Lower logical value = eyes look upward.
All other units in community docs may differ; always test per unit.

---

## 7. TCP Motor Bridge *(DEPRECATED: No Longer Needed)*

> **As of 2026-06-02, `facetrackadb` opens `/dev/ttyS1` directly via JNI (see Section 9).**
> The bridge and everything in this section is kept for reference and for diagnosing
> hardware issues outside the app context. Do not use the bridge for normal operation.

~~The app cannot open `/dev/ttyS1` directly (SELinux blocks `untrusted_app → serial_device`).~~
The native JNI path bypasses this; see Section 9 for the full explanation.
The bridge runs as shell context and is still useful for one-off hardware testing from
ADB shell without the app running.

**Bridge file:** `/data/local/tmp/motor-bridge.sh`
**Bridge port:** TCP 7777 on `0.0.0.0` (LAN-visible; no firewall currently)

### Starting the Bridge (Once per Reboot)
```bash
adb shell "nohup sh /data/local/tmp/motor-bridge.sh > /data/local/tmp/motor-bridge.log 2>&1 &"
# Wait 2–3 s, then verify:
adb shell "busybox netstat -tlnp | grep 7777"
```

### Stop the App before Manual Testing

**CRITICAL:** The app sends motor commands continuously while tracking. Neutralize it before any
manual test or it will contend for the bridge slot and cause short-write storms.

**Preferred method: PAUSE tracking (app stays alive but silent):**
```bash
adb shell "am broadcast -a com.mabu.facetrackadb.PAUSE_TRACKING --ez paused true -p com.mabu.facetrackadb"
```

**If a full restart is needed:** force-stop kills the bridge too; always restart the bridge AFTER
the app, never before. See "Clean motor-control establishment / re-establishment" below.

### Clean Motor-Control Establishment / Re-Establishment (Verified 2026-05-31)

The proven, repeatable sequence for taking reliable manual control. Verified twice back-to-back
(head full-left, then full-right) with 0 short writes each time.

**Key facts that drive the ordering:**
- Force-stopping the app **also takes the bridge down**, so always (re)start the bridge AFTER you
  have dealt with the app, never before.
- The app is the HOME launcher: force-stop relaunches it with tracking ACTIVE, and on startup its
  `MabuMotors.open()` connects to the bridge once (you'll see a brief `127.0.0.1:7777` connection,
  then `FIN_WAIT2`). Pause its tracking so it stops sending and can't contend for the slot.
- One sender at a time. Single-frame commands relay cleanly. The old `nc: short write` storms were
  a symptom of a hung motor board (clears on power-cycle) plus app contention - not a relay bug.

**Procedure (after an app restart, or any time you need to (re)establish control):**
```bash
A="/path/to/adb"   # e.g. "X:/Claude/android platform-tools/adb.exe"

# 1. (Optional) completely restart the app. This ALSO kills the bridge.
$A shell "am force-stop com.mabu.facetrackadb"; sleep 2
$A shell "am start -n com.mabu.facetrackadb/.MainActivity"

# 2. Pause the app so it can't contend for the bridge slot.
$A shell "am broadcast -a com.mabu.facetrackadb.PAUSE_TRACKING --ez paused true -p com.mabu.facetrackadb"

# 3. Kill any stray bridge/nc, then start exactly ONE bridge.
$A shell 'for p in /proc/[0-9]*; do c=$(cat $p/cmdline 2>/dev/null | tr "\0" " ");
  case "$c" in *cmdline*) continue;; esac;
  case "$c" in *motor-bridge.sh*|*"nc -l -p 7777"*) kill ${p#/proc/} 2>/dev/null;; esac; done'
$A shell "nohup sh /data/local/tmp/motor-bridge.sh >/dev/null 2>&1 &"
sleep 3

# 4. Verify the slot is clean BEFORE sending.
$A shell "busybox netstat -tlnp | busybox grep 7777"                          # must show LISTEN
$A shell "busybox netstat -tn | busybox grep 7777 | busybox grep ESTABLISHED" # must show nothing

# 5. Send your command as a SINGLE frame over one connection (reliable loopback form):
$A shell "busybox printf '<frame-hex>' | busybox timeout -t 3 busybox nc 127.0.0.1 7777"
```

**Confirm the move WITHOUT a camera (telemetry):** capture the board's position reports around the
send and read the target motor's byte.
```bash
# start capture, send at ~1s, wait for capture to finish
$A shell 'busybox timeout -t 6 cat /dev/ttyS1 > /data/local/tmp/mv.bin 2>/dev/null &
  sleep 1; busybox printf "<frame-hex>" | busybox timeout -t 3 busybox nc 127.0.0.1 7777; wait'
$A shell "busybox hexdump -C /data/local/tmp/mv.bin | busybox head -4; busybox hexdump -C /data/local/tmp/mv.bin | busybox tail -4"
```
In each `FA 00 09 01 00 ..` position frame the 7 motor bytes are `LDL LDR ELR EUD NE NR NT` at
frame offsets 5..11. A clean move shows the target byte ramp to the commanded wire value, and the
bridge log gains 0 new `short write` lines. (To pull the capture to the PC, prefix the adb command
with `MSYS_NO_PATHCONV=1`.)

**Single-motor frame cheat sheet:** `FA 00 04 01 <mask> 01 <wire> <s2> <s1>`. Examples verified on
hardware 2026-05-31:
| Command | Effect | Frame |
|---|---|---|
| NR=100 | head full LEFT  | `FA 00 04 01 02 01 FF FC 03` |
| NR=0   | head full RIGHT | `FA 00 04 01 02 01 00 FC 03` |
| ELR=80 | eyes right      | `FA 00 04 01 10 01 CC F3 DD` |

### Critical Bridge Rules
- **NEVER start the bridge twice.** A second instance opens `/dev/ttyS1` again, resetting
  termios and DTR, killing motor response until the bridge is killed and restarted.
- **Persistent fd required.** The bridge opens fd3 once and never closes it. Opening/closing
  the serial port per-connection resets termios. This is why tcpsvd and per-child approaches fail.
- **`-hupcl` is mandatory.** Without it, closing the last fd drops DTR, resetting the motor board.
  All subsequent commands are silently ignored.

### Sending Commands from PowerShell (via TCP)
Build the frame as a single `byte[]`: **do not use `+` to concatenate byte arrays in PowerShell 5.1**,
it returns `Object[]` which breaks `Stream.Write(byte[], int, int)`.

```powershell
function Send-MotorFrame([byte[]]$frame) {
    $tcp = New-Object System.Net.Sockets.TcpClient("192.168.0.180", 7777)
    $stream = $tcp.GetStream()
    $stream.Write($frame, 0, $frame.Length)
    $stream.Flush()
    Start-Sleep -Milliseconds 300
    $stream.Close(); $tcp.Close()
}
```

Send **power-on and movement commands in the same TCP connection** (or with power-on first,
close, then reconnect with movement). A gap between separate connections may cause the motor
board to lose state and ignore commands.

### Sending Commands from ADB Shell (Reliable Alternative)
```bash
adb shell "busybox printf '\xFA\x00\x0A...' | nc 127.0.0.1 7777"
```
`busybox printf` supports `\xNN` hex escapes. `nc` closes when stdin (printf) exits.
Use `127.0.0.1` (loopback) not `192.168.0.180` to avoid external routing.

### Connection Failures and the `nc: short write` Storm (Investigated 2026-05-31)

**Symptom:** a PC TCP client to port 7777 fails mid-burst with "An established connection
was aborted by the software in your host machine." The bridge log shows repeated
`nc: short write` immediately followed by `Client disconnected, listening again`.

**Mechanism:** busybox nc (v1.22.1 on this unit) relays socket bytes to `/dev/ttyS1` (fd3).
When that serial `write()` returns fewer bytes than asked (a short write), this build treats it
as FATAL and EXITS, tearing down the TCP connection. The PC side then sees the abort. The app
makes it worse: on any write failure it immediately reconnects (MabuMotors.kt re-`tryConnect`s in
its `writeFrame` catch), so the cycle becomes a self-reinforcing storm.

**Confirmed NOT the cause (ruled out 2026-05-31, tested one variable at a time):**
- *Bridge stdout polluting the motor wire (refuted).* `/proc/<bridge-pid>/fd/1` shows
  `-> /dev/ttyS1`, which looks alarming, but it is a TRANSIENT mksh artifact: the loop's
  `nc -l -p 7777 >&3` borrows the parent shell's fd1 onto fd3 for the duration of the (blocking)
  nc, then restores it. Proof: every `log()` line ("Bridge starting", "Client disconnected")
  lands in the LOGFILE, not on the wire. The bridge never sprays ASCII onto `/dev/ttyS1`.
  Hardening the script with `exec 1>>"$LOG" 2>&1` did not change this (fd1 still reads as ttyS1
  in a /proc snapshot because of the transient borrow).
- *busybox nc being inherently unfit for a single relay (refuted).* A clean single relayed write
  - one client, one 7-byte power-on via loopback, no app connected, no concurrent reader -
  produced ZERO short writes. The relay works fine in isolation.

**Actual trigger: contention on the single-client bridge slot.** The bridge serves ONE client at
a time. The app is the HOME launcher (auto-restarts on force-stop) and reconnects on every write
failure, so when it is tracking-active it hammers port 7777; combined with a PC client or any
churn, nc short-writes and the storm sustains.

**Rule:** before ANY manual testing, neutralize the app so it cannot contend for the slot - pause
tracking via the `PAUSE_TRACKING` broadcast (or force-stop, though it relaunches as launcher).
Verify `busybox netstat -tn | grep 7777` shows NO established client before sending. One sender
at a time.

### Hardened Bridge (Deployed 2026-05-31)
The on-device `/data/local/tmp/motor-bridge.sh` now adds, vs the original: `exec 1>>"$LOG" 2>&1`
at the top (force log output to the file) and `clocal` in the stty (so a fresh fd3 open does not
block on carrier). These are hygiene improvements; they do NOT fix the short-write storm - the fix
for that is removing app/sender contention (above). Local copy: `X:\Claude\Mabu\motor-bridge-hardened.sh`.

### Environment Gotchas Found This Session
- **`adb push` path mangling.** `adb push <local> /data/local/tmp/...` from the Bash tool (Git
  Bash / MSYS) rewrites the device path into `C:/Program Files/Git/data/local/tmp/...` and fails
  with `remote secure_mkdirs failed: No such file or directory`. Prefix the command with
  `MSYS_NO_PATHCONV=1` to disable the conversion. (PowerShell does not have this problem.)
- **WiFi ADB drops mid-command** ("error: closed" or "device offline"). Recover with
  `adb disconnect 192.168.0.180:5555 && adb connect 192.168.0.180:5555`; may take 2-3 tries.

---

## 8. CSV Animation Format

7 CSV files on device at `/sdcard/*.csv`.
Columns: `Time(ms), MCB1, MCB2, DATA1, DATA2`

Wire value from CSV: `wire = clamp(int(round(csv_value + 128)), 0, 255)`

---

## 9. SELinux Notes: Corrected 2026-06-02

- `/dev/ttyS1` Unix permissions: `crwxrwxrwx` (wide open)
- SELinux label: `u:object_r:serial_device:s0`
- App context: `u:r:untrusted_app:s0`
- Shell context: `u:r:shell:s0`; allowed for all operations

### What Is Actually Blocked vs Allowed for untrusted_app

The SELinux policy on this device (Rockchip Android 8.1) allows `untrusted_app` to
`open`, `read`, `write`, and `ioctl` on `serial_device`, but denies `getattr`.

**Implication:**
- **Java `FileOutputStream("/dev/ttyS1")`** → **FAILS.** Java calls `stat()` first
  (to check if the file exists / get metadata), which requires `getattr`. SELinux
  denies `getattr`, so an `IOException` is thrown before `open()` is ever called.
  This is the AVC denial we recorded: `avc: denied { getattr } ... permissive=0`.
- **Native C `open("/dev/ttyS1", O_RDWR | O_NOCTTY)`** → **SUCCEEDS.** The C call
  goes directly to the `open(2)` syscall without a prior `stat()`. SELinux allows
  `open` for `untrusted_app`, so it returns a valid fd. Confirmed 2026-06-02:
  `MabuSerial: opened 57600 baud, fd=42` with zero new AVC denials in dmesg.

### Practical Rule
Use JNI (`serial.c`) to access `/dev/ttyS1` from the app. Never use Java I/O.
The TCP motor bridge is no longer needed.

- `getenforce` reports "Enforcing" because it IS enforcing. `ro.boot.selinux=permissive`
  is ignored by Android `init` on user builds. The `getattr` denial was real; the `open`
  permission is also real (just never blocked).

---

## 10. Known Issues / Gotchas Checklist

- [ ] **ASCII only in PowerShell scripts (.ps1).** NEVER use em-dashes (or any non-ASCII char) in a `.ps1` file. PowerShell 5.1 reads a UTF-8-without-BOM file as Windows-1252, so an em-dash's third byte `0x94` becomes a curly double-quote that silently terminates/reopens strings and desyncs the whole parse (cascading "Unexpected token" errors far from the real line). Use `-` or `--` instead. If a script must contain non-ASCII, save it with a UTF-8 BOM. This has bitten us multiple times.

- [ ] **Use native JNI to open `/dev/ttyS1` from the app; never Java I/O.** Java calls `stat()` first, which requires `getattr`; SELinux denies `getattr` for `untrusted_app`. Native `open()` bypasses `stat()` and succeeds. See Section 9.
- [ ] **Command-latch: distinguish two states (Section 11).** STIFF + MUTE (zero telemetry) = hung MCU → power-cycle likely helps. STIFF + heartbeat-only + commands ignored = State B → **use direct exec+stty recovery (Section 11)**. Power-cycle is not needed for State B. Read telemetry first.
- [ ] **Cold boot: send power-on 5x with 200ms gaps + 1s wait**: single power-on does not wake the board (see Section 3 cold-boot wake-up)
- [ ] All wake-up frames must be in one open of `/dev/ttyS1` (keep the fd open); splitting across connections has failed
- [ ] NE range is [0, 100]: do NOT limit to 50 (community docs wrong) or 18 (also wrong). Confirmed 2026-05-29.
- [ ] EUD is inverted: lower value = eyes look UP
- [ ] EUD soft min = 5 may cause slight grinding; raise to 8 if needed
- [ ] PowerShell `[math]::Round(50 * 2.55)` = 127 not 128; use floor+0.5 formula
- [ ] PowerShell byte[] + byte[] = Object[]; build frames with indexed assignment only

---

## 11. "Motors not responding": Diagnostic Order

### ⚠️ FIRST: Read Telemetry to Classify the Stuck State.

There are **two distinct stuck states** with different recovery paths. Read `/dev/ttyS1` before doing anything else:

```bash
adb shell "busybox timeout -t 5 cat /dev/ttyS1 | busybox hexdump -C"
```

**State A: STIFF + MUTE (zero telemetry, not even a heartbeat):** the MCU is hung.
A physical power-cycle recovered this state in session 8 (2026-05-31). After cycling: reconnect ADB, run the clean-control procedure (Section 7), do the 5× cold-boot wake, then a validation move with the operator watching.

**State B: STIFF + heartbeat-only (`FA 00 01 00 ED FB`) + commands ignored:** recovery confirmed 2026-05-31.

**Recovery: direct exec+stty (NOT the bridge):**
```bash
adb shell "exec 3<>/dev/ttyS1; busybox stty -F /dev/ttyS1 57600 raw -hupcl; \
  busybox printf '\xFA\x00\x02\x4F\x7F\x0B\xCB' >&3; sleep 1; \
  busybox printf '<motor-frame>' >&3; sleep 0.5"
```
Replace `<motor-frame>` with the target move frame (e.g. `\xFA\x00\x04\x01\x02\x01\xFF\xFC\x03` for NR=100). Confirmed: board produced `FA 00 09` position frames and head moved after this, with the bridge approach having just failed in the same session.

**What does NOT clear State B:** bridge/nc relay path (any form), 5× wake via bridge, single `> /dev/ttyS1` redirect, force-stopping app, device-loopback via bridge.

**Mechanism hypothesis (unconfirmed):** opening a second fd to `/dev/ttyS1` via `exec 3<>` while the bridge already holds fd3 may assert a UART signal (DTR or break) that resets the board's command-accept state. The persistent-fd form is required; the simple `>` redirect (which opens and immediately closes) does not work.

**Boot-time contention (investigation incomplete):** `com.catalia.factorymode` (installed, has `RECEIVE_BOOT_COMPLETED` permission and references `/dev/ttyS1` in its DEX) is a candidate cause of State B on boot. If this or any process writes to the serial port during the board's post-boot init window, it may trigger State B.

#### Post-Power-Cycle Recovery (State A)
1. `adb disconnect 192.168.0.180:5555 && adb connect 192.168.0.180:5555` (may take a couple of tries).
2. Follow the clean-control procedure in Section 7.
3. Run the 5× cold-boot wake (Section 3), then a validation move **with the operator watching**.
4. Confirm engagement via telemetry: a successful move streams `FA 00 09 …` position frames (Section 13).

### Full Diagnostic Order

When motors don't move, work through these in order:

1. **Limp vs stiff test.** Gently push the head with a finger.
   - **Limp** → motor board is unpowered. Wiring/power issue, NOT a software problem.
   - **Stiff** → board is powered and holding position. Continue below.
2. **Read telemetry** (see above): classify State A (mute) vs State B (heartbeat-only) vs working (see `FA 00 09` on commands).
3. **Is this a cold boot?** If yes → run the 5× power-on wake-up sequence (Section 3).
4. **App contention?** Verify no established client on 7777 before sending. Pause tracking if needed.
5. **Bridge or board?** Try writing directly to `/dev/ttyS1` using the exec+stty form (NOT a simple redirect):
   ```bash
   adb shell "exec 3<>/dev/ttyS1; busybox stty -F /dev/ttyS1 57600 raw -hupcl; busybox printf '<frame>' >&3; sleep 0.5"
   ```
   - Direct exec+stty works but bridge doesn't → bridge relay issue.
   - **State B:** direct exec+stty IS the recovery, not just a diagnostic. Try it before declaring the board stuck.
   - Neither works → board is in State A (hung MCU) → power-cycle.

### NEVER Reboot Mabu via ADB
`adb reboot` has caused WiFi to not reconnect after boot, leaving the device unreachable with no recovery path (no USB, no physical buttons). **Do not run `adb reboot` under any circumstances.** If a reboot is truly needed, power-cycle the physical hardware instead.

### Rabbit Holes to Avoid (Already Investigated, Don't Re-Chase)

- **`/sys/class/gpio_control` / `inhuasoft_gpio_control` driver.** This is a Catalia-custom
  GPIO control interface exposing 3 GPIO pins (controllers 0xA8/0xA9, pins 16/19/9).
  The control file is `/sys/devices/virtual/gpio_control/gpio/gpio_control`, mode
  `-rw-rw-r-- root:root`. Shell user **cannot write to it without root**, and we have
  no root path on this unit. Even if it does enable motor power, it's not reachable
  from our environment. Don't go down this rabbit hole; the motor board has its own
  power that survives reboots, the issue is always wake-up/state, not power-enable.

---

## 12. Known Bugs

### EUD Oscillation during Face Tracking: ROOT CAUSE FOUND AND FIXED (2026-06-02, Session 13)

**Status: FIXED in `facetrackadb` via `EUD_MAX_RATE = 1.0`.** Residual micro-oscillation
(ptp ≈ 10–25 wire units, < 0.2s duration) remains; visually acceptable. Further tuning deferred.

---

#### Root Cause (Confirmed 2026-06-02)

The oscillation is **not** caused by hitting the mechanical hard stop at EUD=0. It is caused
by the motor board's PID controller overshooting when EUD changes direction (e.g., eye was
tracking upward at EUD≈25–40, face returns to center, eye starts returning to EUD=50).

**What actually happens:**
1. Face moves upward → EUD tracks down toward EYE_UD_MIN (logical ~20–35 in practice).
2. Face returns to center → app commands EUD back toward 50 via `SMOOTH=0.12` ramp.
3. The ramp rate (~5 wire units per 70ms tick) is fast enough to excite the motor board's
   under-damped PID. The board overshoots the target, reversal happens, oscillation rings.
4. Result: eyes bounce through a ±30–50 wire unit range for 0.5–2s.

**What the oscillation is NOT:**
- Not caused by hitting the hard stop at wire=0 (EUD=0). Live telemetry confirmed EUD never
  went below wire≈44 during normal face tracking; well above the physical stop.
- Not caused by neck elevation (NE). NE was flat (ptp=0–2 wire) at every burst.
- Not a transport or frame-format bug.

**Key diagnostic data (session 13, before fix):**
- 9 EUD oscillation bursts in 45s, ptp 80–100 wire units (31–39 logical), lasting up to 2s each.
- 5 ELR bursts (cross-contamination from large EUD bounces).
- Bursts always preceded by EUD returning from ~wire 83–116 (EUD≈33–45) toward center.
- NE completely flat at all burst times: neck not the cause.

**Early (wrong) hypotheses that were eliminated:**
- `EYE_UD_MIN = 5` causing hard-stop contact → raised to 20. Did not fix the oscillation
  because the actual tracking range never reached wire=51 (EUD=20) in practice.
- Ramping the return (5u/70ms or 3u/150ms): tested in isolation with single-motor frames,
  appeared clean. But live app uses all-7-motor frames at 70ms, which behave differently.

---

#### Fix Applied

**`EUD_MAX_RATE = 1.0` logical unit per callback, asymmetric** in `facetrackadb/MainActivity.kt`:

```kotlin
private val EUD_MAX_RATE = 1.0  // max EUD change per tick on RETURN to center only (prevents PID overshoot)
// ...
val deltaEUD = deadbandSmooth(posEUD, targetEUD)
posEUD += if (deltaEUD > 0) deltaEUD.coerceAtMost(EUD_MAX_RATE) else deltaEUD
```

`deltaEUD > 0` means EUD is rising (returning toward center from a low position); the direction
that excites the PID overshoot. Only that direction is capped. Downward tracking (EUD falling,
face moving upward) runs free so the eyes follow without sluggishness.

The original symmetric `coerceIn(-EUD_MAX_RATE, EUD_MAX_RATE)` was deployed in session 13 and
later made asymmetric in session 15 (2026-06-03). At this rate the motor board's PID does not
overshoot significantly in either direction.

**Result after fix (live telemetry, 45s session):**
- EUD bursts: 2 (down from 9), ptp 11–25 wire (down from 80–100). Peak reversals = 3.
- ELR bursts: 0 (down from 5); cross-contamination eliminated.
- Residual bursts are brief (<0.2s) and small; likely at or below visual perception threshold.

**0.75 was tested and performed worse** (ELR bursts returned: 3 bursts including one ptp=66
wire). Slower EUD return appears to cause cross-axis interference on the board. 1.0 is the
current deployed value.

---

#### Follow-Up Tuning (2026-06-02, Session 14): RESOLVED

**Visual confirmation:** residual micro-oscillations (ptp≈10–25 wire) are visually acceptable.

**EYE_UD_MIN floor tuning:**
- Lowering to 5.0 still produced occasional oscillation; the physical stop at wire≈0 is close
  enough that the rate cap alone doesn't fully prevent PID bounce at that floor.
- **Settled on `EYE_UD_MIN = 10.0`** as the practical minimum. Gives meaningful additional upward
  eye range compared to the old 20.0 floor while keeping enough buffer from the stop.

**Y_OFFSET asymmetry, UD neck trigger fix:**
The camera is in the chest tablet, static, at a steep upward angle. It does **not** move with
the head. (Corrected 2026-08-13: this section previously said the camera was head-mounted,
which is wrong and matters for any vision technique that assumes a fixed or a moving camera.
The `Y_OFFSET = -0.70` below is itself the evidence: it exists to shift the tracking centre up
for a camera mounted *below* the eye axis.) The upward angle requires `Y_OFFSET = -0.70` to
correct the tracking center. This creates a permanent asymmetry in the UD axis:
- **Upward** (face high in frame): effective effort `ay = yNorm - 0.70` can reach −1.0+, giving
  full effort and cleanly triggering the neck at the shared `EYE_NECK_TRIGGER = 0.60`.
- **Downward** (face low in frame): maximum `yNorm ≈ 1.0`, so `ay ≤ 1.0 − 0.70 = 0.30`. The
  shared 0.60 trigger is **unreachable** when looking down; neck can never engage.

Fix: separate neck trigger for the UD axis, `UD_NECK_TRIGGER = 0.20`, passed to
`computeEyeNeckAxis` as a parameter. LR axis keeps `EYE_NECK_TRIGGER = 0.60`.
Result: neck now engages when looking down; no change to horizontal tracking behavior.

**Floor setting is irrelevant to oscillation (confirmed 2026-06-02, session 14):**
Extensive floor testing (5.0, 7.5, 10.0) found oscillation at all values. Logcat analysis showed
`posEUD` reaches ~11 naturally from face tracking; neither the 5.0 nor 10.0 floor was ever hit.
The PID overshoot fires on any return from a low EUD position (~11–15) toward center, regardless
of the floor clamp. **`EYE_UD_MIN = 5.0` is the deployed value** (5 vs 10 makes no difference to
oscillation; 5 gives more upward range).

**UD_NECK_TRIGGER settled at 0.05** (down from 0.20). At 0.20 the neck was barely responsive
looking down (max neckFrac ≈ 12.5%); at 0.05 the neck reaches ~26% of range at maximum downward
effort, which is visibly effective.

**Remaining open items:**
1. ~~Asymmetric EUD rate cap~~: **RESOLVED 2026-06-03 (session 15).** Deployed. See updated fix block above.
2. ~~Tracking smoothness~~: **RESOLVED 2026-06-03 (session 15).** `SMOOTH` raised from 0.12 → 0.30; `SEND_INTERVAL_MS` lowered from 70 → 50ms. See Section 14.
3. ELR, NR, NE oscillation testing under rapid reversal: not yet done.

---

#### Historical Notes (Sessions 6–7, Now Superseded)

Original hypothesis was mechanical rebound at EUD=0 hard stop. Session 7 observed:
- Abrupt EUD=0→50 oscillates 100% of trials.
- Ramping the return unreliable (2/5 oscillated).
- Specific to upper stop; EUD=100 lower stop did not oscillate.

These observations were real but the **cause was misidentified**. The physical hard stop at
wire=0 does amplify oscillation (confirmed: EUD=0 caused 166 reversals vs EUD=20 causing ~1 with
rate cap), but the primary issue is the PID overshoot on ANY return from a low EUD position:
even EUD=33 (wire=84, far from the stop) caused 9 bursts without the fix.

---

## 13. Serial Telemetry / Readback (Board → Host)

The motor board is **NOT silent**: it continuously transmits status frames on `/dev/ttyS1`.
This is a useful, camera-free signal for detecting movement, oscillation, and the latch state.

### How to Read It

> ⚠️ **CRITICAL: Do NOT open `/dev/ttyS1` from `adb shell` while `facetrackadb` is running.**
> `termios` settings are shared across all file descriptions on a character device. Opening a
> second fd from ADB shell and running `busybox stty` on it overwrites the baud rate / mode
> settings that the app set on its fd. Result: app sends frames but the motor board can no longer
> parse them; motors go silent. **Recovery: `am force-stop` + restart the app.**
> Safe diagnostic path while the app is running: **logcat only** (see Section 14).

To read telemetry when the app is **not** running (e.g. for standalone hardware testing):
```bash
adb shell "exec 3<>/dev/ttyS1; busybox stty -F /dev/ttyS1 57600 raw -hupcl; busybox timeout -t 5 cat <&3 | busybox hexdump -C"
```

`busybox timeout` on this unit uses `-t SECONDS` (e.g. `-t 5`), NOT `timeout 5 …`.

### Frame Types
| Frame | Meaning |
|-------|---------|
| `FA 00 01 00 ED FB` | **Idle heartbeat** (payload `00`). Streamed continuously when the board is not moving any motor. |
| `FA 00 09 01 00 [LDL LDR ELR EUD NE NR NT] [s2 s1]` | **Position report.** Streamed while the board is engaged/moving. The 7 payload bytes are the live wire positions of all motors. |
| `FA 00 02 4F 7F 0B CB` | Power-on frame **echoed back** (appears right after you send a power-on). |

### Using Telemetry as a Marker
- **Engagement check:** a successful move streams `FA 00 09 …` frames. If you send commands and
  see **only** heartbeat (`FA 00 01 00`), the board did not engage → cold boot needs the 5× wake,
  or it is in the command-latch state; see Section 11 to classify and choose recovery path.
- **Oscillation detector (closed-loop):** during an oscillation, the EUD byte (4th payload byte)
  in successive `FA 00 09` frames rings up and down before settling. Polling that byte gives a
  programmatic oscillation signal with no camera needed; captured live during the EUD=0 bug
  (the EUD byte cycled ~`7c 78 7b 7a …` around center). This is the basis for future
  closed-loop tuning.

---

## 14. Face Tracking Parameters (facetrackadb)

Reference for all tunable constants in `facetrackadb/MainActivity.kt` and
`facetrackadb/MabuMotors.kt`. These are the deployed values as of 2026-06-04,
confirmed working on this unit.

### Architecture: Decoupled Tween (Kendrick-Pattern, 2026-06-04)

The face detector and the motor I/O run on **separate threads at different
rates**. Detection on `motorExecutor` (~10 Hz, camera-bound); motor frames on a
dedicated `mabu-tween` HandlerThread at 25 Hz. The detector NEVER touches the
serial port; it only writes `targetELR/EUD/NR/NE` (volatile fields). The tween
LP-filters `posELR/EUD/NR/NE` toward those targets at every tick and calls
`motors.moveAll`, which has its own send-side deadband so a steady-on-target
motor produces zero serial traffic.

This is the architectural pattern from Kendrick's `mabu-android` app
(`gazeTickRunnable`); we adopted it after diagnosing the 2026-06-04 servo rattle.
Before the refactor, the detection callback drove motor I/O directly, sending a
fresh 7-motor frame every ~10 Hz with small wire-byte jitter; the servos
audibly tracked each micro-update. After the refactor, motor frames go on the
wire only when the LP-filtered position actually crosses a wire-step threshold.

The advantage isn't smoothness alone: it's that the **motor I/O cadence is
decoupled from the noisy detection cadence**. ML Kit's bbox can wobble
frame-to-frame without producing matching wobble on the wire.

### Motion Smoothing (Current Values)

| Constant | Value | Effect |
|----------|-------|--------|
| `TICK_INTERVAL_MS` | `40L` | Tween period (25 Hz). |
| `EYES_ALPHA` | `0.30` | Per-tick LP coefficient for eye motors. `posELR += (targetELR − posELR) * α`. At 25 Hz this gives a ~80 ms time constant to reach 63% of any new target. |
| `NECK_ALPHA` | `0.12` | Per-tick LP coefficient for neck motors. Slower than eyes so neck visibly follows eye movement rather than racing it. |
| `RETURN_ALPHA` | `0.05` | When face lost > `FACE_LOSS_GRACE_MS`, the tween pulls targets toward neutrals at this rate per tick (~125 ms time constant). Gentle drift back to center, never snapping. |
| `TARGET_SMOOTH` | `0.4` | Input EMA on `xNorm`/`yNorm` from the face bbox center, applied in the detection callback before computing targets. Damps ML Kit's frame-to-frame bbox jitter. A single-frame outlier contributes only 40 %. Persistent across face drops (deliberately NOT re-seeded on grace expiry or new-face confirm; re-seeding caused the eye to snap to whatever ML Kit hallucinated on the first re-acquire frame). |
| `TARGET_DEADZONE` | `0.5` | Fixation deadzone for **ELR / NR** in motor units. `updateTargets` only commits a new target if it differs from the current target by more than this (~1.3 wire steps). Eye locks when face wobbles within the band. |
| `TARGET_DEADZONE_UD` | `2.5` | Fixation deadzone for **EUD / NE** (vertical axis) in motor units. Wider than the horizontal band because the bottom edge of the frame produces ~2 unit `tEUD` swings per detection as `yNorm` flickers across ±1.0; the smaller LR band can't absorb that. ~6.4 wire steps; only real downward gaze shifts cross it. |
| `SEND_DEADBAND` (MabuMotors) | `1.0` | Output-side deadband in motor units. `motors.moveAll` skips the wire frame if EVERY motor is within `SEND_DEADBAND` of what was last sent. ~2.5 wire steps. Critical for servo rattle: the LP tween emits a series of small-but-deadband-crossing updates during each convergence, and a larger send-deadband collapses those into one or two frames per target update. Started at 0.5, raised to 1.0 on 2026-06-04 to silence persistent edge-condition EUD chatter. |
| `FACE_LOSS_GRACE_MS` | `1000L` | After this much time with no face, the tween starts pulling targets toward neutrals via `RETURN_ALPHA`. Within grace, targets just hold. Also clears the IoU tracker reference. |
| `TRACKING_CONFIRM_FRAMES` | `4` | Hysteresis: a new face ID must persist 4 consecutive frames before being accepted as the tracked face. Only used when there's NO tracker reference (post-grace) AND IoU < threshold. |
| `OVERLAY_INTERVAL_MS` | `250L` | Debug overlay rate-limit (4 Hz). Per-frame TextView updates preempted the camera thread; rate-limiting eliminated the ≥120 ms inference outliers entirely. **Always keep this.** |
| `TRACKER_IOU_THRESHOLD` | `0.30f` | IoU cross-frame tracker match threshold. Detections with IoU ≥ 0.30 against the velocity-predicted bbox are treated as the same physical face regardless of ML Kit's tracking ID. |
| `TRACKER_VEL_SMOOTH` | `0.3f` | EMA weight for the per-frame velocity estimate used in the IoU prediction. |
| `EDGE_FREEZE_FRAMES` | `1` | When the face center has been clipped past the frame edge for this many consecutive frames, the corresponding eye target stops being pushed further toward the end-stop. Lowered from 3 to 1 on 2026-06-04: at 3 the freeze never engaged when `yNorm` was flickering above/below 1.0 because `yClipFrames` kept resetting on the in-frame frames. |
| `UD_NECK_TRIGGER` | `0.15` | Neck-engagement threshold for the UD axis. Below this `|ay|`, neck stays at neutral while eyes do the work. Raised from 0.05 on 2026-06-04 to keep the NE motor silent for shallow downward gaze (was being driven on every frame because `Y_OFFSET=-0.70` made `ay > 0.05` almost always true when the user was below frame-center). |

**Removed in 2026-06-04 refactor** (do not re-introduce without rationale): `SMOOTH`,
`DEADBAND`, `SEND_INTERVAL_MS`, `EUD_MAX_RATE`, `NE_MAX_RATE`,
`ID_TRANSITION_FRAMES`/`ID_TRANSITION_MAX_RATE`, the inline motor send in the
empty-faces grace path, and the `deadbandSmooth()` function. The LP tween +
SEND_DEADBAND replace all of these cleanly.

### IoU Cross-Frame Tracker

ML Kit's `enableTracking()` reassigns face IDs every few seconds due to
detection gaps, blinks, partial occlusion, or multi-face frames. The IoU
tracker maintains its own `trackerBbox` (normalized [0,1]) plus a velocity EMA
so we recognize the same physical face across ID changes without restarting
hysteresis / smoothing each time. On each detection:

1. Predict bbox: shift `trackerBbox` by `(trackerVelX, trackerVelY)`.
2. Compute IoU between predicted bbox and new detection.
3. If IoU ≥ `TRACKER_IOU_THRESHOLD` (0.30) → same physical face, accept the new
   ID as a continuation.
4. If IoU > 0 but < 0.30 → ambiguous; accept as continuation, but wipe velocity
   so the next prediction starts fresh.
5. **If IoU == 0 AND tracker is alive → reject the detection entirely.** No
   pixel overlap with the predicted bbox means it's a different physical face
   (or a phantom). Return without updating `confirmedTrackingId`, `trackerBbox`,
   `smoothedXNorm`, or any target. Eye holds its current position. If the user
   genuinely jumped to a far position, subsequent frames will keep reporting it
   and grace + hysteresis will pick it up as a fresh face.
6. If IoU < threshold AND tracker is null (post-grace, no reference) → genuine
   new face; run hysteresis.

### Face Selection Priority (When ML Kit Returns Multiple Faces)

ML Kit returns multiple faces on fresh boot while autoexposure settles, or when
a phantom detection appears at the frame edge. The old "biggest area" heuristic
locked onto phantoms whose bbox extended off-screen (raw area includes
off-image pixels). Current order:

1. The face whose `trackingId` equals `confirmedTrackingId`: fastest path.
2. If the tracker is alive, the face with the **highest IoU against the
   tracker's predicted bbox**, drawn from in-frame candidates if any.
3. The largest face **whose center is inside the image** (filters phantoms with
   off-screen centers).
4. Last-resort fallback to the largest face overall.

### Edge-Clip Handling

When the face center reports outside `[-1, 1]` (face partly off-frame), the
detector clamps `xNorm`/`yNorm` to ±1.0 instead of skipping. Skipping froze
motors AND let trackerBbox go stale, refiring the slew window on every reentry
(historical: slew window no longer exists, but the staleness problem would
have re-emerged).

Two edge-clip frame counters (`xClipFrames`, `yClipFrames`) increment on each
clipped frame. Once they cross `EDGE_FREEZE_FRAMES` (1), the eye target stops
being pushed further toward the mechanical end-stop in the clipped direction.

### Face-Loss Behavior

Within `FACE_LOSS_GRACE_MS` (1 s) of the last good detection, targets simply
hold. The tween still runs and continues LP-filtering `pos` toward `target`;
but with `target` unchanged, `pos` converges to it and `SEND_DEADBAND` stops
the wire frames. The motor goes silent.

Past grace, the tween pulls each target toward its neutral via `RETURN_ALPHA`
(0.05 / tick). At 25 Hz that's a ~500 ms time constant to drift halfway back;
gentle, never snapping.

When detection resumes after a long absence, `smoothedXNorm`/`smoothedYNorm`
are NOT reset. The first new sample EMA-blends 40 / 60 with the pre-drop
position, naturally resisting wild outliers from re-acquire frames. This was
the key fix for the "freaking out on re-acquire" pathology.

### Eye/Neck Soft Limits

| Constant | Value | Notes |
|----------|-------|-------|
| `EYE_LR_MIN` / `EYE_LR_MAX` | `15` / `85` | Horizontal eye range during tracking |
| `EYE_UD_MIN` / `EYE_UD_MAX` | `5` / `85` | Vertical eye range. 5 is near the physical stop (wire≈13); rate cap prevents overshoot. |
| `NECK_MIN` / `NECK_MAX` | `20` / `80` | NR tracking range |
| `NE_MIN` / `NE_MAX` | `18` / `100` | NE tracking range |

### Eye/Neck Coordination Thresholds

| Constant | Value | Axis | Notes |
|----------|-------|------|-------|
| `EYE_NECK_TRIGGER` | `0.60` | LR | Eye at 60% effort → neck ramps in |
| `UD_NECK_TRIGGER` | `0.15` | UD | Y_OFFSET=-0.70 caps downward `ay` at ≈0.30 so the LR trigger of 0.60 is unreachable looking down. 0.05 was too sensitive (NE motor was driven on every frame for any below-center face); 0.15 keeps neck silent for shallow downward gaze while still leaving usable range. |
| `NECK_FULL_UNLOCK` | `0.80` | both | Neck at 80% → eye uses full range |
| `EYE_FULL_UNLOCK` | `0.90` | both | Eye at 90% → both axes unlock |

### Camera / Input

| Constant | Value | Notes |
|----------|-------|-------|
| `Y_OFFSET` | `-0.70` | Shifts tracking center up. Compensates camera mounting angle + pixel center offset. |
| `X_OFFSET` | `0.0` | No horizontal compensation needed on this unit. |
| `ELR_GAIN` | `1.4` | Scales xNorm (max ≈ ±0.7 in practice) to fill ±1.0 effort range. |
| Camera resolution | `320×240` | Smallest available: keeps ML Kit latency low on Mabu's CPU. |
| ML Kit mode | `PERFORMANCE_MODE_FAST` | No landmarks, no classification. |
| `minFaceSize` | `0.10f` | Min face width as fraction of frame (32px at 320 wide). Was 0.15 (48px): too large, caused loss at distance or near frame edges. |
| `enableTracking()` | enabled | ML Kit maintains a face model across frames using temporal prediction. Dramatically reduces detection loss during fast motion or partial blur. Safe for single-person tracking; the doc note about "accuracy loss with overlapping faces" does not apply here. |

---

## 15. Face-Tracking Performance: Hardware Ceiling (Session 18, 2026-06-03)

Definitive measurements with three-tier instrumentation (HAL arrival, ML Kit inference, end-to-end pipeline). All numbers from a clean run with no audio/voice load.

### Numbers

| Stage | Avg | Max | Notes |
|---|---|---|---|
| **HAL arrival** (handleFrame cadence) | 100 ms (10.0 fps) | 117–121 ms | Camera HAL delivers frames at a tight, fixed ~10 fps cadence. Very stable (jitter ±15 ms). |
| **ML Kit inference** | 33–37 ms | 85–110 ms | ~70% of frames are ≤40 ms; long tail ~20% at 60–110 ms (GC / thermal / ML Kit internal variance). |
| **End-to-end pipeline interval** | 103–110 ms | 173–208 ms | 200 ms outliers correspond 1:1 with backpressure drops: when inference goes long, the next HAL frame arrives during `busy=true` and is dropped, doubling the next interval. |

### Findings

1. **The HAL is a hard ceiling at ~10 fps.** Camera advertises 24 fps in `supportedPreviewFpsRange` (`[24000-24000]` mHz) and accepts the request, but actually delivers 10 fps. No userland change can lift this.
2. **ML Kit inference on RK3288 averages ~35 ms** at 320×240 with `PERFORMANCE_MODE_FAST` and no landmarks/contours/classification. Kendrick's `mabu-anima` code comments cite ~109 ms, but that was under WebRTC audio load with detection deprioritized; uncontended, it's ~3× faster.
3. **`PERFORMANCE_MODE_ACCURATE` is not worth it** on this hardware. Inference would jump to 100+ ms, exceeding the 100 ms HAL slot every frame → constant drops → effective fps drops below 10. Stay on FAST.
4. **Buffer pool of 4** (was 2) reduces backpressure drops from ~6% to ~2%. Marginal but real. Going higher gives diminishing returns.
5. **Camera thread priority matters for audio coexistence.** ML Kit lazily spawns its inference worker pool on the FIRST `detector.process()` call, and the workers inherit the calling thread's nice value. Opening the camera on the `mabu-camera-vision` HandlerThread at nice +5 means future URGENT_AUDIO threads (nice -19) will preempt face detection. Required pattern when audio/voice work lands.

### Diagnostic Playbook (When "Tracking Feels Off")

Read the three Logcat lines emitted every ~5 s:

```
Camera1Source: hal n=50  arrival avg=99.9ms max=119ms (10.0 fps)  dropped=1/50
MabuFaceTrack: perf n=50  inference avg=33ms max=85ms | interval avg=103ms max=180ms | nativeHeap=14MB
MabuFaceTrack: infer-histogram <20:19 <30:8 <40:7 <50:2 <60:3 <80:9 <120:2 ≥120:0
```

Interpretation:
- **HAL arrival far from 100 ms or `dropped > 5/50`** → camera or buffer issue. Check `handleFrame` is being called from `mabu-camera-vision` thread.
- **Inference avg > 50 ms or ≥120 ms bucket > 0** → CPU contention. Check if anything else is running (TTS, LLM, app overlay updating per frame). The overlay rate-limit is the canonical fix; restore it if disabled.
- **Pipeline interval max ≫ 200 ms** → multiple consecutive drops. Investigate inference tail and GC; consider reducing per-frame allocations.
- **Native heap growing every window** → leak. Should stay ~13–15 MB indefinitely.

### Future Levers (NOT Pulled Yet, Out of Scope for Current Session)

- Pre-allocate the per-frame `InputImage` byte buffer to remove that allocation from the GC hot path.
- Replace ML Kit with a smaller tflite face detector (Mobile FaceNet variants run in ~10 ms on Cortex-A17). Would unlock 30+ fps if HAL cooperated, but HAL is the cap, so the practical gain is just CPU headroom for other work.
- Roll a custom across-frame tracker (bbox IoU + velocity prior) on top of ML Kit detections, treating ML Kit as a per-frame detector. Most likely real lever for ID-churn problem, since we can't get more frames.


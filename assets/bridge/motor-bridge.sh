#!/system/bin/sh
#
# motor-bridge.sh — runs on Mabu, gives apps a way to talk to the motors.
#
# Why this exists:
#   Apps installed normally on Mabu are blocked by SELinux from opening
#   /dev/ttyS1 (the motor cable) directly. This script runs as the shell
#   user — which IS allowed to open the motor cable — and exposes a
#   simple TCP port that any local process can write motor bytes to.
#
# How to start it (from a PC, one time per Mabu reboot):
#   adb push motor-bridge.sh /data/local/tmp/
#   adb shell chmod 755 /data/local/tmp/motor-bridge.sh
#   adb shell "busybox dos2unix /data/local/tmp/motor-bridge.sh"
#   adb shell "nohup sh /data/local/tmp/motor-bridge.sh > /data/local/tmp/motor-bridge.log 2>&1 &"
#
# Design — persistent fd + nc loop:
#   /dev/ttyS1 is opened ONCE via "exec 3<>" and held open for the entire
#   lifetime of this script. nc sessions write to fd 3 rather than opening
#   the device themselves.
#
#   Two critical settings:
#   - "exec 3<>" keeps the serial port open so termios settings persist
#     and the motor board sees a continuous connection.
#   - "-hupcl" prevents DTR/RTS drop if the script is killed — without it,
#     closing /dev/ttyS1 resets the motor board.
#
#   There is a brief gap (~10-50ms) between client disconnect and the next
#   nc listener. The app handles this with retry logic in MabuMotors.kt.
#
# Notes:
#   - Listens on 0.0.0.0:7777 (busybox nc doesn't support -s).
#   - One client at a time. Each connection streams bytes to the motors
#     until the client disconnects, then the script loops for the next one.

PORT=7777
TTY=/dev/ttyS1
BUSYBOX=/system/bin/busybox

log() { echo "[motor-bridge $(date +%H:%M:%S)] $*"; }

# Open ttyS1 once on fd 3 — stays open for the lifetime of this script.
exec 3<>"$TTY"

# Configure serial AFTER opening so settings apply to the active fd.
# -hupcl prevents DTR drop on close (critical — without it the motor board resets).
$BUSYBOX stty -F "$TTY" 57600 raw -hupcl
log "Bridge starting on 0.0.0.0:$PORT -> $TTY (fd3 persistent, -hupcl)"

while true; do
    $BUSYBOX nc -l -p "$PORT" >&3
    log "Client disconnected, listening again"
done

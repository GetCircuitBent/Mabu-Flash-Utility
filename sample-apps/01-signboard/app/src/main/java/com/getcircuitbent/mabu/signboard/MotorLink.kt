package com.getcircuitbent.mabu.signboard

import android.util.Log

/**
 * ============================================================================
 * INDEX ROWS 3 AND 5 - owning the serial port, waking the board, sending.
 * ============================================================================
 *
 * One instance of this owns the file descriptor for the whole app.
 *
 * ---------------------------------------------------------------------------
 * ONE OWNER, ALWAYS
 * ---------------------------------------------------------------------------
 * Exactly one process may usefully hold /dev/ttyS1 at a time. Two openers do
 * not get an error - they get to corrupt each other, because termios settings
 * are shared across every open file description on a character device. A
 * second opener running `stty` silently reconfigures the baud rate underneath
 * the first one, and the motors go quiet with nothing in any log to explain
 * it.
 *
 * Practical consequences:
 *  - If [open] fails with EACCES or EBUSY, another app has the port. On a
 *    freshly flashed unit that is usually com.catalia.factorymode.
 *  - Do NOT `cat /dev/ttyS1` from an adb shell while this app is running,
 *    however tempting it is. Read logcat instead.
 */
class MotorLink(
    private val devicePath: String = "/dev/ttyS1",
    private val baud: Int = 57600,
) {

    private var fd: Int = -1
    private val lock = Any()

    /** Human-readable state for the admin header. */
    @Volatile var status: String = "closed"
        private set

    @Volatile var awake: Boolean = false
        private set

    fun isOpen(): Boolean = fd >= 0

    // -----------------------------------------------------------------------
    // OPEN
    // -----------------------------------------------------------------------

    /**
     * Open the port and prove the protocol implementation before using it.
     *
     * @return true if the port is open. Check [status] for the reason if not.
     */
    fun open(): Boolean = synchronized(lock) {
        if (fd >= 0) return true

        // Cheap insurance: verify the encoder and checksum against known-good
        // frames before we send anything at all. If this fails, the problem is
        // in MabuProtocol, not in your wiring, and you have just saved
        // yourself an afternoon.
        MabuProtocol.selfTest()?.let { failure ->
            status = "protocol self-test FAILED: $failure"
            Log.e(TAG, status)
            return false
        }

        val r = SerialPort.openTty(devicePath, baud)
        if (r < 0) {
            val errno = -r
            status = when (errno) {
                13, 16 -> "busy (errno $errno) - another app owns $devicePath"
                2      -> "not found (errno 2) - is this a Mabu?"
                else   -> "open failed (errno $errno)"
            }
            Log.e(TAG, "openTty($devicePath) failed: $status")
            return false
        }

        fd = r
        status = "open (fd $fd)"
        Log.i(TAG, "serial $status")
        return true
    }

    fun close() = synchronized(lock) {
        if (fd >= 0) {
            SerialPort.closeTty(fd)
            Log.i(TAG, "serial closed (fd $fd)")
        }
        fd = -1
        awake = false
        status = "closed"
    }

    // -----------------------------------------------------------------------
    // ROW 3: THE COLD-BOOT WAKE SEQUENCE
    // -----------------------------------------------------------------------

    /**
     * Wake the motor board. Call once per power cycle, before the first move.
     *
     * *** THIS IS NOT OPTIONAL AND IT IS NOT SUPERSTITION. ***
     *
     * After the Mabu powers on, the motor board's microcontroller spends a
     * while in its own init before it starts paying attention to the UART.
     * Bytes sent during that window are dropped on the floor. A single
     * power-on frame usually lands inside it and is simply lost.
     *
     * The symptom is maximally confusing: the head is STIFF (so the board is
     * clearly powered and holding position), your writes all return success
     * (so the bytes really are reaching /dev/ttyS1), and nothing moves. This
     * is the single most common "my Mabu is broken" report, and it is almost
     * always a missing wake.
     *
     * The sequence that works, determined empirically:
     *
     *     power-on frame, wait 200 ms   x5
     *     wait 1000 ms
     *     then your first move
     *
     * Repeating five times guarantees at least one lands after the MCU is
     * listening. The final second lets the board settle before it is asked to
     * move something.
     *
     * All of it must happen on ONE open file descriptor. Closing and
     * reopening between frames has been observed to fail, because a close can
     * drop DTR and reset the board's command-accept state.
     *
     * Once woken, the board stays awake until the next power cycle, so a
     * second call is harmless but pointless.
     *
     * Blocks for about 2 seconds. Call it off the main thread - [MotorTween]
     * does this for you on its own thread.
     */
    fun wake() {
        if (fd < 0) return
        Log.i(TAG, "wake: sending power-on x$WAKE_REPEATS")
        repeat(WAKE_REPEATS) {
            send(MabuProtocol.POWER_ON)
            Thread.sleep(WAKE_GAP_MS)
        }
        Thread.sleep(WAKE_SETTLE_MS)
        awake = true
        Log.i(TAG, "wake: done, board should be listening")
    }

    // -----------------------------------------------------------------------
    // ROW 5: SENDING
    // -----------------------------------------------------------------------

    /**
     * Move any subset of motors in a single atomic frame.
     *
     * Prefer this over several single-motor calls: one frame means the board
     * applies the whole pose on one tick, so a blink plus a head turn land
     * together instead of rippling.
     */
    fun move(values: Map<Int, Float>) {
        val frame = MabuProtocol.moveFrame(values) ?: return
        send(frame)
    }

    fun move(motorBit: Int, value: Float) = move(mapOf(motorBit to value))

    /**
     * Write raw bytes to the port.
     *
     * Synchronized because a half-written frame is worse than no frame: the
     * board would read the tail of one command as the head of another. In
     * this app only the tween thread sends, but the lock costs nothing and
     * removes a whole class of bug if you later send from somewhere else.
     */
    fun send(bytes: ByteArray) {
        // Hold the lock for the write and nothing else. Logging is slow
        // enough to be worth keeping outside a lock that a 25 Hz tick wants.
        val n = synchronized(lock) {
            if (fd < 0) return
            SerialPort.writeBytes(fd, bytes, 0, bytes.size)
        }

        if (n < 0) {
            Log.w(TAG, "write failed errno=${-n}: ${MabuProtocol.hex(bytes)}")
        } else if (VERBOSE) {
            Log.d(TAG, "tx ${MabuProtocol.hex(bytes)}")
        }
    }

    companion object {
        private const val TAG = "MabuSerial"

        /** Flip to true to log every frame. Noisy: the tween sends at up to 25 Hz. */
        private const val VERBOSE = false

        private const val WAKE_REPEATS = 5
        private const val WAKE_GAP_MS = 200L
        private const val WAKE_SETTLE_MS = 1000L
    }
}

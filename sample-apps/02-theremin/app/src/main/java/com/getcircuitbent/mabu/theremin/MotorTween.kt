package com.getcircuitbent.mabu.theremin

import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import kotlin.math.abs

/**
 * ============================================================================
 * INDEX ROW 10 - the motion engine. Read this before writing any Mabu app.
 * ============================================================================
 *
 * This class is why the robot looks smooth instead of sounding like a box of
 * angry crickets, and the architecture matters more than the code.
 *
 * ---------------------------------------------------------------------------
 * THE PROBLEM
 * ---------------------------------------------------------------------------
 * The obvious design is: something decides where to look, and immediately
 * sends a motor frame. Face tracker gets a new box, send a frame. Slider
 * moves, send a frame. It works, and it sounds terrible - the servos chatter
 * audibly, hunting a target that keeps twitching by a fraction of a degree.
 *
 * Two things cause that:
 *  1. Inputs are noisy. Whatever drives the motors (a sensor, a sine wave, a
 *     finger on a slider) produces small jitter that has no business reaching
 *     a servo.
 *  2. Inputs are bursty. If motor I/O happens on the input's schedule, the
 *     wire traffic inherits the input's timing, including its stalls.
 *
 * ---------------------------------------------------------------------------
 * THE FIX: DECOUPLE, FILTER, AND THEN REFUSE TO SEND
 * ---------------------------------------------------------------------------
 * Three separate mechanisms, each doing one job:
 *
 *  1. DECOUPLING. Producers never touch the serial port. They only write
 *     TARGET values. This thread ticks at a fixed 25 Hz and is the only thing
 *     in the whole app allowed to send a frame. Motor cadence is therefore
 *     constant no matter what the producers do.
 *
 *  2. LOW-PASS FILTER. Each tick, every motor's position moves a fraction
 *     (alpha) of the way toward its target:
 *
 *         pos += (target - pos) * alpha
 *
 *     This is a one-line exponential filter. Small alpha = heavy smoothing
 *     and slow response, large alpha = twitchy and responsive. It also means
 *     the robot NEVER steps instantly to a new value, so a target that jumps
 *     produces a glide rather than a snap.
 *
 *  3. SEND DEADBAND. Even after filtering, the position keeps creeping by
 *     tiny amounts as it converges. Sending those is what actually makes the
 *     noise. So: if no motor has moved at least SEND_DEADBAND from what was
 *     last put on the wire, send nothing at all. A motor sitting on its
 *     target produces ZERO serial traffic.
 *
 * Number 3 is the one people leave out, and it is the one that fixes the
 * rattle. Numbers 1 and 2 make motion look good; number 3 makes it quiet.
 *
 * ---------------------------------------------------------------------------
 * TWO WAYS TO WRITE A VALUE
 * ---------------------------------------------------------------------------
 * [setTarget] - eased. The value is a destination; the filter decides how to
 *     get there. Use for anything that jumps or jitters: sliders, poses, the
 *     idle sweep.
 *
 * [setImmediate] - not eased. The caller has already done its own
 *     interpolation and knows exactly what it wants this instant. Use for
 *     scripted gestures, which time their own steps in milliseconds and would
 *     be made mushy and late by a second round of smoothing.
 *
 * Both still pass through the send deadband, so neither can cause chatter.
 */
class MotorTween(private val link: MotorLink) {

    // -----------------------------------------------------------------------
    // TUNING
    // -----------------------------------------------------------------------

    /**
     * 25 Hz. Fast enough that motion looks continuous, slow enough to leave
     * the CPU alone. The RK3288 is not fast and this thread runs forever.
     */
    private val tickMs = 40L

    /**
     * Per-tick filter strength, per motor group.
     *
     * Eyes are quick and neck is slow on purpose: in a real face the eyes
     * arrive first and the head follows. Matching alphas makes the robot look
     * like a mechanism; different ones make it look like it is paying
     * attention.
     *
     * At 25 Hz, alpha 0.30 reaches 63% of a new target in about 80 ms,
     * alpha 0.12 in about 250 ms.
     */
    private val eyeAlpha = 0.30f
    private val neckAlpha = 0.12f

    /** Eyelids snap. A gentle, eased blink looks like the robot is unwell. */
    private val lidAlpha = 0.80f

    /**
     * Output deadband in logical units. About 2.5 wire steps.
     *
     * Raising this makes the robot quieter and its motion steppier. Lowering
     * it does the reverse. 1.0 was arrived at on hardware: below it, the
     * eye motors chattered while converging.
     */
    private val sendDeadband = 1.0f

    // -----------------------------------------------------------------------
    // STATE
    // -----------------------------------------------------------------------
    // Indexed by position in MabuProtocol.MOTORS, i.e. MSB-first order.

    private val motors = MabuProtocol.MOTORS
    private val n = motors.size

    /** Where each motor is being asked to go. Written by producers. */
    private val target = FloatArray(n) { motors[it].neutral }

    /** Where each motor actually is, after filtering. */
    private val position = FloatArray(n) { motors[it].neutral }

    /** What was last actually put on the wire; the deadband compares to this. */
    private val lastSent = FloatArray(n) { Float.NaN }

    private var thread: HandlerThread? = null
    private var handler: Handler? = null

    @Volatile
    private var running = false

    /**
     * Called on the tween thread at the top of every tick, before filtering.
     * This is where a behaviour (the idle scene) gets to update targets.
     *
     * IT MUST NOT BLOCK. See the warning in IdleScene.
     */
    @Volatile
    var onTick: ((nowMs: Long) -> Unit)? = null

    /** Frames actually written since start. Shown in the admin header. */
    @Volatile
    var framesSent: Long = 0L
        private set

    // -----------------------------------------------------------------------
    // LIFECYCLE
    // -----------------------------------------------------------------------

    /**
     * Open the port, wake the board, and start ticking.
     *
     * Everything happens on the tween thread, including the roughly 2-second
     * wake sequence, so the UI never blocks. Callers get a callback when the
     * link is up (or has failed) so they can update the status line.
     */
    fun start(onReady: (Boolean) -> Unit) {
        if (running) return
        running = true

        val t = HandlerThread("mabu-tween").apply { start() }
        thread = t
        val h = Handler(t.looper)
        handler = h

        h.post {
            val ok = link.open()
            if (ok) {
                // Once per power cycle. See MotorLink.wake - this is the step
                // everyone skips and then spends an evening debugging.
                link.wake()

                // Land on a known pose so the robot does not sit in whatever
                // position it powered up in.
                for (i in 0 until n) {
                    target[i] = motors[i].neutral
                    position[i] = motors[i].neutral
                }
                sendIfChanged(force = true)
            }
            onReady(ok)
            if (ok) h.postDelayed(tickRunnable, tickMs)
        }
    }

    fun stop() {
        running = false
        handler?.removeCallbacksAndMessages(null)
        handler?.post {
            link.close()
            thread?.quitSafely()
        }
    }

    private val tickRunnable = object : Runnable {
        override fun run() {
            if (!running) return
            val now = SystemClock.uptimeMillis()

            // 1. Let the behaviour update targets.
            try {
                onTick?.invoke(now)
            } catch (t: Throwable) {
                // A crash in a behaviour must not kill motor I/O; the robot
                // would freeze mid-pose with no way back short of a restart.
                Log.e(TAG, "onTick threw", t)
            }

            // 2. Filter positions toward targets.
            for (i in 0 until n) {
                val a = alphaFor(motors[i].bit)
                position[i] += (target[i] - position[i]) * a
            }

            // 3. Send, if anything has actually moved enough to matter.
            sendIfChanged()

            // Fixed cadence: schedule from now, not from when we started, so
            // a slow tick does not compound into drift.
            handler?.postDelayed(this, tickMs)
        }
    }

    private fun alphaFor(bit: Int): Float = when (bit) {
        MabuProtocol.LDL, MabuProtocol.LDR -> lidAlpha
        MabuProtocol.ELR, MabuProtocol.EUD -> eyeAlpha
        else -> neckAlpha
    }

    /**
     * The deadband, and the only place a move frame is emitted.
     *
     * Note it is all-or-nothing across all seven motors: if ANY motor has
     * moved enough, we send every motor in one atomic frame. That is cheaper
     * than it sounds (one 12-byte frame instead of up to seven 9-byte ones)
     * and it means a pose lands on a single board tick.
     */
    private fun sendIfChanged(force: Boolean = false) {
        var changed = force
        if (!changed) {
            for (i in 0 until n) {
                val last = lastSent[i]
                if (last.isNaN() || abs(position[i] - last) >= sendDeadband) {
                    changed = true
                    break
                }
            }
        }
        if (!changed) return

        val values = HashMap<Int, Float>(n)
        for (i in 0 until n) {
            values[motors[i].bit] = position[i]
            lastSent[i] = position[i]
        }
        link.move(values)
        framesSent++
    }

    // -----------------------------------------------------------------------
    // PRODUCER API
    // -----------------------------------------------------------------------

    private fun indexOf(bit: Int): Int = motors.indexOfFirst { it.bit == bit }

    /** Eased. The filter decides how to get there. */
    fun setTarget(bit: Int, value: Float) {
        val i = indexOf(bit)
        if (i >= 0) target[i] = value.coerceIn(MabuProtocol.MIN, MabuProtocol.MAX)
    }

    fun setTargets(values: Map<Int, Float>) = values.forEach { (b, v) -> setTarget(b, v) }

    /**
     * Not eased: sets the position directly as well as the target.
     * For callers that time their own motion, like scripted gestures.
     */
    fun setImmediate(bit: Int, value: Float) {
        val i = indexOf(bit)
        if (i < 0) return
        val v = value.coerceIn(MabuProtocol.MIN, MabuProtocol.MAX)
        target[i] = v
        position[i] = v
    }

    /** Where a motor has been asked to go. The UI sliders read this. */
    fun target(bit: Int): Float {
        val i = indexOf(bit)
        return if (i >= 0) target[i] else 0f
    }

    /** Where a motor actually is right now, after filtering. */
    fun position(bit: Int): Float {
        val i = indexOf(bit)
        return if (i >= 0) position[i] else 0f
    }

    companion object {
        private const val TAG = "MabuTween"
    }
}

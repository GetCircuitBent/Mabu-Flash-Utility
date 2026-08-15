package com.getcircuitbent.mabu.theremin

import android.util.Log
import kotlin.math.PI
import kotlin.math.sin
import kotlin.random.Random

/**
 * ============================================================================
 * INDEX ROWS 8, 9 AND 10 COMBINED - the behaviour that makes the sign alive.
 * ============================================================================
 *
 * This is what runs while the sign is on screen. Three things at once:
 *
 *   - a slow side-to-side sweep of the head, with the eyes leading it
 *   - a blink every few seconds
 *   - now and then, a random gesture from [Gestures.IDLE_POOL]
 *
 * ---------------------------------------------------------------------------
 * THE IMPORTANT IDEA: TWO KINDS OF MOTION
 * ---------------------------------------------------------------------------
 * These three behaviours are not the same kind of thing, and treating them as
 * if they were is where idle loops usually go wrong.
 *
 * CONTINUOUS motion is a FUNCTION OF TIME. The sweep is literally sin(t):
 * given the clock, you can compute where the head should be right now, from
 * scratch, with no memory of what happened before. Nothing to start, nothing
 * to cancel, nothing to get out of sync. If you find yourself storing
 * "sweep progress" in a variable, you have made it harder than it is.
 *
 * ONE-SHOT motion is a SCHEDULED EVENT. A blink has a beginning and an end,
 * it temporarily takes over some motors, and then it gives them back. These
 * need state: when is the next one due, and is one running now.
 *
 * Mixing the two is the whole trick. The sweep writes ELR and NR every single
 * tick; a blink owns LDL and LDR for 200 ms; a random gesture claims whatever
 * motors it names for its duration. They coexist because the sweep skips any
 * motor a gesture has claimed - see [claimed] below. That is why the head can
 * keep sweeping while the eyes blink, with no coordination between them.
 *
 * ---------------------------------------------------------------------------
 * *** NEVER BLOCK IN HERE ***
 * ---------------------------------------------------------------------------
 * [tick] is called from the tween thread, which is the thread that owns the
 * serial port. A Thread.sleep in this file stops all motor output, the UI's
 * view of the robot, and any chance of cancelling. Everything below is
 * written as "look at the clock, decide what should be true now, return".
 *
 * If you want a pause in a behaviour, schedule a time and check for it - the
 * way [nextBlinkMs] does. Never sleep.
 */
class IdleScene(
    private val tween: MotorTween,
    private val player: GesturePlayer,
) {

    // -----------------------------------------------------------------------
    // TUNABLES - all exposed as sliders in the admin screen
    // -----------------------------------------------------------------------

    /** How far the head swings either side of centre, in logical units. */
    @Volatile var sweepAmplitude = 15f

    /** Seconds for one complete left-right-left cycle. */
    @Volatile var sweepPeriodSec = 8f

    /** Blink interval range, seconds. A real blink rate is about 3 to 7 s. */
    @Volatile var blinkMinSec = 3f
    @Volatile var blinkMaxSec = 7f

    /** Random-gesture interval range, seconds. */
    @Volatile var gestureMinSec = 20f
    @Volatile var gestureMaxSec = 45f

    /** Master switch. When false, [tick] does nothing at all. */
    @Volatile var enabled = true

    // -----------------------------------------------------------------------
    // STATE - only the one-shots need any
    // -----------------------------------------------------------------------

    private var startMs = 0L
    private var nextBlinkMs = 0L
    private var nextGestureMs = 0L

    /** Last gesture fired, so we do not repeat one twice running. */
    private var lastGesture: Gesture? = null

    private val random = Random(System.nanoTime())

    /**
     * Re-arm the schedules. Called when idle is switched on, so the robot does
     * not immediately blink because a timer expired while it was off.
     */
    fun reset(nowMs: Long) {
        startMs = nowMs
        nextBlinkMs = nowMs + randomMs(blinkMinSec, blinkMaxSec)
        nextGestureMs = nowMs + randomMs(gestureMinSec, gestureMaxSec)
    }

    private fun randomMs(minSec: Float, maxSec: Float): Long {
        val lo = minSec.coerceAtLeast(0.1f)
        val hi = maxSec.coerceAtLeast(lo + 0.1f)
        return ((lo + random.nextFloat() * (hi - lo)) * 1000f).toLong()
    }

    // -----------------------------------------------------------------------
    // THE TICK
    // -----------------------------------------------------------------------

    /**
     * Called from MotorTween at 25 Hz. Must return promptly; see the warning
     * at the top of this file.
     */
    fun tick(nowMs: Long) {
        // A gesture is always advanced, even when idle is off - that is how a
        // gesture button works while the robot is otherwise being driven by
        // hand from the sliders.
        player.tick(nowMs)

        if (!enabled) return
        if (startMs == 0L) reset(nowMs)

        // Motors currently owned by a playing gesture. The sweep must not
        // write these, or the two would fight and the gesture would stutter.
        val claimed = player.claimedMotors

        // --- CONTINUOUS: the sweep --------------------------------------
        // Pure function of the clock. Note there is no state here at all.
        val periodMs = (sweepPeriodSec.coerceAtLeast(0.5f) * 1000f)
        val phase = ((nowMs - startMs) % periodMs.toLong()) / periodMs * 2f * PI.toFloat()
        val swing = sin(phase) * sweepAmplitude

        // The eyes lead the head. Feeding the eyes a phase-advanced version of
        // the same wave means they arrive at each extreme slightly before the
        // neck does, which is what makes the movement read as "looking at
        // something" rather than "panning".
        val eyeSwing = sin(phase + EYE_LEAD_RADIANS) * sweepAmplitude * EYE_GAIN

        // ELR: higher = eyes right. NR: higher = head LEFT. To point both the
        // same way the neck term is negated. This inversion is real and is
        // documented in MabuProtocol.MOTORS; it is not a bug.
        if (claimed and MabuProtocol.ELR == 0) {
            tween.setTarget(MabuProtocol.ELR, 50f + eyeSwing)
        }
        if (claimed and MabuProtocol.NR == 0) {
            tween.setTarget(MabuProtocol.NR, 50f - swing)
        }

        // --- ONE-SHOT: blink --------------------------------------------
        if (nowMs >= nextBlinkMs && !player.isPlaying) {
            player.play(Gestures.BLINK, nowMs)
            nextBlinkMs = nowMs + randomMs(blinkMinSec, blinkMaxSec)
        }

        // --- ONE-SHOT: random gesture -----------------------------------
        if (nowMs >= nextGestureMs && !player.isPlaying) {
            val pick = pickGesture()
            if (pick != null) {
                Log.d(TAG, "idle gesture: ${pick.name}")
                player.play(pick, nowMs)
                lastGesture = pick
            }
            nextGestureMs = nowMs + randomMs(gestureMinSec, gestureMaxSec)
        }
    }

    /** Pick from the idle pool, avoiding an immediate repeat. */
    private fun pickGesture(): Gesture? {
        val pool = Gestures.IDLE_POOL
        if (pool.isEmpty()) return null
        if (pool.size == 1) return pool[0]
        var pick = pool[random.nextInt(pool.size)]
        if (pick === lastGesture) {
            pick = pool[(pool.indexOf(pick) + 1 + random.nextInt(pool.size - 1)) % pool.size]
        }
        return pick
    }

    companion object {
        private const val TAG = "MabuIdle"

        /**
         * How far ahead of the neck the eyes run, in radians. About an eighth
         * of a cycle. Larger values look eager, smaller look sleepy, and zero
         * looks robotic.
         */
        private const val EYE_LEAD_RADIANS = 0.8f

        /** Eyes swing further than the neck, in proportion. */
        private const val EYE_GAIN = 1.6f
    }
}

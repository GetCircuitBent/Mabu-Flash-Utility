package com.getcircuitbent.mabu.signboard

import com.getcircuitbent.mabu.signboard.MabuProtocol.ELR
import com.getcircuitbent.mabu.signboard.MabuProtocol.EUD
import com.getcircuitbent.mabu.signboard.MabuProtocol.EYELID_CLOSED
import com.getcircuitbent.mabu.signboard.MabuProtocol.EYELID_OPEN
import com.getcircuitbent.mabu.signboard.MabuProtocol.LDL
import com.getcircuitbent.mabu.signboard.MabuProtocol.LDR
import com.getcircuitbent.mabu.signboard.MabuProtocol.NE
import com.getcircuitbent.mabu.signboard.MabuProtocol.NR
import com.getcircuitbent.mabu.signboard.MabuProtocol.NT

/**
 * ============================================================================
 * INDEX ROWS 8 AND 9 - scripting a sequence of motions.
 * ============================================================================
 *
 * THIS IS THE FILE TO COPY if you want your robot to *do* things rather than
 * just hold positions. Everything you need to write your own animations is
 * here, and it is about eighty lines of actual machinery.
 *
 * ---------------------------------------------------------------------------
 * HOW A GESTURE IS PUT TOGETHER
 * ---------------------------------------------------------------------------
 * A gesture is a list of STEPS, read top to bottom like a storyboard. Each
 * step says:
 *
 *     "move these motors to these values, take this long getting there,
 *      then wait this long before starting the next step"
 *
 * So a nod is three steps: up, down, level. A blink is two: shut, open.
 *
 *     val NOD_YES = gesture("Nod Yes") {
 *         step(NE to 62f, overMs = 250)   // chin up
 *         step(NE to 38f, overMs = 350)   // chin down
 *         step(NE to 50f, overMs = 250)   // back to level
 *         hold(120)                       // a beat before anything else
 *     }
 *
 * Values are logical 0..100. Check MabuProtocol.MOTORS for what each motor
 * does and which direction is which - several of them are counter-intuitive
 * and two are outright inverted.
 *
 * ---------------------------------------------------------------------------
 * ADDING YOUR OWN GESTURE: FOUR STEPS
 * ---------------------------------------------------------------------------
 * 1. Write it below using `gesture("Name") { ... }`.
 * 2. Add it to the [ALL] list.
 * 3. There is no step 3. The admin screen builds its buttons from [ALL], and
 *    the ADB GESTURE broadcast resolves names against [ALL], so both find it
 *    with no further wiring.
 * 4. If you want the idle scene to fire it at random, add it to [IDLE_POOL]
 *    as well. Not every gesture belongs there - some are too big to do
 *    unprompted every thirty seconds.
 *
 * ---------------------------------------------------------------------------
 * THINGS WORTH KNOWING BEFORE YOU WRITE ONE
 * ---------------------------------------------------------------------------
 * * A gesture only touches the motors it names. Motors it never mentions are
 *   left entirely alone, which is what lets a blink happen in the middle of a
 *   head sweep without the two fighting over the neck.
 *
 * * Asymmetric timing is what makes motion read as physical. In NOD_YES the
 *   downward step is slower than the upward one, so it looks like the head
 *   has weight. Equal times look like a machine executing a plan.
 *
 * * Nothing here sleeps. See [GesturePlayer].
 */

// ---------------------------------------------------------------------------
// THE FORMAT
// ---------------------------------------------------------------------------

/** One step: where to put some motors, how long to take, how long to wait after. */
data class GestureStep(
    val values: Map<Int, Float>,
    val overMs: Long,
    val holdMs: Long = 0L,
)

data class Gesture(val name: String, val steps: List<GestureStep>) {
    /**
     * Every motor this gesture touches, as a bitmask. The idle scene uses
     * this to know which motors to keep its hands off while the gesture runs.
     */
    val motorMask: Int = steps.fold(0) { acc, s -> acc or s.values.keys.fold(0, Int::or) }

    val totalMs: Long = steps.sumOf { it.overMs + it.holdMs }
}

/** Small builder so gesture definitions read like a script. */
class GestureBuilder {
    private val steps = mutableListOf<GestureStep>()

    /** Move the given motors to the given values over [overMs] milliseconds. */
    fun step(vararg values: Pair<Int, Float>, overMs: Long, holdMs: Long = 0L) {
        steps += GestureStep(mapOf(*values), overMs, holdMs)
    }

    /** Do nothing for a while. Beats between motions matter as much as the motions. */
    fun hold(ms: Long) {
        steps += GestureStep(emptyMap(), 0L, ms)
    }

    fun build(name: String) = Gesture(name, steps.toList())
}

fun gesture(name: String, block: GestureBuilder.() -> Unit): Gesture =
    GestureBuilder().apply(block).build(name)

// ---------------------------------------------------------------------------
// THE GESTURES
// ---------------------------------------------------------------------------

object Gestures {

    /**
     * A blink. Shut fast, open slightly slower - that asymmetry is what real
     * eyelids do, and getting it backwards looks distinctly wrong.
     */
    val BLINK = gesture("Blink") {
        step(LDL to EYELID_CLOSED, LDR to EYELID_CLOSED, overMs = 80)
        step(LDL to EYELID_OPEN, LDR to EYELID_OPEN, overMs = 120)
    }

    /** Two blinks in quick succession. Reads as surprise, or as a greeting. */
    val DOUBLE_BLINK = gesture("Double Blink") {
        step(LDL to EYELID_CLOSED, LDR to EYELID_CLOSED, overMs = 70)
        step(LDL to EYELID_OPEN, LDR to EYELID_OPEN, overMs = 90, holdMs = 90)
        step(LDL to EYELID_CLOSED, LDR to EYELID_CLOSED, overMs = 70)
        step(LDL to EYELID_OPEN, LDR to EYELID_OPEN, overMs = 110)
    }

    /** One eyelid only. Cheap and always gets a reaction from passers-by. */
    val WINK = gesture("Wink") {
        step(LDL to EYELID_CLOSED, overMs = 90, holdMs = 130)
        step(LDL to EYELID_OPEN, overMs = 130)
    }

    /** Yes. Up, down (slower, so it reads as weight), level. */
    val NOD_YES = gesture("Nod Yes") {
        step(NE to 62f, overMs = 250)
        step(NE to 38f, overMs = 350)
        step(NE to 50f, overMs = 250)
        hold(120)
    }

    /**
     * No. Two full sweeps either side of centre, then settle.
     * NR: higher = turn left, so this goes left, right, left, centre.
     */
    val SHAKE_NO = gesture("Shake No") {
        step(NR to 62f, overMs = 220)
        step(NR to 38f, overMs = 300)
        step(NR to 60f, overMs = 280)
        step(NR to 50f, overMs = 220)
        hold(120)
    }

    /** A quizzical head tilt. Small movement, disproportionate effect. */
    val TILT = gesture("Tilt") {
        step(NT to 63f, overMs = 320, holdMs = 700)
        step(NT to 50f, overMs = 380)
    }

    /**
     * Glance away and back, as if something moved in the corner of the room.
     * Eyes lead, head follows a beat later, which is the ordering that makes
     * it look like attention rather than choreography.
     */
    val LOOK_AWAY = gesture("Look Away") {
        step(ELR to 78f, overMs = 180)
        step(NR to 36f, EUD to 42f, overMs = 400, holdMs = 600)
        step(ELR to 50f, overMs = 260)
        step(NR to 50f, EUD to 50f, overMs = 420)
    }

    /**
     * A slow scan across the room. Long and deliberate: good for a signboard
     * that wants to look like it is watching the street.
     */
    val SCAN = gesture("Scan") {
        step(ELR to 22f, overMs = 500)
        step(NR to 64f, overMs = 700, holdMs = 400)
        step(ELR to 78f, overMs = 700)
        step(NR to 36f, overMs = 900, holdMs = 400)
        step(ELR to 50f, NR to 50f, overMs = 700)
    }

    /** Every gesture, in admin-button order. Add yours here. */
    val ALL = listOf(BLINK, DOUBLE_BLINK, WINK, NOD_YES, SHAKE_NO, TILT, LOOK_AWAY, SCAN)

    /**
     * The subset the idle scene may fire spontaneously.
     *
     * BLINK is excluded because idle already blinks on its own schedule, and
     * SCAN is excluded because it takes four seconds and would dominate.
     */
    val IDLE_POOL = listOf(DOUBLE_BLINK, WINK, NOD_YES, TILT, LOOK_AWAY)

    fun byName(name: String): Gesture? =
        ALL.firstOrNull { it.name.equals(name, ignoreCase = true) }
}

// ---------------------------------------------------------------------------
// THE PLAYER
// ---------------------------------------------------------------------------

/**
 * Plays one gesture at a time by being ticked, never by sleeping.
 *
 * ***********************************************************************
 * WHY THERE IS NO Thread.sleep IN HERE
 * ***********************************************************************
 * The obvious way to write this is a loop that moves a motor, sleeps for the
 * step duration, moves it again. Do not do that. The thread that plays
 * gestures is the same thread that owns the serial port, so a sleeping
 * gesture is a robot that has stopped listening: no idle motion, no response
 * to the UI, no way to cancel, for as long as the gesture lasts. It also
 * means two gestures can never overlap or interrupt each other.
 *
 * Instead this is a state machine. [tick] is called 25 times a second, works
 * out where in the script it should be by looking at the clock, writes the
 * interpolated values, and returns immediately. A four-second SCAN occupies
 * the thread for microseconds at a time.
 *
 * This is the same principle as the tween itself: own the clock, never block.
 */
class GesturePlayer(private val tween: MotorTween) {

    private var gesture: Gesture? = null
    private var stepIndex = 0
    private var stepStartMs = 0L

    /** Values each motor held when the current step began, for interpolation. */
    private var stepFrom: Map<Int, Float> = emptyMap()

    /** True while a gesture is playing. */
    val isPlaying: Boolean get() = gesture != null

    /**
     * Motors currently claimed by the playing gesture. Anything else driving
     * the robot should leave these alone until the gesture finishes.
     */
    val claimedMotors: Int get() = gesture?.motorMask ?: 0

    val currentName: String? get() = gesture?.name

    /**
     * Start a gesture, replacing any gesture already playing.
     *
     * Replacing rather than queueing is deliberate: if a passer-by mashes
     * three buttons, the robot should do the last thing asked, not work
     * through a backlog for ten seconds.
     */
    fun play(g: Gesture, nowMs: Long) {
        gesture = g
        stepIndex = 0
        stepStartMs = nowMs
        stepFrom = captureFrom(g.steps.firstOrNull())
    }

    fun cancel() {
        gesture = null
    }

    /** Snapshot where the motors in this step currently are, so we can lerp. */
    private fun captureFrom(step: GestureStep?): Map<Int, Float> =
        step?.values?.keys?.associateWith { tween.position(it) } ?: emptyMap()

    /**
     * Advance the gesture. Call once per tween tick.
     * @return true if a gesture is still playing after this tick.
     */
    fun tick(nowMs: Long): Boolean {
        val g = gesture ?: return false

        while (true) {
            if (stepIndex >= g.steps.size) {
                gesture = null
                return false
            }

            val step = g.steps[stepIndex]
            val elapsed = nowMs - stepStartMs

            if (elapsed < step.overMs) {
                // Mid-movement: linear interpolation from where we started to
                // where the step wants us. Written with setImmediate because
                // the gesture is already doing its own timing - running this
                // through the tween's filter as well would make every step
                // late and mushy.
                val t = if (step.overMs <= 0L) 1f else elapsed.toFloat() / step.overMs
                for ((bit, to) in step.values) {
                    val from = stepFrom[bit] ?: tween.position(bit)
                    tween.setImmediate(bit, from + (to - from) * t)
                }
                return true
            }

            // Movement finished: pin the exact target values, then see whether
            // we are still in this step's hold time.
            for ((bit, to) in step.values) tween.setImmediate(bit, to)

            if (elapsed < step.overMs + step.holdMs) return true

            // Step complete. Advance and loop, so a zero-length step does not
            // waste a whole tick.
            stepIndex++
            stepStartMs += step.overMs + step.holdMs
            stepFrom = captureFrom(g.steps.getOrNull(stepIndex))
        }
    }
}

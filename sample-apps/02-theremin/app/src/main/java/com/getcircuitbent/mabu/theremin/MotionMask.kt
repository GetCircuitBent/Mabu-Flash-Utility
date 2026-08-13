package com.getcircuitbent.mabu.theremin

import kotlin.math.abs

/**
 * ============================================================================
 * INDEX ROW 26 - tracker A: motion. The default.
 * ============================================================================
 *
 * "Interesting" means "this pixel's brightness is not what the room usually
 * looks like here."
 *
 * ---------------------------------------------------------------------------
 * THE ALGORITHM, IN FULL
 * ---------------------------------------------------------------------------
 *     background = background * (1 - adaptRate) + frame * adaptRate
 *     mask       = |frame - background| > threshold
 *
 * That is a running-average background model, and it is two lines because
 * that is genuinely all it is. The background is a slowly-updated guess at
 * the empty room; anything that differs from the guess is a thing.
 *
 * ---------------------------------------------------------------------------
 * WHY THIS IS THE DEFAULT
 * ---------------------------------------------------------------------------
 * * NO CALIBRATION. It works the second the app opens, for anybody, with
 *   nothing in their hands. A sample app that needs a setup ritual before it
 *   does anything is a worse sample app.
 * * SKIN TONE IS IRRELEVANT. This only ever looks at CHANGE IN BRIGHTNESS. It
 *   never asks what colour anything is, so it cannot be better at finding
 *   some people's hands than others'. See ToneMask for the discussion that
 *   this mode simply does not have to have.
 * * IT IS THE CHEAPEST THING IN THE APP. One subtract and compare per sampled
 *   pixel: about 3 ms for a frame.
 *
 * ---------------------------------------------------------------------------
 * WHAT IT COSTS: THE HELD HAND
 * ---------------------------------------------------------------------------
 * A hand held perfectly still stops being different from the background,
 * because the background model catches up with it and absorbs it. Then it
 * disappears and your note dies.
 *
 * This is not a bug and it cannot be fixed, only traded, which is what
 * [adaptRate] is for:
 *
 *   FAST adapt (0.05+) - the room re-learns quickly, so lighting changes and
 *       moved furniture stop being "interesting" almost immediately. A held
 *       hand vanishes in about a second.
 *   SLOW adapt (0.005)  - a held hand survives for many seconds. But every
 *       change lingers: move a chair and you get a ghost of it for a minute,
 *       and your own last few positions smear behind you.
 *
 * There is no correct value, which is exactly why it is a slider on the main
 * screen. Sliding it while watching the mask teaches more about background
 * modelling than any comment could, including this one.
 *
 * If you want to hold a note, use ToneMask. That is the whole reason there
 * are two.
 */
class MotionMask : HandTracker {

    override val name = "Motion"

    /**
     * How fast the background model forgets. See the discussion above; this
     * is the single most instructive control in the app.
     */
    @Volatile
    var adaptRate = 0.02f

    /**
     * How different a pixel must be to count, in luma units (0..255).
     *
     * Too low and sensor noise lights up the whole frame. Too high and only
     * high-contrast motion registers, so a hand against a mid-grey wall
     * disappears. 18 is a starting guess; tune it on hardware.
     */
    @Volatile
    var threshold = 18

    /** The background model, in luma, at mask resolution. Float so it can creep. */
    private var background: FloatArray? = null

    override fun reset() {
        background = null
    }

    override fun buildMask(nv21: ByteArray, width: Int, height: Int, out: ByteArray) {
        val mw = HandTracking.maskW
        val mh = HandTracking.maskH
        val step = HandTracking.STEP

        var bg = background
        if (bg == null || bg.size != mw * mh) {
            // First frame: seed the background WITH the frame, so we do not
            // spend the first second reporting that the entire room is
            // interesting. Costs us any hand present at startup, which the
            // background then forgets about within a few seconds anyway.
            bg = FloatArray(mw * mh)
            for (my in 0 until mh) {
                for (mx in 0 until mw) {
                    bg[my * mw + mx] =
                        HandTracking.luma(nv21, width, mx * step, my * step).toFloat()
                }
            }
            background = bg
            java.util.Arrays.fill(out, 0)
            return
        }

        val a = adaptRate.coerceIn(0.001f, 0.2f)
        val t = threshold

        for (my in 0 until mh) {
            val rowBase = my * mw
            val py = my * step
            for (mx in 0 until mw) {
                val i = rowBase + mx
                val v = HandTracking.luma(nv21, width, mx * step, py).toFloat()

                // Interesting if it differs from what we expect the room to
                // look like here.
                out[i] = if (abs(v - bg[i]) > t) 1 else 0

                // Then let the model creep toward reality. Note this happens
                // whether or not the pixel was interesting: that is precisely
                // what makes a held hand fade, and making it conditional
                // ("do not learn where we saw something") is the classic
                // next step, at the cost of ghosts that never clear.
                bg[i] = bg[i] * (1f - a) + v * a
            }
        }
    }

    override fun calibrationSummary(): String =
        "adapt %.3f · threshold %d".format(adaptRate, threshold)
}

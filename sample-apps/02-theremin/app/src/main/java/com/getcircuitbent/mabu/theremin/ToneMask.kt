package com.getcircuitbent.mabu.theremin

import android.util.Log
import kotlin.math.abs

/**
 * ============================================================================
 * INDEX ROW 26 - tracker B: colour. The accurate one.
 * ============================================================================
 *
 * "Interesting" means "this pixel's colour matches the one I was calibrated
 * to."
 *
 *     mask = |Cb - targetCb| < tolCb  &&  |Cr - targetCr| < tolCr
 *
 * Its one great advantage over MotionMask: **a motionless hand stays
 * tracked**, indefinitely. If you want to hold a note, this is the mode.
 *
 * ---------------------------------------------------------------------------
 * WHY CHROMA, AND WHY IT IS FREE HERE
 * ---------------------------------------------------------------------------
 * The camera hands us NV21, and NV21 *is* YCbCr: brightness in one plane,
 * colour in another. Comparing colour while ignoring brightness is therefore
 * just reading two bytes. Converting to RGB first, which is most people's
 * instinct, would cost a conversion AND make the comparison worse, because in
 * RGB "the same colour, dimmer" is a completely different triple.
 *
 * ---------------------------------------------------------------------------
 * *** SKIN TONE: WHY THERE ARE NO CONSTANTS IN THIS FILE ***
 * ---------------------------------------------------------------------------
 * Every textbook version of this technique hardcodes a skin range, almost
 * always this one:
 *
 *     77 <= Cb <= 127   and   133 <= Cr <= 173
 *
 * You will find it in a hundred blog posts. It is not in this file, and it is
 * not going to be, because it is biased toward light skin:
 *
 *  1. Those numbers come from late-1990s papers whose datasets were
 *     predominantly light-skinned. The bias in the sample became a constant,
 *     and the constant gets copied around as though it were physics.
 *  2. The usual defence - "chroma is tone-stable, melanin mostly affects
 *     luminance" - is directionally true and not sufficient. Darker skin
 *     reflects less light, so Y is lower, so the SIGNAL-TO-NOISE RATIO in Cb
 *     and Cr is worse. And NV21 already subsamples chroma 2x2, so there is
 *     less of it to average over to begin with.
 *  3. Camera auto-exposure habitually underexposes darker faces, which pushes
 *     the chroma estimate further into the noise.
 *
 * Ship those constants and you ship an instrument that works better for some
 * players than others. That is a defect, and the kind that never shows up in
 * testing unless you go looking for it.
 *
 * SO: this class has no idea what skin looks like. It matches whatever it was
 * told to match, and it is told by [calibrate], from a region of the actual
 * frame - the player's own hand or face, in the room's own light. The biased
 * step is not compensated for, it is absent.
 *
 * Three further things keep it honest:
 *
 *  - A SMALL LUMINANCE ALLOWANCE. The match window widens slightly as
 *    brightness falls, to cover sensor noise. It is deliberately small, and
 *    it is NOT a fix for dim light - see DARK_WIDENING at the bottom of this
 *    file for the measurement that settled that, and for why widening is
 *    self-defeating. Dim light is a regime this tracker cannot rescue; it can
 *    only report it.
 *  - MARKER MODE IS FREE. Because nothing here assumes skin, calibrating to a
 *    brightly coloured glove costs zero extra code and gives the best
 *    tracking in the app for anyone at all. It is the recommended way to use
 *    this mode.
 *  - THE WINDOW IS ON SCREEN. [calibrationSummary] shows the numbers, so a
 *    failure to track is diagnosable instead of mysterious.
 *
 * And if none of it suits: MotionMask never looks at colour and cannot have
 * this problem.
 */
class ToneMask : HandTracker {

    override val name = "Tone"

    /** Centre of the match window. 128 is neutral grey - matches nothing useful. */
    @Volatile private var targetCb = 128
    @Volatile private var targetCr = 128

    /** Mean luma of the calibration sample, for the adaptive tolerance. */
    @Volatile private var targetY = 128

    /** Where the calibration came from, for the UI. */
    @Volatile private var source = "uncalibrated"

    /**
     * Base half-width of the match window, in chroma units.
     *
     * Wider catches more of the hand and more of the furniture. 14 is a
     * starting guess for skin; a saturated marker can go tighter, maybe 8,
     * because nothing else in the room is that colour.
     */
    @Volatile
    var tolerance = 14

    @Volatile
    var calibrated = false
        private set

    /** Self-assessment of the last frame. See [quality]. */
    @Volatile
    private var lastQuality = Quality.unknown()

    /** Tolerance actually used on the last frame, after the luminance widening. */
    @Volatile
    private var lastTol = 0

    /**
     * Take the match colour from a region of the frame.
     *
     * Called with the face box (automatic) or with the centre calibration box
     * (when the operator taps Calibrate while holding a hand or marker in it).
     *
     * Uses the MEDIAN, not the mean: a face box includes eyes, nostrils and
     * shadow, and a mean is dragged around by them. The median lands on the
     * dominant colour in the region, which is the one we want.
     */
    override fun calibrate(nv21: ByteArray, width: Int, height: Int, box: FloatArray) {
        val x0 = (box[0] * width).toInt().coerceIn(0, width - 1)
        val y0 = (box[1] * height).toInt().coerceIn(0, height - 1)
        val x1 = (box[2] * width).toInt().coerceIn(x0 + 1, width)
        val y1 = (box[3] * height).toInt().coerceIn(y0 + 1, height)

        // Shrink to the middle half of the box. For a face that drops hair and
        // background at the edges; for the calibration box it ignores whatever
        // is around the hand.
        val ix0 = x0 + (x1 - x0) / 4
        val ix1 = x1 - (x1 - x0) / 4
        val iy0 = y0 + (y1 - y0) / 4
        val iy1 = y1 - (y1 - y0) / 4

        val cbs = ArrayList<Int>(256)
        val crs = ArrayList<Int>(256)
        val ys = ArrayList<Int>(256)
        var y = iy0
        while (y < iy1) {
            var x = ix0
            while (x < ix1) {
                val c = HandTracking.chroma(nv21, width, height, x, y)
                cbs.add((c shr 8) and 0xFF)
                crs.add(c and 0xFF)
                ys.add(HandTracking.luma(nv21, width, x, y))
                x += 2
            }
            y += 2
        }
        if (cbs.size < 16) {
            Log.w(TAG, "calibration region too small (${cbs.size} samples)")
            return
        }

        cbs.sort(); crs.sort(); ys.sort()
        targetCb = cbs[cbs.size / 2]
        targetCr = crs[crs.size / 2]
        targetY = ys[ys.size / 2]
        calibrated = true
        source = if (box[4] > 0.5f) "face" else "manual"
        Log.i(TAG, "calibrated from $source: Cb=$targetCb Cr=$targetCr Y=$targetY")
    }

    override fun buildMask(nv21: ByteArray, width: Int, height: Int, out: ByteArray) {
        if (!calibrated) {
            java.util.Arrays.fill(out, 0)
            return
        }

        val mw = HandTracking.maskW
        val mh = HandTracking.maskH
        val step = HandTracking.STEP

        // --- Luminance-adaptive tolerance ---------------------------------
        // Widen the window when the picture is dark, because that is where the
        // chroma estimate is least reliable. Read the class comment before
        // changing this: a FIXED tolerance here is how the skin-tone bias gets
        // back in.
        //
        // NOTE THE `min` BELOW, AND WHY IT IS THERE.
        //
        // The first version of this used targetY alone - the brightness of the
        // calibration sample. That is wrong in the exact way that matters: it
        // widens the window only if you happened to CALIBRATE in the dark, and
        // does nothing if you calibrate in good light and the room then dims,
        // which is the common case. The scripts/tone-sweep.py harness caught
        // it: across a sweep from mean luma 172 down to 50, the tolerance never
        // moved off its base value.
        //
        // So it takes the DIMMER of the calibration sample and the frame in
        // front of us now. Either being dark is a reason to be more forgiving.
        val frameY = meanLuma(nv21, width)
        val effectiveY = minOf(targetY, frameY)
        val darkness = ((128 - effectiveY).coerceAtLeast(0)) / 128f   // 0 bright, 1 very dark
        val tol = (tolerance * (1f + darkness * DARK_WIDENING)).toInt().coerceIn(4, 48)
        lastTol = tol

        // Accumulators for the self-assessment, gathered in the same pass so
        // that knowing how well we are doing costs essentially nothing.
        var matched = 0
        var distanceSum = 0L
        var lumaSum = 0L

        for (my in 0 until mh) {
            val rowBase = my * mw
            val py = my * step
            for (mx in 0 until mw) {
                val px = mx * step
                val c = HandTracking.chroma(nv21, width, height, px, py)
                val cb = (c shr 8) and 0xFF
                val cr = c and 0xFF
                val dCb = abs(cb - targetCb)
                val dCr = abs(cr - targetCr)

                if (dCb < tol && dCr < tol) {
                    out[rowBase + mx] = 1
                    matched++
                    // Chebyshev distance: the test is a box, not a circle.
                    distanceSum += maxOf(dCb, dCr).toLong()
                    lumaSum += HandTracking.luma(nv21, width, px, py).toLong()
                } else {
                    out[rowBase + mx] = 0
                }
            }
        }

        lastQuality = assess(matched, mw * mh, distanceSum, lumaSum, tol)
    }

    /**
     * Turn the pass's counters into something an operator can act on.
     *
     * Two different failures need telling apart, and they look identical if you
     * only count matched pixels:
     *
     *   NO MATCH   - calibration is wrong, the light changed, or this is the
     *       failure we could not fully test for: a match window that does not
     *       fit the person standing in front of it.
     *   TOO BROAD  - the window is so wide it has swallowed the room. Blob
     *       extraction then finds one enormous blob and tracking is nonsense.
     *       A different problem with a different fix.
     *
     * MARGIN separates "just barely matching" from "comfortably matching". Near
     * zero means the pixels are scraping the edge of the window, so any change
     * in the light will drop them. That is the early warning, and it appears
     * well before tracking visibly breaks.
     */
    private fun assess(matched: Int, total: Int, distanceSum: Long, lumaSum: Long, tol: Int): Quality {
        if (matched == 0) {
            return Quality(
                0f, 0f, 0, "NO MATCH",
                if (calibrated) "recalibrate, or switch to Motion" else "not calibrated",
            )
        }
        val frac = matched.toFloat() / total
        val meanDist = distanceSum.toFloat() / matched
        val margin = (1f - meanDist / tol).coerceIn(0f, 1f)
        val meanY = (lumaSum / matched).toInt()

        return when {
            frac > 0.35f -> Quality(
                frac, margin, meanY, "TOO BROAD",
                "window is catching the room - lower the tolerance",
            )
            margin < 0.25f -> Quality(
                frac, margin, meanY, "WEAK",
                if (meanY < 70) "very dim - add light, or use Motion"
                else "recalibrate, or try a coloured marker",
            )
            frac < 0.004f -> Quality(
                frac, margin, meanY, "FAINT",
                "matching, but too small to be a hand - move closer",
            )
            else -> Quality(frac, margin, meanY, "GOOD")
        }
    }

    override fun quality(): Quality = lastQuality

    /**
     * Mean luma of the frame, sampled coarsely.
     *
     * Every fourth pixel in each direction: 4,800 reads, which is nothing next
     * to the mask pass, and plenty for an average. We only need to know
     * roughly how dark the room is, not precisely.
     */
    private fun meanLuma(nv21: ByteArray, width: Int): Int {
        var sum = 0L
        var n = 0
        var y = 0
        while (y < HandTracking.FRAME_H) {
            var x = 0
            while (x < width) {
                sum += HandTracking.luma(nv21, width, x, y).toLong()
                n++
                x += 4
            }
            y += 4
        }
        return if (n == 0) 128 else (sum / n).toInt()
    }

    override fun calibrationSummary(): String =
        if (!calibrated) "uncalibrated - tap Calibrate, or use Motion"
        // Shows the base tolerance AND the one actually in force, because they
        // differ in dim light and the difference is the whole point.
        else "Cb $targetCb / Cr $targetCr +/-$tolerance (using $lastTol) from $source"

    override fun reset() {
        calibrated = false
        source = "uncalibrated"
        lastQuality = Quality.unknown()
    }

    companion object {
        private const val TAG = "MabuTone"

        /**
         * How much to widen the match window in dim light.
         *
         * *** THIS NUMBER IS SMALL ON PURPOSE, AND THE REASON IS INTERESTING. ***
         *
         * It started at 1.5, on the reasoning that dim light degrades the
         * chroma estimate so the window should be more forgiving. Running the
         * scripts/tone-sweep.py harness over a luminance sweep showed that is
         * wrong, and wrong in a way worth understanding:
         *
         *   widening    matched fraction of frame, bright -> dark
         *   0.00        14% 14% 14% 14% 14%
         *   0.25        14% 14% 14% 14% 16%
         *   0.50        14% 14% 14% 15% 25%
         *   1.50        14% 15% 36% 78% 96%     <- swallowed the whole room
         *
         * Dim light does not just make the measurement noisier. It compresses
         * the chroma of EVERYTHING toward neutral, so the background converges
         * on the target as fast as the target does. The separation between
         * hand and wall shrinks, and a wider window captures the wall.
         *
         * You cannot rescue dim-light colour tracking by being more
         * forgiving, because forgiveness is symmetric.
         *
         * 0.25 is therefore a modest allowance for genuine sensor noise, not a
         * fix for darkness. The actual answers when it gets dark are the two
         * honest ones: [quality] says so, and MotionMask does not care about
         * light level at all.
         */
        private const val DARK_WIDENING = 0.25f
    }
}

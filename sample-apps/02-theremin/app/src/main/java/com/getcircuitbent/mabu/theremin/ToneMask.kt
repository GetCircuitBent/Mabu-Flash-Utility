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
 *  - LUMINANCE-ADAPTIVE TOLERANCE. The match window widens as brightness
 *    falls, because dim is exactly where the chroma estimate degrades. A
 *    fixed tolerance would quietly reintroduce the bias through the back
 *    door: same window, worse data, more misses, and the misses would not be
 *    evenly distributed.
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
        // Widen the window when the calibration sample was dark, because that
        // is where the chroma estimate is least reliable. Read the class
        // comment before changing this: a FIXED tolerance here is how the
        // skin-tone bias gets back in.
        val darkness = ((128 - targetY).coerceAtLeast(0)) / 128f   // 0 bright, 1 very dark
        val tol = (tolerance * (1f + darkness * 1.5f)).toInt().coerceIn(4, 48)

        for (my in 0 until mh) {
            val rowBase = my * mw
            val py = my * step
            for (mx in 0 until mw) {
                val c = HandTracking.chroma(nv21, width, height, mx * step, py)
                val cb = (c shr 8) and 0xFF
                val cr = c and 0xFF
                out[rowBase + mx] =
                    if (abs(cb - targetCb) < tol && abs(cr - targetCr) < tol) 1 else 0
            }
        }
    }

    override fun calibrationSummary(): String =
        if (!calibrated) "uncalibrated - tap Calibrate, or use Motion"
        else "Cb $targetCb / Cr $targetCr +/-$tolerance from $source"

    override fun reset() {
        calibrated = false
        source = "uncalibrated"
    }

    companion object {
        private const val TAG = "MabuTone"
    }
}

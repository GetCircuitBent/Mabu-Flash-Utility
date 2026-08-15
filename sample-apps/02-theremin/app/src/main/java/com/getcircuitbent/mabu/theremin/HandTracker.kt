package com.getcircuitbent.mabu.theremin

/**
 * ============================================================================
 * INDEX ROW 26 - tracking hands on hardware that has no hand tracker.
 * ============================================================================
 *
 * Read this file before the two implementations. It is the shape of the
 * solution; they are just details.
 *
 * ---------------------------------------------------------------------------
 * WHY THERE IS NO REAL HAND TRACKING HERE
 * ---------------------------------------------------------------------------
 * You would reach for MediaPipe Hands. It is not available: modern MediaPipe
 * Tasks Vision AARs dropped armeabi-v7a around 0.10.x, and the RK3288 is
 * armv7 only.
 *
 * ML Kit has no hand API at all. Its only body option is Pose Detection, which
 * does return wrists among its 33 landmarks. The frame budget rules it out:
 *
 *     camera delivers a frame every ....... 100 ms   (10 fps, hard ceiling)
 *     face detection costs ................  35 ms   (measured)
 *     left for hands ......................  65 ms
 *     ML Kit Pose on a Cortex-A17 ......... 100-200 ms (estimated)
 *
 * Pose alone would blow the budget, and it would have to share it with face
 * detection because this app wants both. It would also put control latency
 * past 200 ms, which is fine for a robot head and unplayable for an
 * instrument.
 *
 * ---------------------------------------------------------------------------
 * WHAT A THEREMIN ACTUALLY NEEDS
 * ---------------------------------------------------------------------------
 * Two numbers. Where is your left hand, where is your right hand. Not
 * twenty-one landmarks per hand, not finger poses, not gestures.
 *
 * That is a blob-finding problem, and blob finding is cheap. So the question
 * stops being "how do we run a hand model" and becomes "what makes a pixel
 * interesting".
 *
 * ---------------------------------------------------------------------------
 * THE STRUCTURE: ONE INTERFACE, TWO ANSWERS
 * ---------------------------------------------------------------------------
 * There are two good answers to "what makes a pixel interesting", with
 * opposite strengths, so the app ships both:
 *
 *     MotionMask - did this pixel's brightness change? (needs a static camera)
 *     ToneMask   - does this pixel's colour match a calibrated target?
 *
 * They differ in EXACTLY ONE FUNCTION: [buildMask]. Everything downstream -
 * excluding the face, growing blobs, filtering by size, matching blobs to the
 * previous frame, smoothing, deciding which is left and which is right - is
 * shared in [BlobExtractor] and never learns which mask it was handed.
 *
 * Switching technique at runtime is one field assignment.
 *
 * That is the real lesson of this file, and it generalises far past this
 * robot: a tracker is an INTERFACE, and the technique is an implementation
 * detail you should be free to change your mind about. Most computer-vision
 * sample code fuses the two, which is why it is so hard to experiment with.
 *
 * ---------------------------------------------------------------------------
 * WHY MOTION IS EVEN POSSIBLE HERE
 * ---------------------------------------------------------------------------
 * Because Mabu's camera is in the CHEST TABLET and is STATIC. It does not move
 * when the head turns, and no part of the robot is in its field of view.
 *
 * That one hardware fact is what makes MotionMask work. With a head-mounted
 * camera, the head turning would make the whole scene "move" and frame
 * differencing would light up everywhere. Any vision technique that assumes a
 * fixed background lives or dies on this detail, so check it before you copy
 * this code onto a different machine.
 */
interface HandTracker {

    /** Shown in the UI and the perf line. */
    val name: String

    /**
     * Mark interesting pixels in [out].
     *
     * Called on the camera thread, once per frame, with the raw NV21 buffer.
     * Implementations write 1 for interesting and 0 for not, over a grid
     * subsampled by [HandTracking.STEP].
     *
     * @param nv21 raw camera frame: [width]*[height] luma, then interleaved VU
     * @param out  mask, [HandTracking.maskW] * [HandTracking.maskH] bytes
     */
    fun buildMask(nv21: ByteArray, width: Int, height: Int, out: ByteArray)

    /**
     * Take calibration from a region of the frame, if this tracker needs any.
     * Motion tracking ignores it; tone tracking is defined by it.
     *
     * @param box region in normalised [0,1] coordinates
     */
    fun calibrate(nv21: ByteArray, width: Int, height: Int, box: FloatArray) {}

    /** One line for the UI, e.g. the current match window. Empty if n/a. */
    fun calibrationSummary(): String = ""

    /**
     * How well the last frame matched, and what to do about it.
     *
     * This exists because of something we could not test our way out of. The
     * tone tracker's behaviour depends on the player's own colouring and
     * lighting, and validating it properly needs a range of people in front of
     * the camera - which is not always available. A tracker that reports its
     * own confidence turns "we hope this works for you" into "it tells you
     * when it does not, and points at the fallback", which is the honest
     * posture when you cannot verify something for every user.
     *
     * Shown live on the main screen. Keep it short.
     */
    fun quality(): Quality = Quality.unknown()

    /** Drop any accumulated state, e.g. the background model. */
    fun reset() {}
}

/**
 * A tracker's own assessment of the frame it just processed.
 *
 * @param matchedFrac fraction of sampled pixels the tracker called interesting
 * @param margin      0..1, how far inside its acceptance threshold the matched
 *                    pixels sat. 1 is dead centre, 0 is scraping the edge.
 * @param meanY       mean luminance of the matched pixels, 0..255. The number
 *                    that matters most: low luminance is where chroma gets
 *                    noisy and where a colour tracker starts to fail.
 * @param verdict     short human-readable state
 * @param advice      what to do about it, or empty when nothing is wrong
 */
data class Quality(
    val matchedFrac: Float,
    val margin: Float,
    val meanY: Int,
    val verdict: String,
    val advice: String = "",
) {
    fun summary(): String = buildString {
        append(verdict)
        if (matchedFrac > 0f) {
            append(" · %.1f%% of frame".format(matchedFrac * 100))
            append(" · margin %.2f".format(margin))
            append(" · Y %d".format(meanY))
        }
        if (advice.isNotEmpty()) append(" · ").append(advice)
    }

    companion object {
        fun unknown() = Quality(0f, 0f, 0, "")
    }
}

/**
 * Shared constants and helpers for the vision layer.
 *
 * Everything works on a SUBSAMPLED grid. At 320x240 with STEP = 2 that is
 * 160x120 = 19,200 samples instead of 76,800, for a quarter of the work and
 * no meaningful loss - a hand is enormous at this resolution, and we only
 * want its centre.
 */
object HandTracking {

    /** Camera frame size. Smallest the HAL offers, which keeps ML Kit fast. */
    const val FRAME_W = 320
    const val FRAME_H = 240

    /** Subsampling factor for the mask grid. */
    const val STEP = 2

    const val maskW = FRAME_W / STEP
    const val maskH = FRAME_H / STEP

    /**
     * Luma of a pixel. The Y plane is the first FRAME_W*FRAME_H bytes of NV21,
     * one byte per pixel, unsigned.
     */
    fun luma(nv21: ByteArray, width: Int, x: Int, y: Int): Int =
        nv21[y * width + x].toInt() and 0xFF

    /**
     * Chroma of a pixel, as (Cb, Cr) packed into an int as (cb shl 8) or cr.
     *
     * NV21 stores chroma AFTER the luma plane, subsampled 2x2 and interleaved
     * as V,U pairs (note: V first - that catches people out). So one chroma
     * pair covers a 2x2 block of pixels, which is also why chroma is noisier
     * than luma and why low-light chroma is unreliable.
     */
    fun chroma(nv21: ByteArray, width: Int, height: Int, x: Int, y: Int): Int {
        val base = width * height
        val i = base + (y / 2) * width + (x / 2) * 2
        if (i + 1 >= nv21.size) return (128 shl 8) or 128
        val cr = nv21[i].toInt() and 0xFF       // V
        val cb = nv21[i + 1].toInt() and 0xFF   // U
        return (cb shl 8) or cr
    }
}

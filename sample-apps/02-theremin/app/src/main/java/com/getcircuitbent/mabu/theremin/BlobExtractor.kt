package com.getcircuitbent.mabu.theremin

import kotlin.math.abs

/**
 * ============================================================================
 * INDEX ROW 26 - everything that happens after the mask.
 * ============================================================================
 *
 * Mask of interesting pixels in, up to two hand positions out. This code never
 * learns whether the mask came from MotionMask or ToneMask, which is the whole
 * point of the interface: technique is swappable, plumbing is not duplicated.
 *
 * Steps, in order:
 *   1. Blank out the face, so the player's head is not a hand.
 *   2. Grow connected blobs from the mask.
 *   3. Throw away blobs too small to be a hand.
 *   4. Keep the largest two.
 *   5. Match them to last frame's hands so identities are stable.
 *   6. Smooth, because raw blob centroids jitter.
 *   7. Call the left-most one Left.
 */
class BlobExtractor {

    /** A tracked hand in normalised [0,1] frame coordinates. */
    data class Hand(
        val x: Float,
        val y: Float,
        /** Fraction of the frame this blob covers. Proxy for distance. */
        val area: Float,
    )

    /**
     * Minimum blob size, as a fraction of the mask, to count as a hand.
     *
     * Kills sensor noise, dust and the odd stray pixel. Too high and a hand at
     * arm's length is ignored. 0.4% of the frame is roughly 76 mask cells at
     * 160x120, a starting guess to be tuned on hardware.
     */
    @Volatile
    var minAreaFrac = 0.004f

    /**
     * Position smoothing, per frame. Same exponential filter as the motor
     * tween, for the same reason: the input is noisy and the output drives
     * something a human perceives.
     *
     * At 10 fps this is a compromise. Lower is smoother and laggier, and lag
     * on an instrument is felt immediately, so this is deliberately lighter
     * than the motor smoothing.
     */
    @Volatile
    var smoothing = 0.5f

    private var lastLeft: Hand? = null
    private var lastRight: Hand? = null

    /** Scratch buffers, reused. Allocating per frame would feed the GC at 10 Hz. */
    private val labels = IntArray(HandTracking.maskW * HandTracking.maskH)
    private val stack = IntArray(HandTracking.maskW * HandTracking.maskH)

    fun reset() {
        lastLeft = null
        lastRight = null
    }

    /**
     * @param mask     from a HandTracker, 1 = interesting
     * @param faceBox  normalised [x0,y0,x1,y1] to exclude, or null
     * @return Pair(left, right), either of which may be null
     */
    fun extract(mask: ByteArray, faceBox: FloatArray?): Pair<Hand?, Hand?> {
        val mw = HandTracking.maskW
        val mh = HandTracking.maskH

        // --- 1. Blank the face -------------------------------------------
        // Both trackers find the face: it moves (so MotionMask sees it) and
        // it is skin-coloured (so a face-calibrated ToneMask certainly does).
        // Padded outward because the ML Kit box is tight and hair, ears and
        // neck are all just as interesting to a blob finder.
        if (faceBox != null) {
            val padX = (faceBox[2] - faceBox[0]) * 0.35f
            val padY = (faceBox[3] - faceBox[1]) * 0.35f
            val fx0 = ((faceBox[0] - padX) * mw).toInt().coerceIn(0, mw)
            val fy0 = ((faceBox[1] - padY) * mh).toInt().coerceIn(0, mh)
            val fx1 = ((faceBox[2] + padX) * mw).toInt().coerceIn(0, mw)
            val fy1 = ((faceBox[3] + padY) * mh).toInt().coerceIn(0, mh)
            for (y in fy0 until fy1) {
                val base = y * mw
                for (x in fx0 until fx1) mask[base + x] = 0
            }
        }

        // --- 2 and 3. Connected blobs, big ones only ----------------------
        java.util.Arrays.fill(labels, 0)
        var best1Size = 0; var best1Sx = 0L; var best1Sy = 0L
        var best2Size = 0; var best2Sx = 0L; var best2Sy = 0L
        var label = 0
        val minCells = (minAreaFrac * mw * mh).toInt().coerceAtLeast(4)

        for (sy in 0 until mh) {
            for (sx in 0 until mw) {
                val start = sy * mw + sx
                if (mask[start].toInt() == 0 || labels[start] != 0) continue

                // Flood fill, iteratively. A recursive fill would blow the
                // stack on a blob that covers half the frame, which is
                // exactly what happens when the lights change.
                label++
                var sp = 0
                stack[sp++] = start
                labels[start] = label
                var size = 0
                var sumX = 0L
                var sumY = 0L

                while (sp > 0) {
                    val p = stack[--sp]
                    val px = p % mw
                    val py = p / mw
                    size++
                    sumX += px
                    sumY += py

                    // 4-connected. 8-connected joins blobs across diagonal
                    // gaps, which mostly means joining a hand to a forearm.
                    if (px > 0) sp = push(mask, p - 1, label, sp)
                    if (px < mw - 1) sp = push(mask, p + 1, label, sp)
                    if (py > 0) sp = push(mask, p - mw, label, sp)
                    if (py < mh - 1) sp = push(mask, p + mw, label, sp)
                }

                if (size < minCells) continue

                // --- 4. Keep the largest two ------------------------------
                if (size > best1Size) {
                    best2Size = best1Size; best2Sx = best1Sx; best2Sy = best1Sy
                    best1Size = size; best1Sx = sumX; best1Sy = sumY
                } else if (size > best2Size) {
                    best2Size = size; best2Sx = sumX; best2Sy = sumY
                }
            }
        }

        val total = (mw * mh).toFloat()
        val a = if (best1Size > 0) {
            Hand(best1Sx.toFloat() / best1Size / mw, best1Sy.toFloat() / best1Size / mh, best1Size / total)
        } else null
        val b = if (best2Size > 0) {
            Hand(best2Sx.toFloat() / best2Size / mw, best2Sy.toFloat() / best2Size / mh, best2Size / total)
        } else null

        // --- 7. Left is the one further left ------------------------------
        // Crude, and the honest limitation of the whole approach: cross your
        // hands and they swap. Real identity would need appearance matching or
        // an actual hand model, and we established we cannot have one.
        var left = a
        var right = b
        if (a != null && b != null && a.x > b.x) {
            left = b
            right = a
        } else if (a != null && b == null) {
            // Only one hand visible. Assign it to whichever side it was
            // nearest last frame, so a single hand does not flip identity
            // every time the other one drops out.
            val nearLeft = lastLeft?.let { abs(it.x - a.x) } ?: Float.MAX_VALUE
            val nearRight = lastRight?.let { abs(it.x - a.x) } ?: Float.MAX_VALUE
            if (nearRight < nearLeft) { left = null; right = a }
        }

        // --- 6. Smooth ----------------------------------------------------
        left = smooth(left, lastLeft)
        right = smooth(right, lastRight)
        lastLeft = left
        lastRight = right
        return Pair(left, right)
    }

    /** Push a neighbour onto the fill stack if it is unvisited and set. */
    private fun push(mask: ByteArray, p: Int, label: Int, sp: Int): Int {
        if (mask[p].toInt() == 0 || labels[p] != 0) return sp
        labels[p] = label
        stack[sp] = p
        return sp + 1
    }

    private fun smooth(now: Hand?, prev: Hand?): Hand? {
        if (now == null) return null
        if (prev == null) return now
        val a = smoothing.coerceIn(0.05f, 1f)
        return Hand(
            prev.x + (now.x - prev.x) * a,
            prev.y + (now.y - prev.y) * a,
            prev.area + (now.area - prev.area) * a,
        )
    }
}

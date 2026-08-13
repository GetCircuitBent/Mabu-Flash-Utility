package com.getcircuitbent.mabu.theremin

import android.os.SystemClock
import android.util.Log
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions

/**
 * ============================================================================
 * INDEX ROW 13 - finding the player's face.
 * ============================================================================
 *
 * ---------------------------------------------------------------------------
 * WHY ML KIT, PINNED, BUNDLED
 * ---------------------------------------------------------------------------
 * A liberated Mabu has NO Google Play Services. Esper stripped them, and they
 * are not coming back. So anything that depends on GMS at runtime is out,
 * which rules out most of the vision ecosystem.
 *
 * ML Kit's BUNDLED face detector is the exception: the model ships inside the
 * APK and runs locally with nothing installed. It is also one of the very few
 * current vision libraries that still ships `armeabi-v7a`, which the RK3288
 * needs.
 *
 * The dependency is PINNED at 16.1.7 in build.gradle.kts, deliberately. A
 * future release dropping armv7 is exactly how this app would break, and it
 * would break at runtime on the robot rather than at build time on your
 * laptop. MediaPipe has already done this once - it is why there is no hand
 * tracking in this app. Do not float the version.
 *
 * ---------------------------------------------------------------------------
 * SETTINGS, AND WHY EACH ONE IS CHEAP
 * ---------------------------------------------------------------------------
 * Everything here is chosen to keep inference near 35 ms, because the frame
 * budget is 100 ms and the hand tracker and the audio thread both want a
 * share.
 *
 *   PERFORMANCE_MODE_FAST   - ACCURATE roughly triples the cost, which would
 *                             exceed the whole frame budget by itself.
 *   no landmarks            - we need a box, not eyes and a nose.
 *   no classification       - smile and eye-open probabilities cost real time
 *                             and this app has no use for them. (App 3 might.)
 *   no contours             - by far the most expensive option available.
 *   minFaceSize 0.15        - the fraction of the frame a face must fill.
 *                             Larger is faster. A player stands close enough.
 *   enableTracking          - cheap, and gives temporal stability across
 *                             frames, so the box stops jittering when you
 *                             hold still.
 */
class FaceDetector {

    private val detector = FaceDetection.getClient(
        FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
            .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_NONE)
            .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_NONE)
            .setContourMode(FaceDetectorOptions.CONTOUR_MODE_NONE)
            .setMinFaceSize(0.15f)
            .enableTracking()
            .build(),
    )

    /** Rolling inference time in ms, for the perf line. */
    @Volatile var inferenceMs = 0f; private set

    /**
     * Most recent face box in normalised [0,1] coordinates as
     * [x0, y0, x1, y1, fromFace], or null if no face.
     *
     * The fifth element is a flag consumed by ToneMask.calibrate so it can
     * label where its calibration came from. Slightly ugly, and much cheaper
     * than another allocation per frame.
     */
    @Volatile var faceBox: FloatArray? = null; private set

    @Volatile private var inFlight = false

    /**
     * Kick off detection for a frame.
     *
     * ML Kit is asynchronous, so this returns immediately and [faceBox]
     * updates whenever the result lands - usually one frame later. That is
     * fine: a face does not move far in 100 ms, and the alternative (blocking
     * the camera thread) would cost us the frame entirely.
     *
     * If a detection is still in flight the frame is skipped rather than
     * queued, for the same reason the camera drops frames when busy.
     */
    fun submit(nv21: ByteArray, width: Int, height: Int) {
        if (inFlight) return
        inFlight = true
        val started = SystemClock.uptimeMillis()

        val image = InputImage.fromByteArray(
            nv21, width, height, 0, InputImage.IMAGE_FORMAT_NV21,
        )

        detector.process(image)
            .addOnSuccessListener { faces -> onFaces(faces, width, height, started) }
            .addOnFailureListener { e ->
                Log.w(TAG, "detection failed", e)
                inFlight = false
            }
    }

    private fun onFaces(faces: List<Face>, width: Int, height: Int, startedMs: Long) {
        val took = (SystemClock.uptimeMillis() - startedMs).toFloat()
        inferenceMs = inferenceMs * 0.8f + took * 0.2f

        // Largest face wins. The player is the person standing closest to the
        // instrument, and this app does not need the elaborate multi-face
        // arbitration a dedicated tracking app would want.
        val best = faces.maxByOrNull { it.boundingBox.width() * it.boundingBox.height() }
        faceBox = if (best == null) {
            null
        } else {
            val b = best.boundingBox
            floatArrayOf(
                (b.left.toFloat() / width).coerceIn(0f, 1f),
                (b.top.toFloat() / height).coerceIn(0f, 1f),
                (b.right.toFloat() / width).coerceIn(0f, 1f),
                (b.bottom.toFloat() / height).coerceIn(0f, 1f),
                1f,
            )
        }
        inFlight = false
    }

    fun close() {
        try {
            detector.close()
        } catch (_: Throwable) {
        }
    }

    companion object {
        private const val TAG = "MabuFace"
    }
}

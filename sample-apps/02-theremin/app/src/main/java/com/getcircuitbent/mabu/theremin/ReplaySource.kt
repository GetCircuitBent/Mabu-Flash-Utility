package com.getcircuitbent.mabu.theremin

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * ============================================================================
 * The test harness: run the tracker on files instead of the camera.
 * ============================================================================
 *
 * Reads frames from /sdcard/theremin/testframes/ and pushes them through the
 * exact same pipeline the camera feeds, at the same 10 fps. The trackers, the
 * blob extractor and the audio mapping cannot tell the difference.
 *
 * ---------------------------------------------------------------------------
 * WHY THIS EXISTS
 * ---------------------------------------------------------------------------
 * Two reasons, and the second is the important one.
 *
 * 1. TUNING BECOMES REPEATABLE. Adjusting a threshold against a live camera
 *    means changing two things at once - the setting and whatever you happened
 *    to be doing with your hands. Replaying identical frames means the only
 *    variable is the setting, so you can actually tell whether a change helped.
 *
 * 2. IT DECOUPLES TESTING FROM WHO IS IN THE ROOM. The tone tracker's weak
 *    spot is that its behaviour depends on the colouring and lighting of the
 *    person in front of it, and verifying that properly needs a range of
 *    people - which is not something you can summon on a Tuesday afternoon.
 *
 *    With this, thirty seconds of captured frames from anyone who does walk
 *    past becomes a permanent regression test. Capture at a demo, a workshop,
 *    a booth; replay forever after. The test corpus grows instead of the
 *    testing being repeated.
 *
 * Use [FrameStore.capture] (the CAPTURE button) to build that corpus from the
 * device itself, and scripts/tone-sweep.py on your PC to synthesise darker and
 * dimmer variants of a capture you already have.
 *
 * ---------------------------------------------------------------------------
 * FORMATS
 * ---------------------------------------------------------------------------
 * .nv21  Raw camera bytes, exactly as the HAL produced them. PREFERRED: no
 *        decode, no colour conversion, no compression, so what the tracker
 *        sees is bit-identical to what it saw live. This is what CAPTURE
 *        writes and what the tone-sweep script transforms.
 *
 * .png / .jpg  Convenient, and lossy in ways that matter here. Any image gets
 *        scaled to 320x240 and converted to NV21, which means resampled chroma
 *        and, for JPEG, compression artifacts in exactly the channel the tone
 *        tracker reads. Fine for a quick look, not for judging a tolerance.
 */
class ReplaySource(
    private val onFrame: (nv21: ByteArray, width: Int, height: Int) -> Unit,
) {

    private var thread: HandlerThread? = null
    private var handler: Handler? = null

    @Volatile private var running = false
    @Volatile private var frames: List<File> = emptyList()
    @Volatile private var index = 0

    /** Name of the frame currently being replayed, for the UI. */
    @Volatile var currentName: String = ""
        private set

    /** Decoded copy of the current frame, so the UI can show what is being tested. */
    @Volatile var currentBitmap: Bitmap? = null
        private set

    val frameCount: Int get() = frames.size

    /**
     * Load the corpus and start replaying at 10 fps, matching the camera.
     *
     * @return an error message, or null on success.
     */
    fun start(): String? {
        if (running) return null

        val dir = File(FrameStore.DIR)
        val found = dir.listFiles { f ->
            f.isFile && f.name.lowercase().let {
                it.endsWith(".nv21") || it.endsWith(".png") ||
                    it.endsWith(".jpg") || it.endsWith(".jpeg")
            }
        }?.sortedBy { it.name } ?: emptyList()

        if (found.isEmpty()) {
            return "No frames in ${FrameStore.DIR}\nUse CAPTURE, or adb push some"
        }

        frames = found
        index = 0
        running = true

        val t = HandlerThread("mabu-replay").apply { start() }
        thread = t
        handler = Handler(t.looper)
        handler?.post(tick)
        Log.i(TAG, "replaying ${found.size} frames from ${FrameStore.DIR}")
        return null
    }

    fun stop() {
        running = false
        handler?.removeCallbacksAndMessages(null)
        thread?.quitSafely()
        thread = null
        handler = null
        currentBitmap = null
        currentName = ""
    }

    private val tick = object : Runnable {
        override fun run() {
            if (!running) return
            val list = frames
            if (list.isNotEmpty()) {
                val file = list[index % list.size]
                index++
                try {
                    val nv21 = readFrame(file)
                    if (nv21 != null) {
                        currentName = "${file.name} (${index % list.size + 1}/${list.size})"
                        currentBitmap = nv21ToBitmap(nv21)
                        onFrame(nv21, HandTracking.FRAME_W, HandTracking.FRAME_H)
                    }
                } catch (t: Throwable) {
                    Log.e(TAG, "failed on ${file.name}", t)
                }
            }
            // Same cadence as the camera, so timing-dependent behaviour - the
            // background model's adapt rate above all - behaves as it would
            // live. Replaying faster would make MotionMask forget faster.
            handler?.postDelayed(this, 100)
        }
    }

    /** Load a frame, converting if it is an ordinary image. */
    private fun readFrame(file: File): ByteArray? {
        if (file.name.lowercase().endsWith(".nv21")) {
            val expected = HandTracking.FRAME_W * HandTracking.FRAME_H * 3 / 2
            val bytes = file.readBytes()
            if (bytes.size < expected) {
                Log.w(TAG, "${file.name} is ${bytes.size} bytes, expected $expected")
                return null
            }
            return bytes
        }
        val bm = BitmapFactory.decodeFile(file.absolutePath) ?: return null
        val scaled = Bitmap.createScaledBitmap(
            bm, HandTracking.FRAME_W, HandTracking.FRAME_H, true,
        )
        val out = bitmapToNv21(scaled)
        if (scaled !== bm) scaled.recycle()
        bm.recycle()
        return out
    }

    companion object {
        private const val TAG = "MabuReplay"

        /**
         * RGB to NV21.
         *
         * Worth reading once even if you never call it, because it is the
         * clearest statement of what NV21 actually is: a full-resolution plane
         * of brightness, then a half-resolution plane of colour with the two
         * chroma components interleaved V first.
         *
         * The coefficients are the BT.601 conversion, which is what phone
         * camera pipelines use.
         */
        fun bitmapToNv21(bm: Bitmap): ByteArray {
            val w = bm.width
            val h = bm.height
            val argb = IntArray(w * h)
            bm.getPixels(argb, 0, w, 0, 0, w, h)

            val out = ByteArray(w * h * 3 / 2)
            var uvPos = w * h

            for (y in 0 until h) {
                for (x in 0 until w) {
                    val c = argb[y * w + x]
                    val r = (c shr 16) and 0xFF
                    val g = (c shr 8) and 0xFF
                    val b = c and 0xFF

                    val yy = ((66 * r + 129 * g + 25 * b + 128) shr 8) + 16
                    out[y * w + x] = yy.coerceIn(0, 255).toByte()

                    // Chroma is stored for every SECOND pixel of every SECOND
                    // row: one pair covers a 2x2 block. That subsampling is
                    // why chroma is noisier than luma, which is the whole
                    // reason the tone tracker struggles in dim light.
                    if (y % 2 == 0 && x % 2 == 0) {
                        val u = ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
                        val v = ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
                        out[uvPos++] = v.coerceIn(0, 255).toByte()   // V first
                        out[uvPos++] = u.coerceIn(0, 255).toByte()
                    }
                }
            }
            return out
        }

        /**
         * NV21 to Bitmap, for showing the frame under test.
         *
         * Goes via JPEG because YuvImage will do it in three lines and this is
         * a debug view at 10 fps, where a little extra work and a little extra
         * loss cost nothing. Do NOT copy this into a hot path.
         */
        fun nv21ToBitmap(nv21: ByteArray): Bitmap? = try {
            val yuv = YuvImage(
                nv21, ImageFormat.NV21, HandTracking.FRAME_W, HandTracking.FRAME_H, null,
            )
            val bos = ByteArrayOutputStream()
            yuv.compressToJpeg(Rect(0, 0, HandTracking.FRAME_W, HandTracking.FRAME_H), 88, bos)
            val bytes = bos.toByteArray()
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        } catch (t: Throwable) {
            Log.w(TAG, "nv21ToBitmap failed", t)
            null
        }
    }
}

/**
 * Writes camera frames to disk so the replay corpus can be built on the device.
 *
 * This is what turns "we should test with more people" into something you can
 * actually act on when somebody happens to be standing there: press CAPTURE,
 * get a file, pull it, keep it forever.
 */
object FrameStore {

    const val DIR = "/sdcard/theremin/testframes"

    private const val TAG = "MabuReplay"

    /**
     * Save a raw NV21 frame.
     *
     * Raw, not PNG, deliberately: the point of a captured frame is to be
     * exactly what the camera produced, including its noise and its chroma
     * subsampling. Encoding it would smooth over the very artifacts that make
     * dim-light tracking hard.
     *
     * @param note short tag that ends up in the filename, e.g. a lighting
     *        condition. Sanitised, since it comes from a text field.
     * @return the file written, or null.
     */
    fun capture(nv21: ByteArray, note: String = "cap"): File? = try {
        val dir = File(DIR)
        if (!dir.exists()) dir.mkdirs()
        val safe = note.replace(Regex("[^A-Za-z0-9_-]"), "").take(24).ifEmpty { "cap" }
        // Sequence number rather than a timestamp so replay order is capture
        // order, which matters for MotionMask: its background model expects a
        // coherent sequence, not a shuffled pile.
        val n = (dir.listFiles()?.size ?: 0) + 1
        val f = File(dir, "%s-%03d.nv21".format(safe, n))
        f.writeBytes(nv21)
        Log.i(TAG, "captured ${f.absolutePath} (${nv21.size} bytes)")
        f
    } catch (t: Throwable) {
        Log.e(TAG, "capture failed", t)
        null
    }
}

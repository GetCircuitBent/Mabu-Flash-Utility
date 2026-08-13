package com.getcircuitbent.mabu.signboard

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Movie
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.os.SystemClock
import android.util.Log
import android.view.View
import java.io.File

/**
 * ============================================================================
 * INDEX ROW 24 - full-screen media on the Mabu panel.
 * ============================================================================
 *
 * Draws a still image or a looping animated GIF, scaled to the screen, with
 * an adjustable playback rate.
 *
 * ---------------------------------------------------------------------------
 * WHAT THE PANEL IS
 * ---------------------------------------------------------------------------
 *   Resolution   1024 x 600, landscape
 *   Refresh      30 Hz
 *   Density      180 dpi
 *
 * Author your sign at 1024x600 to fill it exactly. Anything else gets scaled
 * by [fitMode]. There is no benefit to supplying a larger image: it costs
 * memory and gets scaled down anyway. There IS a cost to supplying a much
 * smaller one, because upscaling on this GPU is soft.
 *
 * ---------------------------------------------------------------------------
 * WHAT IT CAN PLAY
 * ---------------------------------------------------------------------------
 *   PNG, JPEG, WebP    still images, via BitmapFactory
 *   GIF (animated)     via android.graphics.Movie, looping, rate-adjustable
 *
 * Video is deliberately NOT supported here; it is tracked as row 25 of the
 * function index for a later sample. It needs a MediaPlayer and a surface,
 * codec support that has not been verified on this SoC beyond H.264, and a
 * playback-rate API that embedded decoders frequently ignore. That is a
 * sample of its own, not a footnote in this one.
 *
 * ---------------------------------------------------------------------------
 * WHY android.graphics.Movie, WHICH IS DEPRECATED
 * ---------------------------------------------------------------------------
 * The modern GIF decoder is AnimatedImageDrawable, added in API 28. The Mabu
 * is API 27. It is exactly one version too old, which is a very Mabu problem
 * to have.
 *
 * The alternatives are a third-party library (Glide et al) or Movie, which is
 * deprecated-but-present and works fine here. Movie wins for a sample: no
 * dependency, about thirty lines, and it hands you something the modern API
 * does not.
 *
 * That something is the clock. Movie does NOT animate itself. You tell it
 * which frame to show, by time offset, every time you draw. Which means
 * playback rate is not a feature anyone had to implement - it falls out of
 * the arithmetic you were already doing:
 *
 *     gifTime = elapsedRealTime * rate
 *     movie.setTime(gifTime % movie.duration())
 *
 * Rate 0.5 is half speed, 2.0 is double, 0.0 freezes on a frame, and the
 * modulo is the loop. This is the same "own your own clock" idea as the motor
 * tween, and it is worth internalising: things that animate themselves are
 * convenient right up to the moment you need to control them.
 *
 * ---------------------------------------------------------------------------
 * THE BLACK RECTANGLE
 * ---------------------------------------------------------------------------
 * If a GIF renders as a black box, the view needs a software layer. Movie.draw
 * does not reliably survive a hardware-accelerated canvas. That is done in
 * [setMedia] and it is the first thing to check if you see this.
 */
class SignView(context: Context) : View(context) {

    enum class FitMode {
        /** Whole image visible, letterboxed. Nothing is cropped. */
        CONTAIN,

        /** Fills the screen, edges cropped. Nothing is letterboxed. */
        COVER,
    }

    var fitMode: FitMode = FitMode.CONTAIN
        set(value) {
            field = value
            invalidate()
        }

    /**
     * GIF playback rate. 1.0 is as authored. Clamped to a sane range because
     * 0 is a legitimate value (freeze) but negative is not meaningful with a
     * modulo-based clock.
     */
    var rate: Float = 1.0f
        set(value) {
            field = value.coerceIn(0f, 4f)
        }

    /** Human-readable description of what is loaded, for the admin screen. */
    var mediaLabel: String = "(none)"
        private set

    private var bitmap: Bitmap? = null
    private var movie: Movie? = null
    private var movieStartMs = 0L

    private val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private val srcRect = Rect()
    private val dstRect = RectF()

    init {
        setBackgroundColor(Color.BLACK)
    }

    // -----------------------------------------------------------------------
    // LOADING
    // -----------------------------------------------------------------------

    /**
     * Load the bundled default sign from assets.
     *
     * @param animated true for the looping GIF, false for the still.
     *
     * Both defaults are the Get Circuit Bent brand mark. They are 700x438,
     * which is deliberately NOT the panel's 1024x600 - it means you can see
     * what CONTAIN and COVER actually do without having to go and make a test
     * image first.
     */
    fun setBundledMedia(animated: Boolean) {
        val name = if (animated) ASSET_ANIMATED else ASSET_STILL
        try {
            context.assets.open(name).use { stream ->
                val bytes = stream.readBytes()
                if (animated) {
                    applyMovie(Movie.decodeByteArray(bytes, 0, bytes.size), name)
                } else {
                    applyBitmap(BitmapFactory.decodeByteArray(bytes, 0, bytes.size), name)
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "failed to load bundled asset $name", t)
            mediaLabel = "failed: $name"
        }
        invalidate()
    }

    /**
     * Load a sign from the filesystem, typically /sdcard/signboard/.
     *
     * The file extension decides the decoder, which is crude but predictable:
     * name it .gif and it animates, name it anything else and it is a still.
     *
     * Reading from /sdcard needs READ_EXTERNAL_STORAGE. Because the app
     * targets SDK 28 this is plain File access with no scoped-storage
     * ceremony, so `adb push whatever.png /sdcard/signboard/` just works.
     *
     * @return null on success, or a message to show the operator.
     */
    fun setMediaFromFile(path: String): String? {
        val file = File(path)
        if (!file.isFile) return "not found: $path"
        if (!file.canRead()) {
            return "cannot read $path - granted READ_EXTERNAL_STORAGE?"
        }

        return try {
            val bytes = file.readBytes()
            if (path.lowercase().endsWith(".gif")) {
                val m = Movie.decodeByteArray(bytes, 0, bytes.size)
                    ?: return "not a decodable GIF: $path"
                applyMovie(m, file.name)
            } else {
                val bm = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                    ?: return "not a decodable image: $path"
                applyBitmap(bm, file.name)
            }
            invalidate()
            null
        } catch (t: OutOfMemoryError) {
            // 2 GB of RAM and a 32-bit address space that fragments. A huge
            // image really can do this, and it is a much better experience to
            // say so than to die.
            "out of memory decoding $path - try a smaller image"
        } catch (t: Throwable) {
            "failed to load $path: ${t.message}"
        }
    }

    private fun applyBitmap(bm: Bitmap?, label: String) {
        movie = null
        bitmap = bm
        mediaLabel = if (bm != null) "$label (${bm.width}x${bm.height})" else "failed: $label"
        // A still does not need the software layer, and hardware acceleration
        // is faster for plain bitmap blits, so put it back.
        setLayerType(LAYER_TYPE_HARDWARE, null)
    }

    private fun applyMovie(m: Movie?, label: String) {
        bitmap = null
        movie = m
        movieStartMs = SystemClock.uptimeMillis()
        mediaLabel = if (m != null) "$label (${m.width()}x${m.height()}, ${m.duration()} ms)"
        else "failed: $label"

        // *** The black-rectangle fix. *** Movie.draw is not reliable on a
        // hardware-accelerated canvas. Costs nothing at this size.
        setLayerType(LAYER_TYPE_SOFTWARE, null)
    }

    // -----------------------------------------------------------------------
    // DRAWING
    // -----------------------------------------------------------------------

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val vw = width.toFloat()
        val vh = height.toFloat()
        if (vw <= 0f || vh <= 0f) return

        val m = movie
        val bm = bitmap

        if (m != null && m.duration() > 0) {
            // ---- The whole GIF engine, and the rate control with it. ----
            val elapsed = SystemClock.uptimeMillis() - movieStartMs
            val gifTime = (elapsed * rate).toLong()
            m.setTime((gifTime % m.duration()).toInt())

            // Movie draws at its native size from a given origin, so scaling
            // means transforming the canvas around it rather than passing a
            // destination rectangle the way drawBitmap does.
            fitInto(m.width().toFloat(), m.height().toFloat(), vw, vh)
            val scale = dstRect.width() / m.width()

            canvas.save()
            canvas.translate(dstRect.left, dstRect.top)
            canvas.scale(scale, scale)
            m.draw(canvas, 0f, 0f)
            canvas.restore()

            // Ask for the next frame. Nothing else drives this - a Movie only
            // advances when something redraws it.
            postInvalidateOnAnimation()
        } else if (bm != null) {
            fitInto(bm.width.toFloat(), bm.height.toFloat(), vw, vh)
            srcRect.set(0, 0, bm.width, bm.height)
            canvas.drawBitmap(bm, srcRect, dstRect, paint)
        }
    }

    /**
     * Work out where to draw a [srcW] x [srcH] image inside a [dstW] x [dstH]
     * view, honouring [fitMode]. Result lands in [dstRect].
     *
     * CONTAIN takes the smaller scale so everything fits (letterboxing);
     * COVER takes the larger so nothing is letterboxed (cropping). Either way
     * the result is centred, and the aspect ratio is never distorted -
     * stretching a logo to fit is the one thing nobody ever wants.
     */
    private fun fitInto(srcW: Float, srcH: Float, dstW: Float, dstH: Float) {
        if (srcW <= 0f || srcH <= 0f) return
        val sx = dstW / srcW
        val sy = dstH / srcH
        val s = if (fitMode == FitMode.CONTAIN) minOf(sx, sy) else maxOf(sx, sy)
        val w = srcW * s
        val h = srcH * s
        val left = (dstW - w) / 2f
        val top = (dstH - h) / 2f
        dstRect.set(left, top, left + w, top + h)
    }

    /** Restart the GIF from frame zero. */
    fun restart() {
        movieStartMs = SystemClock.uptimeMillis()
        invalidate()
    }

    fun release() {
        bitmap?.recycle()
        bitmap = null
        movie = null
    }

    companion object {
        private const val TAG = "MabuSign"

        const val ASSET_STILL = "gcb-sign.png"
        const val ASSET_ANIMATED = "gcb-sign-animated.gif"

        /** Where to drop your own signs. Created by the install script. */
        const val SDCARD_DIR = "/sdcard/signboard"
    }
}

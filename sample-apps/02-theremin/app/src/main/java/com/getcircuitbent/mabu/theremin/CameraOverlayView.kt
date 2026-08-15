package com.getcircuitbent.mabu.theremin

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.util.Log
import android.view.View

/**
 * ============================================================================
 * INDEX ROWS 13 AND 26 - what the tracker sees, drawn on top of the preview.
 * ============================================================================
 *
 * A transparent view sitting over the camera preview, drawing the face box,
 * the hand boxes, and the watermark.
 *
 * The overlay is not decoration. It is the ONLY way to debug a tracker: if a
 * hand box is on your elbow, or clamped to a bright window, or missing
 * entirely, you can see it instantly and no log line would have told you.
 * Build the overlay before you tune anything.
 *
 * ---------------------------------------------------------------------------
 * THE WATERMARK, AND HOW TO CHANGE IT
 * ---------------------------------------------------------------------------
 * This is the first thing anyone rebranding this app will want, so it is one
 * asset and three constants:
 *
 *   the image        app/src/main/assets/watermark.png  (just replace it)
 *   which corner     WATERMARK_CORNER
 *   how big          WATERMARK_WIDTH_FRAC, as a fraction of view width
 *   how visible      WATERMARK_ALPHA, 0..255
 *
 * It draws at native aspect ratio, so any reasonably sized PNG with
 * transparency works. Nothing else in the app refers to it.
 */
class CameraOverlayView(context: Context) : View(context) {

    /** Normalised [x0,y0,x1,y1] or null. */
    @Volatile var faceBox: FloatArray? = null

    @Volatile var leftHand: BlobExtractor.Hand? = null
    @Volatile var rightHand: BlobExtractor.Hand? = null

    /** Shown centred when the operator is about to calibrate ToneMask. */
    @Volatile var showCalibrationBox = false

    /**
     * The frame being replayed, drawn underneath everything else.
     *
     * Null in normal use, when the SurfaceView underneath is showing the live
     * camera. During replay the camera is stopped and that surface is blank,
     * so the overlay has to draw the frame itself or you would be tuning a
     * tracker against boxes floating on black.
     */
    @Volatile var backgroundFrame: Bitmap? = null

    private val facePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 3f
        color = Color.parseColor("#A5B0B7")   // Cadet Gray
    }
    private val handPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 4f
        color = Color.parseColor("#179E19")   // La Palma
    }
    private val calPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 3f
        color = Color.parseColor("#FF4F00")   // Signal Orange
    }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = 22f
    }
    private val watermarkPaint = Paint(Paint.FILTER_BITMAP_FLAG).apply {
        alpha = WATERMARK_ALPHA
    }
    private val framePaint = Paint(Paint.FILTER_BITMAP_FLAG)

    private var watermark: Bitmap? = null
    private val src = Rect()
    private val dst = RectF()

    init {
        setWillNotDraw(false)
        setBackgroundColor(Color.TRANSPARENT)
        watermark = try {
            context.assets.open(WATERMARK_ASSET).use { BitmapFactory.decodeStream(it) }
        } catch (t: Throwable) {
            Log.w(TAG, "no watermark asset ($WATERMARK_ASSET)", t)
            null
        }
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0f || h <= 0f) return

        // --- Replayed frame, if any ---------------------------------------
        backgroundFrame?.let { bm ->
            src.set(0, 0, bm.width, bm.height)
            dst.set(0f, 0f, w, h)
            canvas.drawBitmap(bm, src, dst, framePaint)
        }

        // --- Face ---------------------------------------------------------
        faceBox?.let { f ->
            canvas.drawRect(f[0] * w, f[1] * h, f[2] * w, f[3] * h, facePaint)
        }

        // --- Hands --------------------------------------------------------
        // The tracker gives a centroid and an area, not a box, so draw a
        // square whose size follows the blob. Watching that square grow as
        // your hand approaches is what makes "area approximates distance"
        // obvious, which matters if you switch the control axis to it.
        drawHand(canvas, leftHand, "L", w, h)
        drawHand(canvas, rightHand, "R", w, h)

        // --- Calibration target -------------------------------------------
        if (showCalibrationBox) {
            val bw = w * 0.22f
            val bh = h * 0.30f
            canvas.drawRect((w - bw) / 2, (h - bh) / 2, (w + bw) / 2, (h + bh) / 2, calPaint)
            canvas.drawText("hold hand or marker here", (w - bw) / 2, (h - bh) / 2 - 8f, labelPaint)
        }

        // --- Watermark ----------------------------------------------------
        watermark?.let { bm ->
            val targetW = w * WATERMARK_WIDTH_FRAC
            val targetH = targetW * bm.height / bm.width
            val m = w * WATERMARK_MARGIN_FRAC
            val left = if (WATERMARK_CORNER.endsWith("left")) m else w - targetW - m
            val top = if (WATERMARK_CORNER.startsWith("top")) m else h - targetH - m
            src.set(0, 0, bm.width, bm.height)
            dst.set(left, top, left + targetW, top + targetH)
            canvas.drawBitmap(bm, src, dst, watermarkPaint)
        }
    }

    private fun drawHand(canvas: Canvas, hand: BlobExtractor.Hand?, tag: String, w: Float, h: Float) {
        if (hand == null) return
        // area is a fraction of the frame; sqrt gives a side length.
        val side = (Math.sqrt(hand.area.toDouble()).toFloat() * w).coerceIn(24f, w * 0.6f)
        val cx = hand.x * w
        val cy = hand.y * h
        canvas.drawRect(cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2, handPaint)
        canvas.drawText(tag, cx - side / 2, cy - side / 2 - 6f, labelPaint)
    }

    companion object {
        private const val TAG = "MabuOverlay"

        // ---- Watermark configuration. Change these, or the PNG. ----------
        const val WATERMARK_ASSET = "watermark.png"

        /** "top-left", "top-right", "bottom-left" or "bottom-right". */
        const val WATERMARK_CORNER = "bottom-right"

        /** Width as a fraction of the view. 0.18 is present but not shouting. */
        const val WATERMARK_WIDTH_FRAC = 0.18f

        /** Gap from the edges, as a fraction of view width. */
        const val WATERMARK_MARGIN_FRAC = 0.02f

        /** 0 invisible, 255 opaque. */
        const val WATERMARK_ALPHA = 190
    }
}

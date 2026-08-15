package com.getcircuitbent.mabu.theremin

import android.graphics.ImageFormat
import android.hardware.Camera
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.os.SystemClock
import android.util.Log
import android.view.SurfaceHolder

/**
 * ============================================================================
 * INDEX ROW 12 - getting frames out of Mabu's camera.
 * ============================================================================
 *
 * ---------------------------------------------------------------------------
 * WHY THE DEPRECATED API
 * ---------------------------------------------------------------------------
 * `android.hardware.Camera` was deprecated in API 21. This app targets API 27
 * and uses it anyway, because on this device it is the only thing that works.
 *
 * The RK3288's camera HAL is a Camera1 shim. Camera2 enumeration returns
 * nothing usable, so CameraX - which is built on Camera2 - fails its camera
 * validation and never opens. There is no workaround and no newer library that
 * fixes it. Deprecated-and-working beats modern-and-absent.
 *
 * ---------------------------------------------------------------------------
 * THE 10 FPS CEILING, WHICH YOU CANNOT LIFT
 * ---------------------------------------------------------------------------
 * The camera advertises 24 fps in `getSupportedPreviewFpsRange` and accepts a
 * request for it. It then delivers 10, consistently, with about 15 ms of
 * jitter.
 *
 * This has been measured repeatedly. It is the hardware. No preview size, fps
 * range, buffer count or thread priority changes it. Budget accordingly: you
 * get one frame every 100 ms and everything you want to do to that frame has
 * to fit in the gap.
 *
 * The practical consequence for this app is that your hands are sampled at
 * 10 Hz while the audio runs at 44,100 Hz, which is why AudioEngine
 * interpolates rather than stepping. See the comments there.
 *
 * ---------------------------------------------------------------------------
 * FRAME FORMAT
 * ---------------------------------------------------------------------------
 * NV21 at 320x240. That is YCbCr 4:2:0: a full-resolution luma plane followed
 * by half-resolution interleaved V,U. Both trackers read it directly - see
 * HandTracking.luma and HandTracking.chroma - and ML Kit takes NV21 natively,
 * so nothing in this app ever converts a frame to RGB.
 *
 * 320x240 is the smallest size offered and is chosen deliberately: ML Kit's
 * inference cost scales with it, and a hand is still enormous at this size.
 */
class Camera1Source(
    private val onFrame: (nv21: ByteArray, width: Int, height: Int) -> Unit,
) {

    private var camera: Camera? = null
    private var thread: HandlerThread? = null
    private var handler: Handler? = null

    @Volatile private var busy = false

    // Perf counters, read by the UI.
    @Volatile var fps = 0f; private set
    @Volatile var droppedFrames = 0L; private set
    private var frameCount = 0
    private var windowStartMs = 0L

    /**
     * Open the camera and start delivering frames.
     *
     * @param holder a SurfaceHolder for the preview. Camera1 on this HAL will
     *        not start without a real surface, even if you never look at it.
     */
    fun start(holder: SurfaceHolder): Boolean {
        if (camera != null) return true

        val t = HandlerThread("mabu-camera", Process.THREAD_PRIORITY_BACKGROUND).apply { start() }
        thread = t
        handler = Handler(t.looper)

        return try {
            // Front camera if there is one; on a Mabu there is exactly one.
            val cam = Camera.open(frontCameraId())
            val p = cam.parameters
            p.previewFormat = ImageFormat.NV21
            p.setPreviewSize(HandTracking.FRAME_W, HandTracking.FRAME_H)

            // Ask for the highest advertised rate. We will get 10. Asking
            // costs nothing and documents the intent.
            p.supportedPreviewFpsRange.maxByOrNull { it[1] }?.let {
                p.setPreviewFpsRange(it[0], it[1])
            }
            cam.parameters = p

            // Preallocated callback buffers. Without these, Camera1 allocates
            // a fresh byte[] for every frame, and at 10 fps that is 750 KB a
            // second straight into the GC on a device with 2 GB of RAM.
            //
            // Four, not two: when a frame takes longer than usual, the extra
            // buffers absorb it instead of the HAL dropping the next frame.
            val size = HandTracking.FRAME_W * HandTracking.FRAME_H * 3 / 2
            repeat(4) { cam.addCallbackBuffer(ByteArray(size)) }

            cam.setPreviewDisplay(holder)
            cam.setPreviewCallbackWithBuffer { data, c ->
                onPreviewFrame(data, c)
            }
            cam.startPreview()
            camera = cam
            windowStartMs = SystemClock.uptimeMillis()
            Log.i(TAG, "camera started at ${HandTracking.FRAME_W}x${HandTracking.FRAME_H} NV21")
            true
        } catch (t2: Throwable) {
            Log.e(TAG, "camera open failed", t2)
            stop()
            false
        }
    }

    private fun onPreviewFrame(data: ByteArray?, cam: Camera) {
        if (data == null) return

        // Backpressure. If the previous frame is still being processed, drop
        // this one and hand the buffer straight back. Queueing instead would
        // build latency without ever catching up, and on an instrument that
        // is worse than a dropped frame.
        if (busy) {
            droppedFrames++
            cam.addCallbackBuffer(data)
            return
        }
        busy = true

        handler?.post {
            try {
                onFrame(data, HandTracking.FRAME_W, HandTracking.FRAME_H)
            } catch (t: Throwable) {
                Log.e(TAG, "frame handler threw", t)
            } finally {
                // ALWAYS return the buffer, even after an exception. Miss this
                // and the pool empties, the callbacks stop, and the preview
                // freezes with nothing in the log to say why.
                cam.addCallbackBuffer(data)
                busy = false
                countFrame()
            }
        }
    }

    private fun countFrame() {
        frameCount++
        val now = SystemClock.uptimeMillis()
        val elapsed = now - windowStartMs
        if (elapsed >= 2000) {
            fps = frameCount * 1000f / elapsed
            frameCount = 0
            windowStartMs = now
        }
    }

    fun stop() {
        camera?.let {
            try {
                it.setPreviewCallbackWithBuffer(null)
                it.stopPreview()
                it.release()
            } catch (_: Throwable) {
            }
        }
        camera = null
        handler?.removeCallbacksAndMessages(null)
        thread?.quitSafely()
        thread = null
        handler = null
    }

    private fun frontCameraId(): Int {
        val info = Camera.CameraInfo()
        for (i in 0 until Camera.getNumberOfCameras()) {
            Camera.getCameraInfo(i, info)
            if (info.facing == Camera.CameraInfo.CAMERA_FACING_FRONT) return i
        }
        return 0
    }

    companion object {
        private const val TAG = "MabuCamera"
    }
}

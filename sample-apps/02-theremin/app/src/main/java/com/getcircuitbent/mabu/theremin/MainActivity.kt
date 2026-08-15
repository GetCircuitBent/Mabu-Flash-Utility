package com.getcircuitbent.mabu.theremin

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.TypedValue
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowManager
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import java.io.File

/**
 * ============================================================================
 * Mabu Theremin - the whole app wired together.
 * ============================================================================
 *
 * Three independent clocks, which is the thing to understand before reading
 * anything else:
 *
 *   CAMERA THREAD   10 Hz. Detects the face, builds the hand mask, extracts
 *                   blobs, writes audio targets and motor targets. Never
 *                   touches AudioTrack or the serial port.
 *   TWEEN THREAD    25 Hz. Owns the serial port. Reads motor targets, filters,
 *                   sends frames. (Straight from Sample App 1, unmodified.)
 *   AUDIO THREAD    43 Hz of 1024-sample blocks. Owns AudioTrack. Reads audio
 *                   targets and ramps toward them.
 *
 * Nothing blocks anything else, and every hand-off between them is a volatile
 * field holding a TARGET. That is the same pattern in all three places, and it
 * is why 10 Hz camera data can drive 44.1 kHz audio and 25 Hz motor frames
 * without either sounding or looking like 10 Hz.
 */
class MainActivity : Activity(), ControlReceiver.Handler, SurfaceHolder.Callback {

    // --- Robot (all copied from Sample App 1) ------------------------------
    private val link = MotorLink()
    private lateinit var tween: MotorTween
    private lateinit var player: GesturePlayer
    private lateinit var idle: IdleScene
    private lateinit var faceFollow: FaceFollow

    // --- Vision ------------------------------------------------------------
    private lateinit var camera: Camera1Source
    private lateinit var faces: FaceDetector
    private val motionMask = MotionMask()
    private val toneMask = ToneMask()
    @Volatile private var tracker: HandTracker = motionMask
    private val blobs = BlobExtractor()
    private val mask = ByteArray(HandTracking.maskW * HandTracking.maskH)
    @Volatile private var trackMs = 0f
    @Volatile private var pendingCalibration = false

    // --- Test harness ------------------------------------------------------
    // Replays saved frames through the same pipeline instead of the camera.
    // See ReplaySource for why this matters more than it looks like it should.
    private lateinit var replay: ReplaySource
    @Volatile private var replaying = false
    /** Last frame seen, so CAPTURE can save exactly what the tracker just used. */
    @Volatile private var lastFrame: ByteArray? = null

    // --- Audio -------------------------------------------------------------
    private val sample = SamplePlayer()
    private lateinit var audio: AudioEngine

    @Volatile private var leftParam = HandParam.VOLUME
    @Volatile private var rightParam = HandParam.PITCH

    // --- UI ----------------------------------------------------------------
    private lateinit var preview: SurfaceView
    // NOT named `overlay`: android.view.View already has an `overlay`
    // property, so inside any `apply {}` on a View the receiver's member
    // would shadow this field and the compiler error is baffling.
    private lateinit var overlayView: CameraOverlayView
    private lateinit var statusLine: TextView
    private lateinit var perfLine: TextView
    private lateinit var sampleLine: TextView
    private lateinit var calibLine: TextView
    private lateinit var trackerButton: Button
    private lateinit var armButton: Button
    private lateinit var replayButton: Button
    private lateinit var qualityLine: TextView

    private val ui = Handler(Looper.getMainLooper())

    // =======================================================================
    // LIFECYCLE
    // =======================================================================

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        tween = MotorTween(link)
        player = GesturePlayer(tween)
        idle = IdleScene(tween, player)
        faceFollow = FaceFollow(tween, player)

        // Order matters and is the entire arbitration between the two. Idle
        // writes its sweep; FaceFollow then overwrites the same motors if it
        // has a face. Blinks are a gesture and claim their motors, so neither
        // touches the eyelids. See FaceFollow's header.
        tween.onTick = { now ->
            idle.tick(now)
            faceFollow.tick(faces.faceBox)
        }

        faces = FaceDetector()
        audio = AudioEngine(sample)
        camera = Camera1Source(::onCameraFrame)
        // Both sources call the SAME handler. Nothing downstream can tell
        // whether a frame came from the camera or from a file, which is the
        // property that makes the harness worth having.
        replay = ReplaySource(::onCameraFrame)

        buildUi()

        sample.loadAsset(this, SamplePlayer.ASSET_SAMPLE)?.let { toast(it) }
        syncSampleLine()

        tween.start { ok ->
            ui.post {
                statusLine.text = if (ok) "Link ${link.status}" else "Link FAILED: ${link.status}"
                statusLine.setTextColor(if (ok) GREEN else ORANGE)
                if (ok) idle.reset(SystemClock.uptimeMillis())
            }
        }
        audio.start()

        ControlReceiver.handler = this
        ui.post(refresh)

        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.CAMERA), 1)
        }
    }

    override fun onDestroy() {
        ControlReceiver.handler = null
        ui.removeCallbacksAndMessages(null)
        camera.stop()
        replay.stop()
        faces.close()
        audio.stop()
        tween.stop()
        super.onDestroy()
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        if (!camera.start(holder)) toast("Camera failed to open")
    }

    override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, ht: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) = camera.stop()

    // =======================================================================
    // THE FRAME PIPELINE - runs on the camera thread, 10 times a second
    // =======================================================================

    private fun onCameraFrame(nv21: ByteArray, width: Int, height: Int) {
        val t0 = SystemClock.uptimeMillis()
        lastFrame = nv21

        // 1. Face detection is asynchronous; this just hands ML Kit the frame
        //    and moves on. The result lands a frame later, which is fine.
        faces.submit(nv21, width, height)
        val faceBox = faces.faceBox

        // 2. Tone mode calibrates itself from the face the first time it sees
        //    one, so switching to it is not a dead end if nobody reads the
        //    instructions. A marker is better; this at least works.
        if (tracker === toneMask && faceBox != null && (!toneMask.calibrated || pendingCalibration)) {
            if (pendingCalibration) {
                // Manual: sample the centre box instead, where the operator is
                // holding a hand or a marker.
                toneMask.calibrate(nv21, width, height, CAL_BOX)
                pendingCalibration = false
            } else {
                toneMask.calibrate(nv21, width, height, faceBox)
            }
        } else if (pendingCalibration) {
            toneMask.calibrate(nv21, width, height, CAL_BOX)
            pendingCalibration = false
        }

        // 3. Mask, then blobs. The only line that knows which tracker is
        //    active is this one.
        tracker.buildMask(nv21, width, height, mask)
        val (left, right) = blobs.extract(mask, faceBox)

        // 4. Drive the audio. handsPresent is what gates sound; see
        //    AudioEngine's header for why that is presence and not volume.
        audio.handsPresent = (left != null || right != null)

        if (left != null) Mapping.apply(leftParam, Mapping.readAxis(left), audio)
        else Mapping.release(leftParam, audio)

        if (right != null) Mapping.apply(rightParam, Mapping.readAxis(right), audio)
        else Mapping.release(rightParam, audio)

        // 5. Draw. postInvalidate because we are not on the main thread.
        overlayView.faceBox = faceBox
        overlayView.leftHand = left
        overlayView.rightHand = right
        // In replay the SurfaceView shows nothing (the camera is stopped), so
        // the overlay draws the frame under test itself. You have to SEE what
        // you are testing or the harness is just numbers.
        overlayView.backgroundFrame = if (replaying) replay.currentBitmap else null
        overlayView.postInvalidate()

        trackMs = trackMs * 0.8f + (SystemClock.uptimeMillis() - t0) * 0.2f
    }

    // =======================================================================
    // UI
    // =======================================================================

    private fun buildUi() {
        val page = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), dp(10), dp(14), dp(24))
            setBackgroundColor(BG)
        }
        val scroll = ScrollView(this).apply {
            addView(page, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        }
        setContentView(scroll)

        page.addView(title("Mabu Theremin"))
        statusLine = body("Link opening...").also { page.addView(it) }

        // ---- Camera + overlay -------------------------------------------
        // Fixed height rather than a 4:3 box: the preview stretches to the
        // surface, and the overlayView maps normalised coordinates to the same
        // view, so boxes stay aligned with what you see either way.
        preview = SurfaceView(this).also { it.holder.addCallback(this) }
        overlayView = CameraOverlayView(this)
        val camBox = FrameLayout(this).apply {
            addView(preview, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
            addView(overlayView, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        }
        page.addView(camBox, LinearLayout.LayoutParams(MATCH_PARENT, dp(240)))

        // ---- Mapping -----------------------------------------------------
        page.addView(section("What Each Hand Does"))
        page.addView(body(
            "Hand HEIGHT is the control. Pick a parameter per hand; picking one " +
                "the other hand already owns releases it there, because two hands " +
                "fighting over one value is miserable to play."
        ))
        val mapRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        mapRow.addView(label("Left"))
        mapRow.addView(paramSpinner(true))
        mapRow.addView(label("   Right"))
        mapRow.addView(paramSpinner(false))
        page.addView(mapRow)

        // ---- Tracker -----------------------------------------------------
        page.addView(section("How It Finds Your Hands"))
        page.addView(body(
            "MOTION needs no setup and does not care about skin tone, but a hand " +
                "held still fades into the background. TONE holds a still hand, and " +
                "wants calibrating - a brightly coloured glove is best. Neither is " +
                "a real hand tracker; see HandTracker.kt for why this device cannot " +
                "have one."
        ))
        trackerButton = button("Tracking: Motion") { toggleTracker() }
        page.addView(row(
            trackerButton,
            button("Calibrate") { startCalibration() },
        ))
        calibLine = body("").also { page.addView(it) }

        // The tracker's own opinion of how it is doing. This is here because
        // the tone tracker cannot be fully validated across everyone who might
        // use it, so instead of hoping, it reports. See HandTracker.quality.
        qualityLine = body("").also { page.addView(it) }

        page.addView(section("Test Harness"))
        page.addView(body(
            "CAPTURE saves the current frame to " + FrameStore.DIR + ". REPLAY runs " +
                "saved frames through the same pipeline instead of the camera, at the " +
                "same 10 fps, so tuning changes one variable instead of two. Capture " +
                "anyone who walks past and the corpus becomes a permanent test - which " +
                "is the only practical way to cover a range of people over time. " +
                "scripts/tone-sweep.py synthesises darker and dimmer variants of a " +
                "capture on your PC."
        ))
        replayButton = button("Replay: off") { toggleReplay() }
        page.addView(row(
            button("Capture Frame") { captureFrame() },
            replayButton,
        ))

        page.addView(slider("Motion: adapt rate", 0.002f, 0.08f, motionMask.adaptRate) {
            motionMask.adaptRate = it
        })
        page.addView(slider("Motion: threshold", 5f, 60f, motionMask.threshold.toFloat()) {
            motionMask.threshold = it.toInt()
        })
        page.addView(slider("Tone: tolerance", 4f, 40f, toneMask.tolerance.toFloat()) {
            toneMask.tolerance = it.toInt()
        })
        page.addView(slider("Min blob size (%)", 0.1f, 3f, blobs.minAreaFrac * 100f) {
            blobs.minAreaFrac = it / 100f
        })
        page.addView(slider("Hand smoothing", 0.1f, 1f, blobs.smoothing) {
            blobs.smoothing = it
        })

        // ---- Sound -------------------------------------------------------
        page.addView(section("Sound"))
        sampleLine = body("").also { page.addView(it) }
        armButton = button("ARMED") { toggleArm() }
        page.addView(row(
            armButton,
            button("Load /sdcard") { loadFromSdcard() },
        ))
        page.addView(slider("Master gain", 0f, 1f, audio.masterGain) { audio.masterGain = it })
        page.addView(body(
            "Sound is gated on HANDS BEING VISIBLE, not on any volume mapping, so " +
                "it cannot be configured into screaming. Hands gone: 250 ms grace, " +
                "then a 150 ms fade, because an instant cut is a click."
        ))

        // ---- Robot -------------------------------------------------------
        page.addView(section("The Robot"))
        page.addView(body(
            "It watches you and blinks on its own. Y offset is a PER-UNIT " +
                "calibration: the camera is in the chest, angled up, so without it " +
                "the robot looks at the ceiling."
        ))
        page.addView(slider("Y offset", -1f, 0.5f, faceFollow.yOffset) { faceFollow.yOffset = it })
        page.addView(slider("Gain", 0.5f, 3f, faceFollow.gain) { faceFollow.gain = it })
        page.addView(slider("Neck range", 0f, 40f, faceFollow.neckRange) { faceFollow.neckRange = it })
        page.addView(slider("Eye range", 0f, 45f, faceFollow.eyeRange) { faceFollow.eyeRange = it })

        // ---- Perf and reference -----------------------------------------
        page.addView(section("Performance"))
        perfLine = mono("").also { page.addView(it) }
        page.addView(body(
            "The camera HAL delivers 10 fps and no setting changes that. Face " +
                "detection is about 35 ms of the 100 ms budget; the tracker is 3 to " +
                "6 ms. Underruns mean the audio buffer ran dry: raise BLOCK in " +
                "AudioEngine."
        ))

        page.addView(section("Before You Break Something"))
        page.addView(body(SAFETY_TEXT))

        syncTrackerUi()
        syncArmUi()
    }

    private fun paramSpinner(isLeft: Boolean): Spinner = Spinner(this).apply {
        adapter = ArrayAdapter(
            this@MainActivity,
            android.R.layout.simple_spinner_dropdown_item,
            HandParam.ALL.map { it.label },
        )
        setSelection(HandParam.ALL.indexOf(if (isLeft) leftParam else rightParam))
        onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) {
                setParam(isLeft, HandParam.ALL[pos])
            }

            override fun onNothingSelected(p: AdapterView<*>?) {}
        }
    }

    /**
     * Apply a mapping change, releasing whatever the parameter used to control
     * and clearing a duplicate on the other hand.
     */
    private fun setParam(isLeft: Boolean, param: HandParam) {
        val other = if (isLeft) rightParam else leftParam
        val previous = if (isLeft) leftParam else rightParam
        if (previous != param) Mapping.release(previous, audio)

        if (isLeft) leftParam = param else rightParam = param

        if (param != HandParam.NONE && other == param) {
            // Duplicate: drop it on the other hand rather than have both write.
            Mapping.release(other, audio)
            if (isLeft) rightParam = HandParam.NONE else leftParam = HandParam.NONE
            toast("Other hand released ${param.label}")
            // Rebuilding the whole page to move one spinner is not worth it;
            // the toast explains, and the next redraw picks it up.
        }
    }

    /** Save the frame the tracker just used, raw, for the replay corpus. */
    private fun captureFrame() {
        val f = lastFrame
        if (f == null) {
            toast("No frame yet")
            return
        }
        val file = FrameStore.capture(f.copyOf(), tracker.name.lowercase())
        toast(if (file != null) "Saved ${file.name}" else "Capture failed")
    }

    private fun toggleReplay() {
        if (replaying) {
            replay.stop()
            replaying = false
            // Restarting the camera means re-attaching to the live surface.
            camera.start(preview.holder)
        } else {
            val err = replay.start()
            if (err != null) {
                toast(err)
                return
            }
            // One source at a time: two things calling onCameraFrame would
            // interleave frames and the background model would see a scene
            // cutting back and forth.
            camera.stop()
            replaying = true
            // Both trackers hold history that a scene change invalidates.
            tracker.reset()
            blobs.reset()
        }
        replayButton.text = if (replaying) "Replay: ON" else "Replay: off"
    }

    private fun toggleTracker() {
        tracker = if (tracker === motionMask) toneMask else motionMask
        tracker.reset()
        blobs.reset()
        syncTrackerUi()
    }

    private fun startCalibration() {
        if (tracker !== toneMask) {
            toast("Calibration is for Tone tracking. Switch first.")
            return
        }
        overlayView.showCalibrationBox = true
        toast("Hold a hand or marker in the box")
        // Give the operator time to get into position, then sample one frame.
        ui.postDelayed({
            pendingCalibration = true
            ui.postDelayed({
                overlayView.showCalibrationBox = false
                overlayView.postInvalidate()
                syncTrackerUi()
            }, 400)
        }, 2500)
    }

    private fun toggleArm() {
        audio.armed = !audio.armed
        syncArmUi()
    }

    private fun loadFromSdcard() {
        val dir = File(SamplePlayer.SDCARD_DIR)
        val wavs = dir.listFiles { f -> f.isFile && f.name.lowercase().endsWith(".wav") }
            ?.sortedBy { it.name } ?: emptyList()
        if (wavs.isEmpty()) {
            toast("No .wav in ${SamplePlayer.SDCARD_DIR}\nadb push yours.wav there")
            return
        }
        val f = wavs[sdcardIndex++ % wavs.size]
        val err = sample.loadFile(f.absolutePath)
        if (err != null) toast(err) else toast("Loaded ${f.name}")
        syncSampleLine()
    }

    private var sdcardIndex = 0

    private fun syncTrackerUi() {
        trackerButton.text = "Tracking: ${tracker.name}"
        calibLine.text = tracker.calibrationSummary()
    }

    private fun syncArmUi() {
        armButton.text = if (audio.armed) "ARMED" else "silent"
        armButton.setTextColor(if (audio.armed) GREEN else FG_DIM)
    }

    private fun syncSampleLine() {
        sampleLine.text = "Sample: ${sample.label}"
    }

    private val refresh = object : Runnable {
        override fun run() {
            val d = DeviceInfo.snapshot(this@MainActivity)
            perfLine.text = "HAL %.1f fps · face %.0f ms · track %.0f ms · dropped %d\n%s · audio %s · underruns %d"
                .format(
                    camera.fps, faces.inferenceMs, trackMs, camera.droppedFrames,
                    d.summary(), if (audio.active) "sounding" else "silent", audio.underruns,
                )
            calibLine.text = tracker.calibrationSummary()

            val q = tracker.quality()
            qualityLine.text = if (replaying) {
                "REPLAY ${replay.currentName} · ${q.summary()}"
            } else {
                q.summary()
            }
            qualityLine.setTextColor(
                when {
                    q.verdict.isEmpty() -> FG_DIM
                    q.verdict == "GOOD" -> GREEN
                    q.advice.isEmpty() -> FG_DIM
                    else -> ORANGE
                }
            )
            ui.postDelayed(this, 500)
        }
    }

    // =======================================================================
    // ADB control surface
    // =======================================================================

    override fun onArm(on: Boolean) = ui.post { audio.armed = on; syncArmUi() }.let {}

    override fun onSetMapping(hand: String, param: String) {
        ui.post {
            val p = HandParam.ALL.firstOrNull { it.label.equals(param, true) }
            if (p == null) {
                toast("No parameter '$param'. Try: ${HandParam.ALL.joinToString { it.label }}")
            } else {
                setParam(hand.equals("left", true), p)
                toast("$hand -> ${p.label}")
            }
        }
    }

    override fun onSetTracker(name: String) {
        ui.post {
            tracker = if (name.equals("tone", true)) toneMask else motionMask
            tracker.reset(); blobs.reset(); syncTrackerUi()
        }
    }

    override fun onSetSample(path: String) {
        ui.post {
            val err = sample.loadFile(path)
            if (err != null) toast(err)
            syncSampleLine()
        }
    }

    override fun onGesture(name: String) {
        ui.post {
            Gestures.byName(name)?.let { player.play(it, SystemClock.uptimeMillis()) }
                ?: toast("No gesture '$name'")
        }
    }

    // =======================================================================
    // Small UI helpers (same shapes as Sample App 1)
    // =======================================================================

    private fun row(vararg views: View): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        views.forEach { addView(it) }
    }

    private fun label(t: String) = TextView(this).apply {
        text = t
        setTextColor(FG)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setPadding(0, dp(12), dp(4), 0)
    }

    private fun button(t: String, onClick: () -> Unit) = Button(this).apply {
        text = t
        setTextColor(FG)
        setBackgroundColor(SURFACE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setPadding(dp(10), dp(6), dp(10), dp(6))
        layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply {
            rightMargin = dp(6); topMargin = dp(4)
        }
        setOnClickListener { onClick() }
    }

    private fun slider(lbl: String, min: Float, max: Float, initial: Float, onChange: (Float) -> Unit): View {
        val wrap = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(3), 0, dp(3))
        }
        val text = TextView(this).apply {
            text = "$lbl: %.3f".format(initial)
            setTextColor(FG_DIM)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        }
        wrap.addView(text)
        wrap.addView(SeekBar(this).apply {
            this.max = 100
            progress = (((initial - min) / (max - min)) * 100f).toInt().coerceIn(0, 100)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(sb: SeekBar, p: Int, fromUser: Boolean) {
                    val v = min + (max - min) * (p / 100f)
                    text.text = "$lbl: %.3f".format(v)
                    if (fromUser) onChange(v)
                }

                override fun onStartTrackingTouch(sb: SeekBar) {}
                override fun onStopTrackingTouch(sb: SeekBar) {}
            })
        })
        return wrap
    }

    private fun title(t: String) = TextView(this).apply {
        text = t
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
        setTypeface(typeface, Typeface.BOLD)
    }

    private fun section(t: String) = TextView(this).apply {
        text = t.uppercase()
        setTextColor(GREEN)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setTypeface(typeface, Typeface.BOLD)
        setPadding(0, dp(18), 0, dp(3))
    }

    private fun body(t: String) = TextView(this).apply {
        text = t
        setTextColor(FG_DIM)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        setPadding(0, dp(2), 0, dp(4))
    }

    private fun mono(t: String) = TextView(this).apply {
        text = t
        setTextColor(FG_DIM)
        typeface = Typeface.MONOSPACE
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
        setBackgroundColor(SURFACE)
        setPadding(dp(8), dp(8), dp(8), dp(8))
    }

    private fun dp(v: Int): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics,
    ).toInt()

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()

    companion object {
        private val BG = Color.parseColor("#1A242D")
        private val SURFACE = Color.parseColor("#283845")
        private val GREEN = Color.parseColor("#179E19")
        private val ORANGE = Color.parseColor("#FF4F00")
        private val FG = Color.parseColor("#FFFFFF")
        private val FG_DIM = Color.parseColor("#A5B0B7")

        /** Centre calibration region, normalised. Matches the overlayView's box. */
        private val CAL_BOX = floatArrayOf(0.39f, 0.35f, 0.61f, 0.65f, 0f)

        private val SAFETY_TEXT = """
            NEVER run 'adb reboot' on a Mabu. Units have come back without Wi-Fi,
            and with no external USB port that means no way in. Power-cycle instead.

            Only one process may hold /dev/ttyS1. Do not read it from an adb shell
            while this app runs: termios is shared, so the shell reconfigures the
            port underneath the app and the motors go silent.

            If the link fails at startup, something else owns the port:
            adb shell am force-stop com.catalia.factorymode
        """.trimIndent()
    }
}

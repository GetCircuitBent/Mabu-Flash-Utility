package com.getcircuitbent.mabu.signboard

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.TypedValue
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import java.io.File

/**
 * ============================================================================
 * Mabu Signboard - the whole UI.
 * ============================================================================
 *
 * INDEX ROW 6 (the manual motor sliders) plus the screen that ties everything
 * else together.
 *
 * ---------------------------------------------------------------------------
 * TWO SCREENS, ONE ACTIVITY
 * ---------------------------------------------------------------------------
 * ADMIN is a single scrolling page. Everything the app can do is on it, in
 * order, with no tabs and no navigation. You can see the whole feature set by
 * scrolling, which is the point of a sample.
 *
 * SHOW is a full-screen overlay on the same Activity, not a second screen.
 * Double-tap returns to admin.
 *
 * ---------------------------------------------------------------------------
 * WHAT SHOW MODE DOES *NOT* DO
 * ---------------------------------------------------------------------------
 * It does not touch the motors. At all.
 *
 * That is worth stating because "keep moving while the sign is up" sounds
 * like a feature that needs building, and it is not: the motion engine runs
 * on its own thread and has no idea the UI exists. Showing the sign changes
 * what is on the screen and nothing else. Whatever the robot was doing when
 * you pressed the button, it carries on doing.
 *
 * This is the payoff for the architecture in MotorTween. If the UI owned the
 * motors, every screen change would need to think about motion, and pausing
 * would be a bug waiting to happen.
 *
 * ---------------------------------------------------------------------------
 * UI BUILT IN CODE, NOT XML
 * ---------------------------------------------------------------------------
 * Deliberate. A sample is read top to bottom, and a layout split across XML
 * and Kotlin has to be read in two places at once. Nothing here needs a
 * layout editor.
 */
class MainActivity : Activity(), ControlReceiver.Handler {

    // --- The robot ---------------------------------------------------------
    private val link = MotorLink()
    private lateinit var tween: MotorTween
    private lateinit var player: GesturePlayer
    private lateinit var idle: IdleScene

    // --- The screen --------------------------------------------------------
    private lateinit var root: FrameLayout
    private lateinit var adminScroll: ScrollView
    private lateinit var sign: SignView
    private lateinit var statusLine: TextView
    private lateinit var linkLine: TextView
    private lateinit var mediaLine: TextView
    private lateinit var idleButton: Button

    /** Motor sliders, kept so the refresh loop can mirror engine state into them. */
    private val motorBars = HashMap<Int, SeekBar>()
    private val motorValues = HashMap<Int, TextView>()

    /** Which slider the operator has a finger on, so we do not fight them. */
    private var draggingBar: SeekBar? = null

    private var showing = false

    private val ui = Handler(Looper.getMainLooper())
    private lateinit var doubleTap: GestureDetector

    // =======================================================================
    // LIFECYCLE
    // =======================================================================

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // The three layers, innermost first: the tween owns motor I/O, the
        // player scripts gestures onto it, the idle scene decides what should
        // be happening at all.
        tween = MotorTween(link)
        player = GesturePlayer(tween)
        idle = IdleScene(tween, player)

        // The engine's per-tick hook. This one line is the entire connection
        // between "a behaviour" and "the motors".
        tween.onTick = { now -> idle.tick(now) }

        buildUi()

        doubleTap = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDoubleTap(e: MotionEvent): Boolean {
                if (showing) hideSign()
                return true
            }

            // Returning true here is what makes double-tap detection work at
            // all: the detector only looks for a second tap if the first one
            // was claimed.
            override fun onDown(e: MotionEvent): Boolean = true
        })

        // Bring up the serial link. This blocks for about two seconds on the
        // tween thread (the wake sequence), so it reports back by callback.
        tween.start { ok ->
            ui.post {
                linkLine.text = if (ok) {
                    "Link ${link.status} · board awake"
                } else {
                    "Link FAILED: ${link.status}"
                }
                linkLine.setTextColor(if (ok) GREEN else ORANGE)
                if (ok) idle.reset(SystemClock.uptimeMillis())
            }
        }

        ControlReceiver.handler = this
        ui.post(refresh)
    }

    override fun onDestroy() {
        ControlReceiver.handler = null
        ui.removeCallbacksAndMessages(null)
        tween.stop()
        sign.release()
        super.onDestroy()
    }

    // =======================================================================
    // SHOW MODE
    // =======================================================================

    private fun showSign() {
        if (showing) return
        showing = true
        adminScroll.visibility = View.GONE
        sign.visibility = View.VISIBLE

        // Without this the panel blanks on the display timeout, which also
        // drops the Wi-Fi ADB connection and makes the robot unreachable.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        applyImmersive(true)
        sign.restart()
    }

    private fun hideSign() {
        if (!showing) return
        showing = false
        sign.visibility = View.GONE
        adminScroll.visibility = View.VISIBLE
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        applyImmersive(false)
    }

    /**
     * Hide the status and navigation bars.
     *
     * API 27, so this is the old systemUiVisibility flag set rather than
     * WindowInsetsController (API 30+). IMMERSIVE_STICKY means a stray swipe
     * shows the bars briefly and then they go away again on their own, which
     * is what you want for something left running unattended.
     */
    private fun applyImmersive(on: Boolean) {
        window.decorView.systemUiVisibility = if (on) {
            View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        } else {
            View.SYSTEM_UI_FLAG_VISIBLE
        }
    }

    /**
     * Catch the double-tap here, at the Activity, rather than with a listener
     * on the sign view.
     *
     * The reason is defensive: touch listeners on a media view are easy to
     * lose. A SurfaceView (which a future video sign would need) consumes
     * touches before any listener sees them, and then show mode becomes a
     * trap with no way back to the admin screen and no way to stop the app
     * short of adb. Handling it at dispatch means it cannot be taken away.
     */
    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (showing) {
            doubleTap.onTouchEvent(ev)
            // Swallow the event: a single tap should do nothing at all in
            // show mode, so an accidental brush against the panel cannot
            // change anything.
            return true
        }
        return super.dispatchTouchEvent(ev)
    }

    // =======================================================================
    // THE ADMIN PAGE
    // =======================================================================

    private fun buildUi() {
        root = FrameLayout(this)

        val page = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(12), dp(16), dp(24))
            setBackgroundColor(BG)
        }

        adminScroll = ScrollView(this).apply {
            addView(page, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        }
        root.addView(adminScroll, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))

        sign = SignView(this).apply { visibility = View.GONE }
        root.addView(sign, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))

        setContentView(root)

        // ---- Header --------------------------------------------------
        page.addView(title("Mabu Signboard"))
        linkLine = body("Link opening...").also { page.addView(it) }
        statusLine = body("").also { page.addView(it) }

        page.addView(row(
            button("Wake Board") {
                // Safe to repeat. Runs on the tween thread so the UI stays live.
                Thread { link.wake() }.start()
                toast("Wake sequence sent")
            },
            button("All Neutral") {
                idle.enabled = false
                syncIdleButton()
                tween.setTargets(Poses.NEUTRAL.values)
            },
        ))

        // ---- Idle ----------------------------------------------------
        page.addView(section("Idle Behaviour"))
        page.addView(body(
            "The motion that runs while the sign is up: a slow sweep, a blink " +
                "every few seconds, and an occasional gesture. Poses and sliders " +
                "switch it off, because otherwise the loop overwrites you within " +
                "one 40 ms tick and the buttons look broken."
        ))
        idleButton = button("Idle: ON") {
            idle.enabled = !idle.enabled
            if (idle.enabled) idle.reset(SystemClock.uptimeMillis())
            syncIdleButton()
        }
        page.addView(row(idleButton))

        page.addView(slider("Sweep width", 0f, 40f, idle.sweepAmplitude) {
            idle.sweepAmplitude = it
        })
        page.addView(slider("Sweep period (s)", 2f, 20f, idle.sweepPeriodSec) {
            idle.sweepPeriodSec = it
        })
        page.addView(slider("Blink every, min (s)", 1f, 15f, idle.blinkMinSec) {
            idle.blinkMinSec = it
        })
        page.addView(slider("Blink every, max (s)", 2f, 25f, idle.blinkMaxSec) {
            idle.blinkMaxSec = it
        })
        page.addView(slider("Gesture every, min (s)", 5f, 60f, idle.gestureMinSec) {
            idle.gestureMinSec = it
        })
        page.addView(slider("Gesture every, max (s)", 10f, 120f, idle.gestureMaxSec) {
            idle.gestureMaxSec = it
        })

        // ---- Motors --------------------------------------------------
        page.addView(section("Motors"))
        page.addView(body(
            "Live control of all seven motors. The sliders mirror the engine, " +
                "so you can watch them move while idle runs. Touching one takes " +
                "over. Values are 0-100; see the hint under each for which way " +
                "is which on this unit."
        ))
        for (m in MabuProtocol.MOTORS) page.addView(motorSlider(m))

        // ---- Poses ---------------------------------------------------
        page.addView(section("Poses"))
        page.addView(body("A pose is just a set of motor values. Eased into by the tween."))
        var poseRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        Poses.ALL.forEachIndexed { i, pose ->
            if (i > 0 && i % 4 == 0) {
                page.addView(poseRow)
                poseRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            }
            poseRow.addView(button(pose.name) { applyPose(pose) })
        }
        page.addView(poseRow)

        // ---- Gestures ------------------------------------------------
        page.addView(section("Gestures"))
        page.addView(body(
            "Scripted sequences. These do NOT switch idle off: they take the " +
                "motors they need, play, and hand them back. See Gestures.kt to " +
                "write your own - it is four lines and a list entry."
        ))
        var gRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        Gestures.ALL.forEachIndexed { i, g ->
            if (i > 0 && i % 4 == 0) {
                page.addView(gRow)
                gRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            }
            gRow.addView(button(g.name) { playGesture(g) })
        }
        page.addView(gRow)

        // ---- Sign ----------------------------------------------------
        page.addView(section("The Sign"))
        page.addView(body(
            "Stills (PNG/JPEG/WebP) and animated GIF, at 1024x600. Drop your " +
                "own in /sdcard/signboard/ and it appears below. Video is not " +
                "supported here on purpose - see SignView.kt."
        ))
        mediaLine = body("").also { page.addView(it) }

        page.addView(row(
            button("GCB Still") {
                sign.setBundledMedia(animated = false)
                syncMediaLine()
            },
            button("GCB Animated") {
                sign.setBundledMedia(animated = true)
                syncMediaLine()
            },
            button("From /sdcard") { pickFromSdcard() },
        ))
        page.addView(row(
            button("Fit: Contain") {
                sign.fitMode = SignView.FitMode.CONTAIN
                toast("Contain: whole image visible")
            },
            button("Fit: Cover") {
                sign.fitMode = SignView.FitMode.COVER
                toast("Cover: fills screen, crops edges")
            },
        ))
        page.addView(slider("GIF rate (x)", 0f, 3f, 1f) { sign.rate = it })

        page.addView(bigButton("SHOW SIGN") { showSign() })
        page.addView(body("Double-tap the sign to come back here."))

        // ---- About ---------------------------------------------------
        page.addView(section("Before You Break Something"))
        page.addView(body(SAFETY_TEXT))

        page.addView(section("Drive It From Your PC"))
        page.addView(mono(ADB_HELP))

        sign.setBundledMedia(animated = false)
        syncMediaLine()
        syncIdleButton()
    }

    // =======================================================================
    // ACTIONS
    // =======================================================================

    /** Poses take over, so idle goes off. See the note in the Idle section. */
    private fun applyPose(pose: Poses.Pose) {
        idle.enabled = false
        syncIdleButton()
        player.cancel()
        tween.setTargets(pose.values)
    }

    /** Gestures are transient and deliberately leave idle alone. */
    private fun playGesture(g: Gesture) {
        player.play(g, SystemClock.uptimeMillis())
    }

    /**
     * List /sdcard/signboard/ and load the first usable file, cycling on
     * repeat presses.
     *
     * A real file picker would be nicer and would also be fifty lines of
     * dialog code that teaches nothing about the robot.
     */
    private var sdcardIndex = 0

    private fun pickFromSdcard() {
        val dir = File(SignView.SDCARD_DIR)
        val files = dir.listFiles { f ->
            f.isFile && f.name.lowercase().matches(Regex(".*\\.(png|jpg|jpeg|webp|gif)$"))
        }?.sortedBy { it.name } ?: emptyList()

        if (files.isEmpty()) {
            toast("No images in ${SignView.SDCARD_DIR}\nadb push yours.png there")
            return
        }

        val file = files[sdcardIndex % files.size]
        sdcardIndex++
        val err = sign.setMediaFromFile(file.absolutePath)
        if (err != null) toast(err) else toast("Loaded ${file.name}")
        syncMediaLine()
    }

    private fun syncIdleButton() {
        idleButton.text = if (idle.enabled) "Idle: ON" else "Idle: off"
        idleButton.setTextColor(if (idle.enabled) GREEN else FG_DIM)
    }

    private fun syncMediaLine() {
        mediaLine.text = "Loaded: ${sign.mediaLabel}"
    }

    // =======================================================================
    // REFRESH LOOP
    // =======================================================================

    /**
     * Twice a second: update the status line and mirror engine state into the
     * sliders.
     *
     * 2 Hz on purpose. The RK3288 is not fast, and a per-frame TextView
     * relayout is genuinely enough to disturb work on other threads. Slow is
     * fine here; nothing on this header changes quickly.
     */
    private val refresh = object : Runnable {
        override fun run() {
            if (!showing) {
                statusLine.text = DeviceInfo.snapshot(this@MainActivity).summary() +
                    " · frames ${tween.framesSent}" +
                    (player.currentName?.let { " · $it" } ?: "")

                for (m in MabuProtocol.MOTORS) {
                    val bar = motorBars[m.bit] ?: continue
                    // Do not fight a finger that is on this slider.
                    if (bar === draggingBar) continue
                    val v = tween.target(m.bit)
                    bar.progress = v.toInt().coerceIn(0, 100)
                    motorValues[m.bit]?.text = "%.0f".format(v)
                }
            }
            ui.postDelayed(this, 500)
        }
    }

    // =======================================================================
    // ControlReceiver.Handler - the ADB surface
    // =======================================================================

    // Every one of these hops to the main thread: broadcasts arrive on the
    // main thread already, but going through the handler keeps the ordering
    // identical to the button paths and means none of it can touch the UI
    // from the wrong place if a future caller moves off-thread.
    override fun onShow() {
        ui.post { showSign() }
    }

    override fun onHide() {
        ui.post { hideSign() }
    }

    override fun onSetMedia(path: String, rate: Float?) {
        ui.post {
            rate?.let { sign.rate = it }
            val err = sign.setMediaFromFile(path)
            if (err != null) toast(err)
            syncMediaLine()
        }
    }

    override fun onIdle(on: Boolean) {
        ui.post {
            idle.enabled = on
            if (on) idle.reset(SystemClock.uptimeMillis())
            syncIdleButton()
        }
    }

    override fun onPose(name: String) {
        ui.post {
            val pose = Poses.byName(name)
            if (pose == null) {
                toast("No pose '$name'. Try: ${Poses.ALL.joinToString { it.name }}")
            } else {
                applyPose(pose)
            }
        }
    }

    override fun onGesture(name: String) {
        ui.post {
            val g = Gestures.byName(name)
            if (g == null) {
                toast("No gesture '$name'. Try: ${Gestures.ALL.joinToString { it.name }}")
            } else {
                playGesture(g)
            }
        }
    }

    override fun onMove(motorCode: String, value: Float) {
        ui.post {
            val motor = MabuProtocol.MOTORS.firstOrNull {
                it.code.equals(motorCode, ignoreCase = true)
            }
            if (motor == null) {
                toast("No motor '$motorCode'. Try: ${MabuProtocol.MOTORS.joinToString { it.code }}")
            } else {
                idle.enabled = false
                syncIdleButton()
                tween.setTarget(motor.bit, value)
            }
        }
    }

    // =======================================================================
    // SMALL UI HELPERS
    // =======================================================================

    private fun motorSlider(m: MabuProtocol.Motor): View {
        val wrap = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(6), 0, dp(6))
        }

        val header = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        header.addView(TextView(this).apply {
            text = "${m.code}  ${m.label}"
            setTextColor(FG)
            typeface = Typeface.MONOSPACE
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            layoutParams = LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f)
        })
        val valueText = TextView(this).apply {
            text = "%.0f".format(m.neutral)
            setTextColor(GREEN)
            typeface = Typeface.MONOSPACE
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        }
        header.addView(valueText)
        wrap.addView(header)

        val bar = SeekBar(this).apply {
            max = 100
            progress = m.neutral.toInt()
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(sb: SeekBar, p: Int, fromUser: Boolean) {
                    if (!fromUser) return
                    // A finger on a slider means manual control is wanted.
                    if (idle.enabled) {
                        idle.enabled = false
                        syncIdleButton()
                    }
                    tween.setTarget(m.bit, p.toFloat())
                    valueText.text = "$p"
                }

                override fun onStartTrackingTouch(sb: SeekBar) {
                    draggingBar = sb
                }

                override fun onStopTrackingTouch(sb: SeekBar) {
                    draggingBar = null
                }
            })
        }
        wrap.addView(bar)

        wrap.addView(TextView(this).apply {
            text = "0 = ${m.lowMeans}   ·   100 = ${m.highMeans}"
            setTextColor(FG_DIM)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
        })

        motorBars[m.bit] = bar
        motorValues[m.bit] = valueText
        return wrap
    }

    private fun slider(label: String, min: Float, max: Float, initial: Float, onChange: (Float) -> Unit): View {
        val wrap = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(4), 0, dp(4))
        }
        val text = TextView(this).apply {
            text = "$label: %.1f".format(initial)
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
                    text.text = "$label: %.1f".format(v)
                    if (fromUser) onChange(v)
                }

                override fun onStartTrackingTouch(sb: SeekBar) {}
                override fun onStopTrackingTouch(sb: SeekBar) {}
            })
        })
        return wrap
    }

    private fun row(vararg views: View): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        views.forEach { addView(it) }
    }

    private fun button(label: String, onClick: () -> Unit) = Button(this).apply {
        text = label
        setTextColor(FG)
        setBackgroundColor(SURFACE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setPadding(dp(10), dp(6), dp(10), dp(6))
        layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply {
            rightMargin = dp(6)
            topMargin = dp(4)
        }
        setOnClickListener { onClick() }
    }

    private fun bigButton(label: String, onClick: () -> Unit) = Button(this).apply {
        text = label
        setTextColor(Color.WHITE)
        setBackgroundColor(GREEN)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
        setPadding(dp(16), dp(14), dp(16), dp(14))
        layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply {
            topMargin = dp(12)
        }
        setOnClickListener { onClick() }
    }

    private fun title(t: String) = TextView(this).apply {
        text = t
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
        setTypeface(typeface, Typeface.BOLD)
    }

    private fun section(t: String) = TextView(this).apply {
        text = t.uppercase()
        setTextColor(GREEN)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        setTypeface(typeface, Typeface.BOLD)
        setPadding(0, dp(20), 0, dp(4))
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

    private fun dp(v: Int): Int =
        TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics,
        ).toInt()

    private fun toast(msg: String) {
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
    }

    companion object {
        // Get Circuit Bent dark theme. See the GCB style guide repo.
        private val BG = Color.parseColor("#1A242D")       // Bluewood 900
        private val SURFACE = Color.parseColor("#283845")  // Bluewood 800
        private val GREEN = Color.parseColor("#179E19")    // La Palma
        private val ORANGE = Color.parseColor("#FF4F00")   // Signal Orange
        private val FG = Color.parseColor("#FFFFFF")
        private val FG_DIM = Color.parseColor("#A5B0B7")   // Cadet Gray

        private val SAFETY_TEXT = """
            NEVER run 'adb reboot' on a Mabu. It has left units that came back
            without Wi-Fi, and with no external USB port and no buttons that
            means no way in short of opening the case. Power-cycle instead.

            Only one process may hold /dev/ttyS1. Do not 'cat /dev/ttyS1' from
            an adb shell while this app is running: termios settings are shared
            across every open descriptor, so a shell reconfigures the port
            underneath the app and the motors go silent with nothing in any log.
            Read logcat instead.

            If nothing moves, push the head gently. LIMP means the motor board
            has no power, which is a wiring fault and not a software problem.
            STIFF means the board is powered and holding, so the problem is the
            wake sequence or another app owning the port.

            If the link fails at startup, something else has the port. On a
            freshly flashed unit that is usually com.catalia.factorymode:
            adb shell am force-stop com.catalia.factorymode
        """.trimIndent()

        private val ADB_HELP = """
            P=com.getcircuitbent.mabu.signboard

            am broadcast -a ${'$'}P.SHOW -p ${'$'}P
            am broadcast -a ${'$'}P.HIDE -p ${'$'}P
            am broadcast -a ${'$'}P.IDLE -p ${'$'}P --ez on false
            am broadcast -a ${'$'}P.POSE -p ${'$'}P --es name Sleep
            am broadcast -a ${'$'}P.GESTURE -p ${'$'}P --es name 'Nod Yes'
            am broadcast -a ${'$'}P.MOVE -p ${'$'}P --es motor NR --ef value 80
            am broadcast -a ${'$'}P.SET_MEDIA -p ${'$'}P \
              --es path /sdcard/signboard/promo.gif --ef rate 0.75

            The -p flag is required. Without it Android 8+ silently drops
            the broadcast and reports success.
        """.trimIndent()
    }
}

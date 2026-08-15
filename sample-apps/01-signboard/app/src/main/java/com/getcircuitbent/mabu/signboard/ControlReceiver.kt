package com.getcircuitbent.mabu.signboard

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * ============================================================================
 * INDEX ROW 20 - driving the app from your PC over ADB.
 * ============================================================================
 *
 * Lets you control a running Signboard without touching the screen. That is
 * useful three ways: scripting a demo, testing a change without walking over
 * to the robot, and swapping the sign on a deployed unit from a laptop.
 *
 * ---------------------------------------------------------------------------
 * *** THE -p FLAG IS NOT OPTIONAL ***
 * ---------------------------------------------------------------------------
 * Every command below includes `-p com.getcircuitbent.mabu.signboard`. Since
 * Android 8.0, implicit broadcasts are not delivered to receivers declared in
 * the manifest. Leave the flag off and `am broadcast` cheerfully reports
 *
 *     Broadcast completed: result=0
 *
 * while absolutely nothing happens. There is no error and nothing in logcat.
 * If a command seems to do nothing, check the -p flag first, every time.
 *
 * ---------------------------------------------------------------------------
 * THE COMMANDS
 * ---------------------------------------------------------------------------
 * Extras are typed: --es string, --ei int, --ef float, --ez boolean.
 *
 *   Show the sign full-screen / return to the admin screen:
 *     adb shell "am broadcast -a com.getcircuitbent.mabu.signboard.SHOW -p com.getcircuitbent.mabu.signboard"
 *     adb shell "am broadcast -a com.getcircuitbent.mabu.signboard.HIDE -p com.getcircuitbent.mabu.signboard"
 *
 *   Swap the sign. Push the file first, then point at it:
 *     adb push promo.gif /sdcard/signboard/
 *     adb shell "am broadcast -a com.getcircuitbent.mabu.signboard.SET_MEDIA -p com.getcircuitbent.mabu.signboard --es path /sdcard/signboard/promo.gif --ef rate 0.75"
 *
 *   Fill the screen (COVER, default) or fit the whole image (CONTAIN):
 *     adb shell "am broadcast -a com.getcircuitbent.mabu.signboard.FIT -p com.getcircuitbent.mabu.signboard --ez fill false"
 *
 *   Turn the idle behaviour on or off:
 *     adb shell "am broadcast -a com.getcircuitbent.mabu.signboard.IDLE -p com.getcircuitbent.mabu.signboard --ez on false"
 *
 *   Strike a pose, or play a gesture (names from Poses.ALL / Gestures.ALL):
 *     adb shell "am broadcast -a com.getcircuitbent.mabu.signboard.POSE -p com.getcircuitbent.mabu.signboard --es name Sleep"
 *     adb shell "am broadcast -a com.getcircuitbent.mabu.signboard.GESTURE -p com.getcircuitbent.mabu.signboard --es name 'Nod Yes'"
 *
 *   Move one motor (code from MabuProtocol.MOTORS: LDL LDR ELR EUD NE NR NT):
 *     adb shell "am broadcast -a com.getcircuitbent.mabu.signboard.MOVE -p com.getcircuitbent.mabu.signboard --es motor NR --ef value 80"
 *
 * ---------------------------------------------------------------------------
 * SECURITY POSTURE
 * ---------------------------------------------------------------------------
 * This receiver is exported and unprotected, which is what makes it reachable
 * from `am broadcast` at all. Anything on the device can send these too. That
 * is fine for a bench tool on a LAN; if you deploy a Signboard somewhere
 * untrusted, either delete the receiver from the manifest or add a signature
 * permission to it.
 */
class ControlReceiver : BroadcastReceiver() {

    /**
     * Set by MainActivity while it is alive. Commands are ignored when the
     * activity is not running, since there is nothing to control.
     *
     * Held statically because the system creates a NEW receiver instance for
     * every broadcast - there is no way to hand this one a reference.
     */
    companion object {
        private const val TAG = "MabuControl"
        private const val PKG = "com.getcircuitbent.mabu.signboard"

        const val ACTION_SHOW = "$PKG.SHOW"
        const val ACTION_HIDE = "$PKG.HIDE"
        const val ACTION_SET_MEDIA = "$PKG.SET_MEDIA"
        const val ACTION_FIT = "$PKG.FIT"
        const val ACTION_IDLE = "$PKG.IDLE"
        const val ACTION_POSE = "$PKG.POSE"
        const val ACTION_GESTURE = "$PKG.GESTURE"
        const val ACTION_MOVE = "$PKG.MOVE"

        @Volatile
        var handler: Handler? = null
    }

    /** Implemented by MainActivity. Every method is called on the main thread. */
    interface Handler {
        fun onShow()
        fun onHide()
        fun onSetMedia(path: String, rate: Float?)
        fun onFit(fill: Boolean)
        fun onIdle(on: Boolean)
        fun onPose(name: String)
        fun onGesture(name: String)
        fun onMove(motorCode: String, value: Float)
    }

    override fun onReceive(context: Context, intent: Intent) {
        val h = handler
        if (h == null) {
            Log.w(TAG, "${intent.action} ignored: app is not running")
            return
        }

        Log.i(TAG, "rx ${intent.action}")
        when (intent.action) {
            ACTION_SHOW -> h.onShow()
            ACTION_HIDE -> h.onHide()

            ACTION_SET_MEDIA -> {
                val path = intent.getStringExtra("path")
                if (path.isNullOrBlank()) {
                    Log.w(TAG, "SET_MEDIA needs --es path <file>")
                } else {
                    // hasExtra so that an absent rate means "leave it alone"
                    // rather than "set it to zero", which would freeze the GIF.
                    val rate = if (intent.hasExtra("rate")) {
                        intent.getFloatExtra("rate", 1f)
                    } else {
                        null
                    }
                    h.onSetMedia(path, rate)
                }
            }

            ACTION_FIT -> h.onFit(intent.getBooleanExtra("fill", true))

            ACTION_IDLE -> h.onIdle(intent.getBooleanExtra("on", true))

            ACTION_POSE -> intent.getStringExtra("name")?.let(h::onPose)
                ?: Log.w(TAG, "POSE needs --es name <pose>")

            ACTION_GESTURE -> intent.getStringExtra("name")?.let(h::onGesture)
                ?: Log.w(TAG, "GESTURE needs --es name <gesture>")

            ACTION_MOVE -> {
                val motor = intent.getStringExtra("motor")
                if (motor.isNullOrBlank()) {
                    Log.w(TAG, "MOVE needs --es motor <code> --ef value <0..100>")
                } else {
                    h.onMove(motor, intent.getFloatExtra("value", 50f))
                }
            }

            else -> Log.w(TAG, "unknown action ${intent.action}")
        }
    }
}

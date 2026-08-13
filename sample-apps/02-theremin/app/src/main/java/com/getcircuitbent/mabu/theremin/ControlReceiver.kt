package com.getcircuitbent.mabu.theremin

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * ============================================================================
 * INDEX ROW 20 - driving the instrument from your PC.
 * ============================================================================
 *
 * Same pattern as Sample App 1, different verbs. Useful for setting up a demo
 * without standing at the robot poking dropdowns, and for A/B-ing the two
 * trackers while someone else stands in front of the camera.
 *
 * *** EVERY COMMAND NEEDS -p <package>. *** Since Android 8.0 an implicit
 * broadcast never reaches a manifest-registered receiver, and `am broadcast`
 * reports "result=0" success while doing absolutely nothing.
 *
 *   adb shell "am broadcast -a com.getcircuitbent.mabu.theremin.ARM -p com.getcircuitbent.mabu.theremin --ez on false"
 *   adb shell "am broadcast -a com.getcircuitbent.mabu.theremin.MAP -p com.getcircuitbent.mabu.theremin --es hand left --es param Pitch"
 *   adb shell "am broadcast -a com.getcircuitbent.mabu.theremin.TRACKER -p com.getcircuitbent.mabu.theremin --es name tone"
 *   adb shell "am broadcast -a com.getcircuitbent.mabu.theremin.SAMPLE -p com.getcircuitbent.mabu.theremin --es path /sdcard/theremin/loop.wav"
 *   adb shell "am broadcast -a com.getcircuitbent.mabu.theremin.GESTURE -p com.getcircuitbent.mabu.theremin --es name 'Nod Yes'"
 *
 * Exported and unprotected, which is what makes it reachable at all. Fine for
 * a bench tool on a LAN; delete the receiver or add a permission before
 * putting a Theremin somewhere untrusted.
 */
class ControlReceiver : BroadcastReceiver() {

    interface Handler {
        fun onArm(on: Boolean)
        fun onSetMapping(hand: String, param: String)
        fun onSetTracker(name: String)
        fun onSetSample(path: String)
        fun onGesture(name: String)
    }

    companion object {
        private const val TAG = "MabuControl"
        private const val PKG = "com.getcircuitbent.mabu.theremin"

        const val ACTION_ARM = "$PKG.ARM"
        const val ACTION_MAP = "$PKG.MAP"
        const val ACTION_TRACKER = "$PKG.TRACKER"
        const val ACTION_SAMPLE = "$PKG.SAMPLE"
        const val ACTION_GESTURE = "$PKG.GESTURE"

        @Volatile
        var handler: Handler? = null
    }

    override fun onReceive(context: Context, intent: Intent) {
        val h = handler
        if (h == null) {
            Log.w(TAG, "${intent.action} ignored: app is not running")
            return
        }
        Log.i(TAG, "rx ${intent.action}")

        when (intent.action) {
            ACTION_ARM -> h.onArm(intent.getBooleanExtra("on", true))

            ACTION_MAP -> {
                val hand = intent.getStringExtra("hand")
                val param = intent.getStringExtra("param")
                if (hand.isNullOrBlank() || param.isNullOrBlank()) {
                    Log.w(TAG, "MAP needs --es hand left|right --es param <name>")
                } else {
                    h.onSetMapping(hand, param)
                }
            }

            ACTION_TRACKER -> intent.getStringExtra("name")?.let(h::onSetTracker)
                ?: Log.w(TAG, "TRACKER needs --es name motion|tone")

            ACTION_SAMPLE -> intent.getStringExtra("path")?.let(h::onSetSample)
                ?: Log.w(TAG, "SAMPLE needs --es path <file.wav>")

            ACTION_GESTURE -> intent.getStringExtra("name")?.let(h::onGesture)
                ?: Log.w(TAG, "GESTURE needs --es name <gesture>")

            else -> Log.w(TAG, "unknown action ${intent.action}")
        }
    }
}

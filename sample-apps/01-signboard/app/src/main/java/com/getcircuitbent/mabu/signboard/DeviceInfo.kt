package com.getcircuitbent.mabu.signboard

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.SystemClock
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * ============================================================================
 * INDEX ROW 19 - what the robot can tell you about itself.
 * ============================================================================
 *
 * Battery, temperature, uptime and IP address, formatted for the admin header.
 *
 * The IP address is the one that really matters. The Mabu has no external USB
 * port, so Wi-Fi ADB is the only way to reach it, and the address is handed
 * out by DHCP and changes. Putting it on screen means you can walk up to the
 * robot, read the address, and connect - instead of hunting through your
 * router's client table.
 */
object DeviceInfo {

    data class Snapshot(
        val batteryPct: Int,
        val batteryTempC: Float,
        val charging: Boolean,
        val uptimeMs: Long,
        val ipAddress: String,
    ) {
        /** One line for the admin header. */
        fun summary(): String {
            val batt = if (batteryPct >= 0) {
                buildString {
                    append("Batt $batteryPct%")
                    if (charging) append(" (chg)")
                    if (!batteryTempC.isNaN()) append(" %.1fC".format(batteryTempC))
                }
            } else {
                "Batt n/a"
            }
            return "$batt · up ${formatUptime(uptimeMs)} · $ipAddress"
        }
    }

    fun snapshot(context: Context): Snapshot {
        var pct = -1
        var tempC = Float.NaN
        var charging = false

        // A null receiver with ACTION_BATTERY_CHANGED returns the current
        // sticky broadcast without actually registering anything. It is a
        // binder call, so do not do this every frame - the admin screen
        // refreshes at 2 Hz, which is plenty.
        try {
            val intent: Intent? = context.registerReceiver(
                null, IntentFilter(Intent.ACTION_BATTERY_CHANGED),
            )
            if (intent != null) {
                val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                if (level >= 0 && scale > 0) pct = level * 100 / scale

                // Reported in tenths of a degree C.
                val tenths = intent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
                if (tenths != Int.MIN_VALUE) tempC = tenths / 10f

                val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                    status == BatteryManager.BATTERY_STATUS_FULL
            }
        } catch (_: Throwable) {
            // Never let a status read take down the UI.
        }

        return Snapshot(
            batteryPct = pct,
            batteryTempC = tempC,
            charging = charging,
            uptimeMs = SystemClock.elapsedRealtime(),
            ipAddress = wifiIpAddress(),
        )
    }

    /**
     * The device's IPv4 address on wlan0.
     *
     * Read straight from NetworkInterface rather than through WifiManager,
     * because that needs no permission at all.
     */
    fun wifiIpAddress(): String {
        return try {
            NetworkInterface.getNetworkInterfaces().toList()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { it.inetAddresses.toList() }
                .filterIsInstance<Inet4Address>()
                .firstOrNull()
                ?.hostAddress
                ?: "no IP"
        } catch (_: Throwable) {
            "no IP"
        }
    }

    private fun formatUptime(ms: Long): String {
        val totalMin = ms / 60000
        val h = totalMin / 60
        val m = totalMin % 60
        return if (h > 0) "${h}h${m}m" else "${m}m"
    }
}

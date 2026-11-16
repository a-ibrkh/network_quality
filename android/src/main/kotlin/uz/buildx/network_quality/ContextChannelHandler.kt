package uz.buildx.network_quality

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.sqrt

/**
 * Handles the "network_quality/context" MethodChannel: the circumstances
 * around a reading that explain a bad number without being about the
 * network itself.
 *
 * - getDeviceExtras: battery saver and thermal status. Both make the
 *   phone throttle its modem, which drags throughput down.
 * - sampleEnvironment: ambient light, motion and Wi-Fi counts over a short
 *   window - indoor/outdoor and moving/still hints alongside GNSS.
 *
 * Motion uses the accelerometer rather than Play Services activity
 * recognition: no new permission, no new dependency. Its spread tells
 * still from moving; GPS speed (already collected) separates walking from
 * driving.
 *
 * Wi-Fi reports counts and the strongest signal only. Network names and
 * BSSIDs identify places as precisely as GPS, so they never leave here.
 */
class ContextChannelHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "network_quality/context"

        /** Scan results older than this describe somewhere else; ignore them. */
        private const val WIFI_MAX_AGE_MS = 2 * 60 * 1000L
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getDeviceExtras" -> result.success(deviceExtras())
            "sampleEnvironment" -> {
                val durationMs = (call.argument<Int>("durationMs") ?: 6000).toLong()
                sampleEnvironment(durationMs, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun deviceExtras(): Map<String, Any?> {
        val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        return mapOf(
            "isPowerSaveMode" to pm?.isPowerSaveMode,
            "thermalStatus" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && pm != null) {
                when (pm.currentThermalStatus) {
                    PowerManager.THERMAL_STATUS_NONE -> "none"
                    PowerManager.THERMAL_STATUS_LIGHT -> "light"
                    PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
                    PowerManager.THERMAL_STATUS_SEVERE -> "severe"
                    PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
                    PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
                    PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
                    else -> null
                }
            } else null,
        )
    }

    private fun sampleEnvironment(durationMs: Long, result: MethodChannel.Result) {
        val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        val light = sensorManager?.getDefaultSensor(Sensor.TYPE_LIGHT)
        // Linear acceleration has gravity removed; fall back to the raw
        // accelerometer, whose spread around 1 g works the same way.
        val motion = sensorManager?.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
            ?: sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)

        var maxLux: Float? = null
        var count = 0
        var sum = 0.0
        var sumSquares = 0.0

        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                when (event.sensor.type) {
                    Sensor.TYPE_LIGHT -> maxLux = maxOf(maxLux ?: 0f, event.values[0])
                    else -> {
                        val (x, y, z) = Triple(event.values[0], event.values[1], event.values[2])
                        val magnitude = sqrt((x * x + y * y + z * z).toDouble())
                        count++
                        sum += magnitude
                        sumSquares += magnitude * magnitude
                    }
                }
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }

        val handler = Handler(Looper.getMainLooper())
        light?.let { sensorManager?.registerListener(listener, it, SensorManager.SENSOR_DELAY_NORMAL, handler) }
        motion?.let { sensorManager?.registerListener(listener, it, SensorManager.SENSOR_DELAY_GAME, handler) }

        handler.postDelayed({
            sensorManager?.unregisterListener(listener)
            val stdDev = if (count >= 2) {
                val mean = sum / count
                sqrt(maxOf(0.0, sumSquares / count - mean * mean))
            } else null
            result.success(
                mapOf(
                    // Max over the window: a pocket or a hand covers the
                    // sensor some of the time; the brightest moment is the
                    // best estimate of the surroundings.
                    "ambientLux" to maxLux?.toDouble(),
                    "accelStdDevMps2" to stdDev,
                    "sampleSeconds" to durationMs / 1000.0,
                ) + wifiCounts()
            )
        }, durationMs)
    }

    /**
     * Visible Wi-Fi networks from the OS's latest scan - no scan is
     * triggered (Android throttles those). Needs precise location and
     * location services on; null when the scan list is unavailable.
     */
    private fun wifiCounts(): Map<String, Any?> {
        val granted = context.packageManager.checkPermission(
            Manifest.permission.ACCESS_FINE_LOCATION, context.packageName
        ) == PackageManager.PERMISSION_GRANTED
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        if (!granted || wifi == null) return emptyMap()
        @Suppress("DEPRECATION")
        val scanAvailable = wifi.isWifiEnabled || wifi.isScanAlwaysAvailable
        if (!scanAvailable) return emptyMap()
        return try {
            val nowMicros = SystemClock.elapsedRealtime() * 1000
            val recent = wifi.scanResults.orEmpty()
                .filter { nowMicros - it.timestamp <= WIFI_MAX_AGE_MS * 1000 }
            mapOf(
                "wifiNetworksVisible" to recent.size,
                "wifiStrongestRssiDbm" to recent.maxOfOrNull { it.level },
            )
        } catch (e: SecurityException) {
            emptyMap()
        }
    }
}

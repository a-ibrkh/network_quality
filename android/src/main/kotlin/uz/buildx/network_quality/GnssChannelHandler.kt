package uz.buildx.network_quality

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.GnssStatus
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Handles the "network_quality/gnss" MethodChannel: samples satellite
 * status for a short window, as raw hints for indoor/outdoor detection.
 *
 * Walls cost 10-20 dB of cellular signal, so a reading taken indoors looks
 * like bad coverage. GNSS is the strongest available hint: open sky sees
 * many satellites at a strong carrier-to-noise density (C/N0), a building
 * sees few or none, and weak.
 *
 * GnssStatus callbacks only fire while the GPS engine is running, and the
 * rest of the module only reads the OS's cached position, so this turns
 * the GPS provider on for [durationMs] and off again. The location updates
 * themselves are discarded - they're requested purely to power the engine.
 *
 * Aggregation is the maximum over the window, because the engine starts
 * cold: the first callbacks see few satellites, and the window's best
 * moment is the best description of the sky view. Satellites "used in
 * fix" can stay 0 for a while even outdoors, which is why C/N0 of every
 * visible satellite is reported alongside.
 *
 * Requires ACCESS_FINE_LOCATION - Android withholds GNSS status from an
 * approximate-only grant. GnssStatus is API 24+; older devices report
 * "unsupported".
 */
class GnssChannelHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "network_quality/gnss"

        /** Strongest satellites averaged for [topCn0DbHz]. */
        private const val TOP_SATELLITES = 4
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "sampleGnss" -> {
                val durationMs = (call.argument<Int>("durationMs") ?: 6000).toLong()
                sampleGnss(durationMs, result)
            }
            else -> result.notImplemented()
        }
    }

    @SuppressLint("MissingPermission") // checked explicitly below
    private fun sampleGnss(durationMs: Long, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            result.success(mapOf("status" to "unsupported"))
            return
        }
        if (context.packageManager.checkPermission(
                Manifest.permission.ACCESS_FINE_LOCATION, context.packageName
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            result.success(mapOf("status" to "permissionDenied"))
            return
        }
        val locationManager =
            context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (locationManager == null ||
            !locationManager.allProviders.contains(LocationManager.GPS_PROVIDER)
        ) {
            result.success(mapOf("status" to "unsupported"))
            return
        }
        if (!locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
            result.success(mapOf("status" to "gpsDisabled"))
            return
        }

        val mainLooper = Looper.getMainLooper()
        val handler = Handler(mainLooper)
        var callbacks = 0
        var maxUsed = 0
        var maxVisible = 0
        var bestTopCn0: Double? = null

        val statusCallback = object : GnssStatus.Callback() {
            override fun onSatelliteStatusChanged(status: GnssStatus) {
                callbacks++
                var used = 0
                val cn0s = ArrayList<Float>(status.satelliteCount)
                for (i in 0 until status.satelliteCount) {
                    if (status.usedInFix(i)) used++
                    // 0 means "tracked but no signal measured".
                    val cn0 = status.getCn0DbHz(i)
                    if (cn0 > 0f) cn0s.add(cn0)
                }
                maxUsed = maxOf(maxUsed, used)
                maxVisible = maxOf(maxVisible, cn0s.size)
                if (cn0s.isNotEmpty()) {
                    cn0s.sortDescending()
                    val top = cn0s.take(TOP_SATELLITES).average()
                    bestTopCn0 = maxOf(bestTopCn0 ?: top, top)
                }
            }
        }
        // Only here to keep the GPS engine running; fixes are ignored.
        val locationListener = object : LocationListener {
            override fun onLocationChanged(location: Location) {}
            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
            @Deprecated("Required on API < 29")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
        }

        try {
            locationManager.registerGnssStatusCallback(statusCallback, handler)
            locationManager.requestLocationUpdates(
                LocationManager.GPS_PROVIDER, 1000L, 0f, locationListener, mainLooper
            )
        } catch (e: SecurityException) {
            locationManager.unregisterGnssStatusCallback(statusCallback)
            result.success(mapOf("status" to "permissionDenied"))
            return
        }

        handler.postDelayed({
            locationManager.removeUpdates(locationListener)
            locationManager.unregisterGnssStatusCallback(statusCallback)
            result.success(
                mapOf(
                    "status" to if (callbacks == 0) "noData" else "ok",
                    "satellitesUsed" to maxUsed,
                    "satellitesVisible" to maxVisible,
                    "topCn0DbHz" to bestTopCn0,
                    "sampleSeconds" to durationMs / 1000.0,
                )
            )
        }, durationMs)
    }
}

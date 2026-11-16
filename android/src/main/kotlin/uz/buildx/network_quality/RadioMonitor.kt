package uz.buildx.network_quality

import android.Manifest
import android.annotation.SuppressLint
import android.annotation.TargetApi
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import android.telephony.CellIdentityGsm
import android.telephony.CellIdentityLte
import android.telephony.CellIdentityNr
import android.telephony.CellIdentityWcdma
import android.telephony.CellInfo
import android.telephony.CellInfoGsm
import android.telephony.CellInfoLte
import android.telephony.CellInfoNr
import android.telephony.CellInfoWcdma
import android.telephony.PhoneStateListener
import android.telephony.ServiceState
import android.telephony.TelephonyCallback
import android.telephony.TelephonyDisplayInfo
import android.telephony.TelephonyManager

/**
 * Listens to the radio for as long as the app process lives, so a reading
 * can report what happened *between* readings, not just a snapshot:
 * handovers, time spent on each generation, and time out of service.
 *
 * Also the only source of the "real" network type: 5G NSA rides on an LTE
 * anchor, so getDataNetworkType() says LTE, and only TelephonyDisplayInfo
 * (a callback, not a getter) says NR_NSA.
 *
 * [ensureStarted] is called on every collection and re-registers when
 * permissions change - the first launch grants them after this starts.
 * Uses TelephonyCallback on API 31+ and PhoneStateListener below it.
 * Every entry point runs on the main thread.
 */
@SuppressLint("MissingPermission") // permissions checked in desiredMode()
object RadioMonitor {

    /** Bucket names, matching the backend's secondsOn* fields. */
    private const val BUCKET_OUT_OF_SERVICE = "outOfService"

    private var telephonyManager: TelephonyManager? = null
    private var context: Context? = null

    /** 0 = not listening, 1 = without cell info, 2 = with cell info. */
    private var mode = 0
    private var callback: Any? = null

    // Latest known state.
    private var serviceState: Int? = null
    private var networkType: Int = TelephonyManager.NETWORK_TYPE_UNKNOWN
    private var overrideType: Int? = null
    private var cellBandwidthsKhz: IntArray? = null
    private var servingCellKey: String? = null

    // Accumulators since the last [takeStats].
    private var windowStart = SystemClock.elapsedRealtime()
    private var bucketStart = windowStart
    private var currentBucket: String? = null
    private val secondsPerBucket = HashMap<String, Double>()
    private var handovers = 0

    fun ensureStarted(appContext: Context) {
        if (context == null) {
            context = appContext.applicationContext
            telephonyManager =
                appContext.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        }
        val tm = telephonyManager ?: return
        val wanted = desiredMode()
        if (wanted == mode) return
        unregister(tm)
        if (wanted == 0) return
        try {
            register(tm, withCellInfo = wanted == 2)
            mode = wanted
        } catch (e: SecurityException) {
            mode = 0
        }
    }

    private fun desiredMode(): Int {
        val ctx = context ?: return 0
        fun granted(p: String) =
            ctx.packageManager.checkPermission(p, ctx.packageName) == PackageManager.PERMISSION_GRANTED
        if (!granted(Manifest.permission.READ_PHONE_STATE)) return 0
        return if (granted(Manifest.permission.ACCESS_FINE_LOCATION)) 2 else 1
    }

    @Suppress("DEPRECATION") // PhoneStateListener is the pre-31 path
    private fun register(tm: TelephonyManager, withCellInfo: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val cb = if (withCellInfo) FullCallback() else BaseCallback()
            tm.registerTelephonyCallback(context!!.mainExecutor, cb)
            callback = cb
        } else {
            val listener = LegacyListener()
            var events = PhoneStateListener.LISTEN_SERVICE_STATE or
                PhoneStateListener.LISTEN_DATA_CONNECTION_STATE
            if (withCellInfo) events = events or PhoneStateListener.LISTEN_CELL_INFO
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                events = events or PhoneStateListener.LISTEN_DISPLAY_INFO_CHANGED
            }
            @Suppress("DEPRECATION")
            tm.listen(listener, events)
            callback = listener
        }
    }

    @Suppress("DEPRECATION") // PhoneStateListener is the pre-31 path
    private fun unregister(tm: TelephonyManager) {
        val cb = callback ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && cb is TelephonyCallback) {
            tm.unregisterTelephonyCallback(cb)
        } else if (cb is PhoneStateListener) {
            @Suppress("DEPRECATION")
            tm.listen(cb, PhoneStateListener.LISTEN_NONE)
        }
        callback = null
        mode = 0
    }

    // ------------------------------------------------------------ events

    private fun onServiceState(state: ServiceState) {
        serviceState = state.state
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            cellBandwidthsKhz = state.cellBandwidths
        }
        updateBucket()
    }

    private fun onNetworkType(type: Int) {
        networkType = type
        updateBucket()
    }

    private fun onDisplayInfo(type: Int) {
        overrideType = type
        updateBucket()
    }

    private fun onCellInfo(cells: List<CellInfo>?) {
        val key = cells?.firstOrNull { it.isRegistered }?.let { identityKey(it) } ?: return
        val previous = servingCellKey
        if (previous != null && previous != key) handovers++
        servingCellKey = key
    }

    /** Time spent so far goes to the bucket we were in, then switch. */
    private fun updateBucket() {
        val now = SystemClock.elapsedRealtime()
        currentBucket?.let { addSeconds(it, now - bucketStart) }
        bucketStart = now
        currentBucket = bucketFor()
    }

    private fun addSeconds(bucket: String, millis: Long) {
        secondsPerBucket[bucket] = (secondsPerBucket[bucket] ?: 0.0) + millis / 1000.0
    }

    private fun bucketFor(): String? {
        val state = serviceState
        if (state != null && state != ServiceState.STATE_IN_SERVICE) return BUCKET_OUT_OF_SERVICE
        // 5G NSA and 5G Advanced report LTE as the network type.
        if (overrideType == 3 || overrideType == 4 || overrideType == 5) return "5g"
        return when (generationOf(networkType)) {
            "g2" -> "2g"
            "g3" -> "3g"
            "g4" -> "4g"
            "g5" -> "5g"
            else -> null
        }
    }

    // ------------------------------------------------------------ reads

    /** Current service state as a backend enum value, or null if unknown. */
    fun serviceStateName(): String? = when (serviceState) {
        ServiceState.STATE_IN_SERVICE -> "inService"
        ServiceState.STATE_OUT_OF_SERVICE -> "outOfService"
        ServiceState.STATE_EMERGENCY_ONLY -> "emergencyOnly"
        ServiceState.STATE_POWER_OFF -> "powerOff"
        else -> null
    }

    /** TelephonyDisplayInfo override type, or null before API 30 / first callback. */
    fun overrideNetworkTypeName(): String? = when (overrideType) {
        0 -> "none"
        1 -> "lteCa"
        2 -> "lteAdvancedPro"
        3 -> "nrNsa"
        4 -> "nrNsaMmwave"
        5 -> "nrAdvanced"
        else -> null
    }

    fun cellBandwidthsKhz(): IntArray? = cellBandwidthsKhz

    /**
     * Stats since the previous call (or since listening began), then
     * resets the window. Null when not listening at all.
     */
    fun takeStats(): Map<String, Any?>? {
        if (mode == 0) return null
        val now = SystemClock.elapsedRealtime()
        currentBucket?.let { addSeconds(it, now - bucketStart) }
        fun bucket(name: String) = secondsPerBucket[name] ?: 0.0
        val stats = mapOf(
            "windowSeconds" to (now - windowStart) / 1000.0,
            // Handovers need cell info, which needs precise location.
            "handoverCount" to if (mode == 2) handovers else null,
            "secondsOn2g" to bucket("2g"),
            "secondsOn3g" to bucket("3g"),
            "secondsOn4g" to bucket("4g"),
            "secondsOn5g" to bucket("5g"),
            "secondsOutOfService" to bucket(BUCKET_OUT_OF_SERVICE),
        )
        windowStart = now
        bucketStart = now
        secondsPerBucket.clear()
        handovers = 0
        return stats
    }

    // ------------------------------------------------------------ helpers

    private fun identityKey(cell: CellInfo): String? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && cell is CellInfoNr) {
            val id = cell.cellIdentity as? CellIdentityNr ?: return null
            return "nr:${id.nci}:${id.pci}"
        }
        return when (cell) {
            is CellInfoLte -> cell.cellIdentity.let { id: CellIdentityLte -> "lte:${id.ci}:${id.pci}" }
            is CellInfoWcdma -> cell.cellIdentity.let { id: CellIdentityWcdma -> "wcdma:${id.cid}:${id.psc}" }
            is CellInfoGsm -> cell.cellIdentity.let { id: CellIdentityGsm -> "gsm:${id.cid}:${id.lac}" }
            else -> null
        }
    }

    /** Same mapping as ConnectivityChannelHandler's generation field. */
    fun generationOf(type: Int): String = when (type) {
        TelephonyManager.NETWORK_TYPE_GPRS,
        TelephonyManager.NETWORK_TYPE_EDGE,
        TelephonyManager.NETWORK_TYPE_GSM,
        @Suppress("DEPRECATION") TelephonyManager.NETWORK_TYPE_CDMA,
        @Suppress("DEPRECATION") TelephonyManager.NETWORK_TYPE_1xRTT -> "g2"
        TelephonyManager.NETWORK_TYPE_UMTS,
        TelephonyManager.NETWORK_TYPE_HSDPA,
        TelephonyManager.NETWORK_TYPE_HSUPA,
        TelephonyManager.NETWORK_TYPE_HSPA,
        TelephonyManager.NETWORK_TYPE_HSPAP,
        TelephonyManager.NETWORK_TYPE_TD_SCDMA,
        @Suppress("DEPRECATION") TelephonyManager.NETWORK_TYPE_EVDO_0,
        @Suppress("DEPRECATION") TelephonyManager.NETWORK_TYPE_EVDO_A,
        @Suppress("DEPRECATION") TelephonyManager.NETWORK_TYPE_EVDO_B,
        @Suppress("DEPRECATION") TelephonyManager.NETWORK_TYPE_EHRPD -> "g3"
        TelephonyManager.NETWORK_TYPE_LTE, 19 /* LTE_CA */ -> "g4"
        TelephonyManager.NETWORK_TYPE_NR -> "g5"
        else -> "unknown"
    }

    // ------------------------------------------------------------ adapters

    @TargetApi(Build.VERSION_CODES.S)
    private open class BaseCallback : TelephonyCallback(),
        TelephonyCallback.ServiceStateListener,
        TelephonyCallback.DataConnectionStateListener,
        TelephonyCallback.DisplayInfoListener {
        override fun onServiceStateChanged(serviceState: ServiceState) = onServiceState(serviceState)
        override fun onDataConnectionStateChanged(state: Int, networkType: Int) = onNetworkType(networkType)
        override fun onDisplayInfoChanged(telephonyDisplayInfo: TelephonyDisplayInfo) =
            onDisplayInfo(telephonyDisplayInfo.overrideNetworkType)
    }

    @TargetApi(Build.VERSION_CODES.S)
    private class FullCallback : BaseCallback(), TelephonyCallback.CellInfoListener {
        override fun onCellInfoChanged(cellInfo: MutableList<CellInfo>) = onCellInfo(cellInfo)
    }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    private class LegacyListener : PhoneStateListener() {
        override fun onServiceStateChanged(serviceState: ServiceState?) {
            serviceState?.let { onServiceState(it) }
        }
        override fun onDataConnectionStateChanged(state: Int, networkType: Int) = onNetworkType(networkType)
        override fun onDisplayInfoChanged(telephonyDisplayInfo: TelephonyDisplayInfo) =
            onDisplayInfo(telephonyDisplayInfo.overrideNetworkType)
        override fun onCellInfoChanged(cellInfo: MutableList<CellInfo>?) = onCellInfo(cellInfo)
    }
}

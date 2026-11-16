package uz.buildx.network_quality

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.CellInfo
import android.telephony.CellInfoGsm
import android.telephony.CellInfoLte
import android.telephony.CellInfoNr
import android.telephony.CellInfoWcdma
import android.telephony.CellSignalStrengthNr
import android.telephony.CellIdentityNr
import android.telephony.TelephonyManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Handles the "network_quality/cellular" MethodChannel: raw cellular radio
 * metrics via TelephonyManager, since no well-maintained pub.dev plugin
 * exposes the full CellInfo API (RSRP/RSRQ/CQI/PCI/etc).
 *
 * Requires ACCESS_FINE_LOCATION + READ_PHONE_STATE. Degrades to an empty
 * result (rather than throwing) when permissions are missing, since this
 * module doesn't request permissions on its own - see
 * NetworkQualityService.requestPermissions() on the Dart side.
 *
 * On API 29+ this uses requestCellInfoUpdate() to force a fresh radio
 * reading, since getAllCellInfo() can return data cached from up to
 * several seconds ago. Older API levels fall back to getAllCellInfo().
 *
 * Many of the per-technology signal getters (LTE rsrp/rsrq/rssnr/cqi,
 * timing advance) only became public API in level 26, and this app's
 * minSdk is 21, so those are guarded by explicit Build.VERSION checks and
 * reported as null on older devices.
 */
class CellularChannelHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "network_quality/cellular"

        /** Cap on neighbouring cells reported, to bound payload size. */
        private const val MAX_NEIGHBORS = 16

        /** Fields kept for a neighbouring cell; the rest describe the serving cell only. */
        private val NEIGHBOR_KEYS = setOf(
            "technology", "cellId", "pci", "arfcn", "band",
            "rssi", "rsrp", "rsrq", "rscp", "rssnr", "signalLevel",
        )

        /** CellInfo.UNAVAILABLE (API 29+) - a compile-time constant equal to Int.MAX_VALUE. */
        private const val UNAVAILABLE_INT = Int.MAX_VALUE
        private const val UNAVAILABLE_LONG = Long.MAX_VALUE
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getCellularInfo" -> {
                RadioMonitor.ensureStarted(context)
                getCellularInfo(result)
            }
            "getRadioStats" -> {
                RadioMonitor.ensureStarted(context)
                result.success(RadioMonitor.takeStats())
            }
            else -> result.notImplemented()
        }
    }

    private fun hasPermissions(): Boolean {
        return isGranted(Manifest.permission.ACCESS_FINE_LOCATION) &&
            isGranted(Manifest.permission.READ_PHONE_STATE)
    }

    /**
     * Uses PackageManager rather than androidx's ContextCompat so this
     * handler carries no dependency beyond the Android framework itself,
     * keeping it easy to lift into a standalone plugin later.
     */
    private fun isGranted(permission: String): Boolean {
        return context.packageManager.checkPermission(
            permission, context.packageName
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun getCellularInfo(result: MethodChannel.Result) {
        if (!hasPermissions()) {
            result.success(emptyMap<String, Any?>())
            return
        }

        val telephonyManager =
            context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        if (telephonyManager == null) {
            result.success(emptyMap<String, Any?>())
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            requestFreshCellInfo(telephonyManager, result)
        } else {
            result.success(readCachedCellInfo(telephonyManager))
        }
    }

    /**
     * API 29+: ask the modem for a fresh reading. Falls back to the cached
     * getAllCellInfo() list if the update yields nothing. [result] is
     * answered exactly once, always on the main thread.
     */
    private fun requestFreshCellInfo(
        telephonyManager: TelephonyManager,
        result: MethodChannel.Result,
    ) {
        val replied = java.util.concurrent.atomic.AtomicBoolean(false)
        val mainHandler = Handler(Looper.getMainLooper())

        fun reply(payload: Map<String, Any?>) {
            if (replied.compareAndSet(false, true)) {
                mainHandler.post { result.success(payload) }
            }
        }

        try {
            telephonyManager.requestCellInfoUpdate(
                context.mainExecutor,
                object : TelephonyManager.CellInfoCallback() {
                    override fun onCellInfo(cellInfo: MutableList<CellInfo>) {
                        reply(
                            buildPayload(cellInfo)
                                ?: readCachedCellInfo(telephonyManager)
                        )
                    }

                    override fun onError(errorCode: Int, detail: Throwable?) {
                        reply(readCachedCellInfo(telephonyManager))
                    }
                }
            )
        } catch (e: SecurityException) {
            reply(emptyMap())
        }
    }

    private fun readCachedCellInfo(telephonyManager: TelephonyManager): Map<String, Any?> {
        return try {
            buildPayload(telephonyManager.allCellInfo ?: emptyList()) ?: emptyMap()
        } catch (e: SecurityException) {
            emptyMap()
        }
    }

    /**
     * The serving cell's fields plus `neighborCells`: every other cell the
     * modem reports, trimmed to [NEIGHBOR_KEYS]. Neighbours usually carry
     * only PCI, channel and signal - the network doesn't broadcast their
     * full cell ID. Null when the list is empty.
     */
    private fun buildPayload(cells: List<CellInfo>): Map<String, Any?>? {
        val serving = pickCell(cells) ?: return null
        val neighbors = cells.asSequence()
            .filter { it !== serving }
            .take(MAX_NEIGHBORS)
            .map { cell -> parseCellInfo(cell).filter { (k, v) -> k in NEIGHBOR_KEYS && v != null } }
            .filter { it.size > 1 } // more than just "technology"
            .toList()
        return parseCellInfo(serving) + ("neighborCells" to neighbors)
    }

    /** Prefer the cell we're actually registered on; otherwise take whatever is first. */
    private fun pickCell(cellInfoList: List<CellInfo>): CellInfo? {
        return cellInfoList.firstOrNull { it.isRegistered } ?: cellInfoList.firstOrNull()
    }

    private fun parseCellInfo(cellInfo: CellInfo): Map<String, Any?> {
        val isRegistered = cellInfo.isRegistered

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && cellInfo is CellInfoNr) {
            val signal = cellInfo.cellSignalStrength as? CellSignalStrengthNr
            val identity = cellInfo.cellIdentity as? CellIdentityNr
            return mapOf(
                // NR reports SS-RSRP/RSRQ/SINR; there is no plain RSSI or CQI
                // equivalent exposed for 5G NR.
                "rssi" to null,
                "rsrp" to signal?.ssRsrp?.let { safeInt(it) },
                "rsrq" to signal?.ssRsrq?.let { safeInt(it) },
                "rssnr" to signal?.ssSinr?.let { safeInt(it) },
                "cqi" to null,
                "asuLevel" to signal?.asuLevel?.let { safeInt(it) },
                "signalLevel" to signal?.level,
                "cellId" to identity?.nci?.let { safeLong(it) },
                "pci" to identity?.pci?.let { safeInt(it) },
                "lac" to null,
                "tac" to identity?.tac?.let { safeInt(it) },
                "timingAdvance" to null,
                "isRegistered" to isRegistered,
                "technology" to "nr",
                "arfcn" to identity?.nrarfcn?.let { safeInt(it) },
                "band" to bandOf(identity),
                "csiRsrp" to signal?.csiRsrp?.let { safeInt(it) },
                "csiRsrq" to signal?.csiRsrq?.let { safeInt(it) },
                "csiSinr" to signal?.csiSinr?.let { safeInt(it) },
            )
        }

        return when (cellInfo) {
            is CellInfoLte -> {
                val signal = cellInfo.cellSignalStrength
                val identity = cellInfo.cellIdentity
                // getRsrp/getRsrq/getRssnr/getCqi/getTimingAdvance became
                // public API only in level 26 (minSdk here is 21).
                val detailed = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                mapOf(
                    // getDbm() is RSRP on LTE, so real RSSI needs getRssi()
                    // (level 29). Older devices report null rather than RSRP.
                    "rssi" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        safeInt(signal.rssi)
                    } else null,
                    "rsrp" to if (detailed) safeInt(signal.rsrp) else null,
                    "rsrq" to if (detailed) safeInt(signal.rsrq) else null,
                    "rssnr" to if (detailed) safeInt(signal.rssnr) else null,
                    "cqi" to if (detailed) safeInt(signal.cqi) else null,
                    "asuLevel" to safeInt(signal.asuLevel),
                    "signalLevel" to signal.level,
                    "cellId" to safeInt(identity.ci),
                    "pci" to safeInt(identity.pci),
                    "lac" to null,
                    "tac" to safeInt(identity.tac),
                    "timingAdvance" to if (detailed) safeInt(signal.timingAdvance) else null,
                    "isRegistered" to isRegistered,
                    "technology" to "lte",
                    "arfcn" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        safeInt(identity.earfcn)
                    } else null,
                    "band" to bandOf(identity),
                    "bandwidthKhz" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        safeInt(identity.bandwidth)
                    } else null,
                )
            }

            is CellInfoWcdma -> {
                val signal = cellInfo.cellSignalStrength
                val identity = cellInfo.cellIdentity
                mapOf(
                    // getDbm() is RSCP on WCDMA, not RSSI - reported as such.
                    "rssi" to null,
                    "rscp" to safeInt(signal.dbm),
                    "rsrp" to null,
                    "rsrq" to null,
                    "rssnr" to null,
                    "cqi" to null,
                    "asuLevel" to safeInt(signal.asuLevel),
                    "signalLevel" to signal.level,
                    "cellId" to safeInt(identity.cid),
                    // WCDMA has no PCI; the primary scrambling code is its
                    // closest analogue, so it lands in the same field.
                    "pci" to safeInt(identity.psc),
                    "lac" to safeInt(identity.lac),
                    "tac" to null,
                    "timingAdvance" to null,
                    "isRegistered" to isRegistered,
                    "technology" to "wcdma",
                    "arfcn" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        safeInt(identity.uarfcn)
                    } else null,
                    "band" to bandOf(identity),
                )
            }

            is CellInfoGsm -> {
                val signal = cellInfo.cellSignalStrength
                val identity = cellInfo.cellIdentity
                // CellSignalStrengthGsm.getTimingAdvance() is public from level 26.
                val timingAdvance = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    safeInt(signal.timingAdvance)
                } else null
                mapOf(
                    "rssi" to safeInt(signal.dbm),
                    "rsrp" to null,
                    "rsrq" to null,
                    "rssnr" to null,
                    "cqi" to null,
                    "asuLevel" to safeInt(signal.asuLevel),
                    "signalLevel" to signal.level,
                    "cellId" to safeInt(identity.cid),
                    "pci" to null,
                    "lac" to safeInt(identity.lac),
                    "tac" to null,
                    "timingAdvance" to timingAdvance,
                    "isRegistered" to isRegistered,
                    "technology" to "gsm",
                    "arfcn" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        safeInt(identity.arfcn)
                    } else null,
                    "band" to bandOf(identity),
                )
            }

            // CDMA and any future subclass: only the registration flag is
            // meaningful without technology-specific parsing.
            else -> mapOf("isRegistered" to isRegistered, "technology" to "other")
        }
    }

    /**
     * First operating band an LTE/NR identity reports (3GPP band number,
     * e.g. 3 for LTE B3 / 1800 MHz). getBands() is level 30; null before
     * that, and always null for WCDMA/GSM.
     */
    private fun bandOf(identity: Any?): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val bands = when (identity) {
            is android.telephony.CellIdentityLte -> identity.bands
            is android.telephony.CellIdentityNr -> identity.bands
            // WCDMA and GSM identities expose no band list.
            else -> null
        }
        return bands?.firstOrNull()
    }

    /** Android reports "no value" as Int.MAX_VALUE (CellInfo.UNAVAILABLE). */
    private fun safeInt(value: Int): Int? {
        return if (value == UNAVAILABLE_INT) null else value
    }

    private fun safeLong(value: Long): Long? {
        return if (value == UNAVAILABLE_LONG) null else value
    }
}

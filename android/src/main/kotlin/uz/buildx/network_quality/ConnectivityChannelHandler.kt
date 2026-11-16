package uz.buildx.network_quality

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.telephony.SubscriptionManager
import java.net.Inet4Address
import java.net.Inet6Address
import android.os.Build
import android.provider.Settings
import android.telephony.TelephonyManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Handles the "network_quality/connectivity" MethodChannel: the
 * connectivity/telephony fields that `connectivity_plus` doesn't expose -
 * VPN active, metered, airplane mode, data roaming, carrier name, MCC/MNC,
 * cellular generation, and data network type.
 *
 * Telephony fields require READ_PHONE_STATE and degrade to null (rather
 * than throwing) when it's missing. VPN detection needs the
 * NetworkCapabilities API (level 23) and is null below that - the Dart
 * side falls back to connectivity_plus's own VPN signal there.
 */
class ConnectivityChannelHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "network_quality/connectivity"

        /** TelephonyManager.NETWORK_TYPE_LTE_CA - hidden constant, public value is stable. */
        private const val NETWORK_TYPE_LTE_CA = 19
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getConnectivityExtras" -> {
                RadioMonitor.ensureStarted(context)
                result.success(
                    getConnectivityExtras() + serviceExtras() + networkExtras() + simExtras()
                )
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Uses PackageManager rather than androidx's ContextCompat so this
     * handler carries no dependency beyond the Android framework itself.
     */
    private fun hasReadPhoneState(): Boolean {
        return context.packageManager.checkPermission(
            Manifest.permission.READ_PHONE_STATE, context.packageName
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun getConnectivityExtras(): Map<String, Any?> {
        val connectivityManager =
            context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val telephonyManager =
            context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager

        val isVpnActive = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            connectivityManager?.let { cm ->
                val network = cm.activeNetwork ?: return@let null
                val capabilities = cm.getNetworkCapabilities(network) ?: return@let null
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            }
        } else null

        val isMetered = connectivityManager?.isActiveNetworkMetered

        val isAirplaneModeOn = try {
            Settings.Global.getInt(
                context.contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0
            ) != 0
        } catch (e: Exception) {
            null
        }

        var isDataRoaming: Boolean? = null
        var carrierName: String? = null
        var mcc: String? = null
        var mnc: String? = null
        var cellularGeneration: String? = null
        var dataNetworkType: String? = null

        if (telephonyManager != null && hasReadPhoneState()) {
            try {
                isDataRoaming = telephonyManager.isNetworkRoaming
                carrierName = telephonyManager.networkOperatorName?.takeIf { it.isNotBlank() }

                // networkOperator is MCC (3 digits) + MNC (2-3 digits), and is
                // empty when not registered on a cellular network.
                val networkOperator = telephonyManager.networkOperator
                if (networkOperator != null && networkOperator.length >= 5) {
                    mcc = networkOperator.substring(0, 3)
                    mnc = networkOperator.substring(3)
                }

                // getDataNetworkType() is level 24+; getNetworkType() covers
                // older devices (deprecated at 29, but minSdk here is 21).
                val networkType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    telephonyManager.dataNetworkType
                } else {
                    @Suppress("DEPRECATION")
                    telephonyManager.networkType
                }
                cellularGeneration = generationForNetworkType(networkType)
                dataNetworkType = labelForNetworkType(networkType)
            } catch (e: SecurityException) {
                // Permission revoked between the check above and the call -
                // leave the telephony fields null.
            }
        }

        return mapOf(
            "isVpnActive" to isVpnActive,
            "isMetered" to isMetered,
            "isAirplaneModeOn" to isAirplaneModeOn,
            "isDataRoaming" to isDataRoaming,
            "carrierName" to carrierName,
            "mcc" to mcc,
            "mnc" to mnc,
            "cellularGeneration" to cellularGeneration,
            "dataNetworkType" to dataNetworkType,
        )
    }

    /**
     * Registration state, the "real" network type (5G NSA shows as LTE
     * otherwise), and carrier aggregation. Service state is read directly
     * where possible (level 26+) and from [RadioMonitor] otherwise; the
     * display type only exists as a callback, so it is null until the
     * monitor's first one arrives.
     */
    private fun serviceExtras(): Map<String, Any?> {
        val telephonyManager =
            context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        var state = RadioMonitor.serviceStateName()
        var bandwidths = RadioMonitor.cellBandwidthsKhz()
        if (telephonyManager != null && hasReadPhoneState() &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        ) {
            try {
                telephonyManager.serviceState?.let { serviceState ->
                    state = when (serviceState.state) {
                        android.telephony.ServiceState.STATE_IN_SERVICE -> "inService"
                        android.telephony.ServiceState.STATE_OUT_OF_SERVICE -> "outOfService"
                        android.telephony.ServiceState.STATE_EMERGENCY_ONLY -> "emergencyOnly"
                        android.telephony.ServiceState.STATE_POWER_OFF -> "powerOff"
                        else -> state
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        bandwidths = serviceState.cellBandwidths
                    }
                }
            } catch (e: SecurityException) {
                // Location-gated on level 29+; keep the monitor's value.
            }
        }
        val channels = bandwidths?.filter { it > 0 }
        return mapOf(
            "serviceState" to state,
            "overrideNetworkType" to RadioMonitor.overrideNetworkTypeName(),
            "aggregatedChannelCount" to channels?.size?.takeIf { it > 0 },
            "aggregatedBandwidthKhz" to channels?.sum()?.takeIf { it > 0 },
        )
    }

    /**
     * What the active network can actually do: internet validated (no
     * captive portal), congestion, the OS's own bandwidth estimate (free -
     * no test traffic), MTU, IP versions, private DNS and data saver.
     */
    private fun networkExtras(): Map<String, Any?> {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        if (cm == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return emptyMap()
        val network = cm.activeNetwork ?: return emptyMap()
        val caps = cm.getNetworkCapabilities(network)
        val link = cm.getLinkProperties(network)
        val addresses = link?.linkAddresses?.map { it.address }.orEmpty()
        return mapOf(
            "isValidated" to caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
            "isCaptivePortal" to caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL),
            "isCongested" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_CONGESTED)?.not()
            } else null,
            "estimatedDownstreamKbps" to caps?.linkDownstreamBandwidthKbps?.takeIf { it > 0 },
            "estimatedUpstreamKbps" to caps?.linkUpstreamBandwidthKbps?.takeIf { it > 0 },
            "mtu" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                link?.mtu?.takeIf { it > 0 }
            } else null,
            "hasIpv4" to link?.let { addresses.any { it is Inet4Address } },
            // Link-local fe80:: addresses exist on every interface; only a
            // routable one means IPv6 actually works.
            "hasIpv6" to link?.let {
                addresses.any { it is Inet6Address && !it.isLinkLocalAddress }
            },
            "isPrivateDnsActive" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                link?.isPrivateDnsActive
            } else null,
            "isLowDataMode" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                cm.restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED
            } else null,
        )
    }

    /**
     * Dual SIM: how many SIMs are active, which slot carries data, and the
     * other SIM's operator. Never reads ICCID or phone number, which
     * SubscriptionInfo also exposes.
     */
    private fun simExtras(): Map<String, Any?> {
        if (!hasReadPhoneState()) return emptyMap()
        val sm = context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE)
            as? SubscriptionManager ?: return emptyMap()
        return try {
            val subs = sm.activeSubscriptionInfoList.orEmpty()
            val dataSubId = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                SubscriptionManager.getDefaultDataSubscriptionId()
            } else null
            val dataSub = subs.firstOrNull { it.subscriptionId == dataSubId }
            val other = subs.firstOrNull { it.subscriptionId != dataSubId }
                ?.takeIf { subs.size > 1 }
            mapOf(
                "activeSimCount" to subs.size,
                "dataSimSlot" to dataSub?.simSlotIndex,
                "otherSimCarrierName" to other?.carrierName?.toString()?.takeIf { it.isNotBlank() },
                "otherSimMcc" to other?.let { mccOf(it) },
                "otherSimMnc" to other?.let { mncOf(it) },
            )
        } catch (e: SecurityException) {
            emptyMap()
        }
    }

    private fun mccOf(info: android.telephony.SubscriptionInfo): String? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) info.mccString
        else @Suppress("DEPRECATION") info.mcc.takeIf { it > 0 }?.let { "%03d".format(it) }

    /** Pre-29 the MNC is an int, so "04" and "004" can't be told apart; assume 2 digits. */
    private fun mncOf(info: android.telephony.SubscriptionInfo): String? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) info.mncString
        else @Suppress("DEPRECATION") info.mnc.takeIf { it >= 0 }?.let { "%02d".format(it) }

    /** Maps TelephonyManager.NETWORK_TYPE_* to our Dart DataNetworkType enum names. */
    private fun labelForNetworkType(networkType: Int): String {
        return when (networkType) {
            TelephonyManager.NETWORK_TYPE_GPRS -> "gprs"
            TelephonyManager.NETWORK_TYPE_EDGE -> "edge"
            TelephonyManager.NETWORK_TYPE_UMTS -> "umts"
            TelephonyManager.NETWORK_TYPE_HSDPA -> "hsdpa"
            TelephonyManager.NETWORK_TYPE_HSUPA -> "hsupa"
            TelephonyManager.NETWORK_TYPE_HSPA -> "hspa"
            TelephonyManager.NETWORK_TYPE_HSPAP -> "hspap"
            TelephonyManager.NETWORK_TYPE_CDMA -> "cdma"
            TelephonyManager.NETWORK_TYPE_EVDO_0 -> "evdo0"
            TelephonyManager.NETWORK_TYPE_EVDO_A -> "evdoA"
            TelephonyManager.NETWORK_TYPE_EVDO_B -> "evdoB"
            TelephonyManager.NETWORK_TYPE_EHRPD -> "ehrpd"
            TelephonyManager.NETWORK_TYPE_LTE -> "lte"
            NETWORK_TYPE_LTE_CA -> "lteCa"
            TelephonyManager.NETWORK_TYPE_NR -> "nr"
            TelephonyManager.NETWORK_TYPE_GSM -> "gsm"
            TelephonyManager.NETWORK_TYPE_TD_SCDMA -> "tdScdma"
            TelephonyManager.NETWORK_TYPE_IWLAN -> "iwlan"
            else -> "unknown"
        }
    }

    private fun generationForNetworkType(networkType: Int): String {
        return when (networkType) {
            TelephonyManager.NETWORK_TYPE_GPRS,
            TelephonyManager.NETWORK_TYPE_EDGE,
            TelephonyManager.NETWORK_TYPE_CDMA,
            TelephonyManager.NETWORK_TYPE_1xRTT,
            TelephonyManager.NETWORK_TYPE_IDEN,
            TelephonyManager.NETWORK_TYPE_GSM -> "g2"

            TelephonyManager.NETWORK_TYPE_UMTS,
            TelephonyManager.NETWORK_TYPE_EVDO_0,
            TelephonyManager.NETWORK_TYPE_EVDO_A,
            TelephonyManager.NETWORK_TYPE_EVDO_B,
            TelephonyManager.NETWORK_TYPE_HSDPA,
            TelephonyManager.NETWORK_TYPE_HSUPA,
            TelephonyManager.NETWORK_TYPE_HSPA,
            TelephonyManager.NETWORK_TYPE_HSPAP,
            TelephonyManager.NETWORK_TYPE_EHRPD,
            TelephonyManager.NETWORK_TYPE_TD_SCDMA -> "g3"

            TelephonyManager.NETWORK_TYPE_LTE,
            NETWORK_TYPE_LTE_CA,
            TelephonyManager.NETWORK_TYPE_IWLAN -> "g4"

            TelephonyManager.NETWORK_TYPE_NR -> "g5"

            else -> "unknown"
        }
    }
}

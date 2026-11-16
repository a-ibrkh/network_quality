package uz.buildx.network_quality

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Handles the "network_quality/permissions" MethodChannel: requesting and
 * inspecting ACCESS_FINE_LOCATION + READ_PHONE_STATE, both of which Android
 * requires before getAllCellInfo() will return anything.
 *
 * Hand-rolled rather than delegating to a permissions plugin because these
 * are the only permissions the module needs and they are Android-only; a
 * cross-platform plugin would add a dependency for consumers of the
 * extracted SDK and compile in iOS permission APIs that are never used.
 *
 * [activity] must be set for requests to work (the OS dialog needs an
 * Activity) and cleared when that Activity is destroyed, to avoid leaking
 * it. Permission *checks* work without one.
 */
class PermissionChannelHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "network_quality/permissions"

        /** Arbitrary but must not collide with other request codes in the host app. */
        const val REQUEST_CODE = 8531

        private const val KEY_FINE_LOCATION = "fineLocation"
        private const val KEY_PHONE_STATE = "phoneState"

        private const val GRANTED = "granted"
        private const val DENIED = "denied"
        private const val PERMANENTLY_DENIED = "permanentlyDenied"

        private val REQUIRED_PERMISSIONS = arrayOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.READ_PHONE_STATE,
        )
    }

    var activity: Activity? = null

    /** Non-null only while an OS permission dialog is awaiting an answer. */
    private var pendingResult: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkPermissions" -> result.success(currentStatuses())
            "requestPermissions" -> requestPermissions(result)
            "openAppSettings" -> result.success(openAppSettings())
            else -> result.notImplemented()
        }
    }

    /**
     * Current state without prompting. Cannot report PERMANENTLY_DENIED:
     * Android only distinguishes it via shouldShowRequestPermissionRationale,
     * which returns false both for "never asked" and for "don't ask again",
     * so reporting it here would flag a fresh install as permanently denied.
     */
    private fun currentStatuses(): Map<String, String> {
        return REQUIRED_PERMISSIONS.associate { permission ->
            keyFor(permission) to if (isGranted(permission)) GRANTED else DENIED
        }
    }

    private fun requestPermissions(result: MethodChannel.Result) {
        // Below API 23 permissions are granted at install time.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            REQUIRED_PERMISSIONS.all { isGranted(it) }
        ) {
            result.success(currentStatuses())
            return
        }

        if (pendingResult != null) {
            result.error(
                "already_requesting",
                "A permission request is already awaiting the user's answer.",
                null,
            )
            return
        }

        val currentActivity = activity
        if (currentActivity == null) {
            result.error(
                "no_activity",
                "No Activity available to host the permission dialog.",
                null,
            )
            return
        }

        pendingResult = result
        currentActivity.requestPermissions(REQUIRED_PERMISSIONS, REQUEST_CODE)
    }

    /**
     * Forwarded from the host Activity's onRequestPermissionsResult.
     * Returns true when this handler consumed the result.
     */
    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE) return false

        val result = pendingResult ?: return true
        pendingResult = null

        val statuses = REQUIRED_PERMISSIONS.associate { permission ->
            val index = permissions.indexOf(permission)
            // An empty grantResults means the dialog was cancelled, which
            // counts as a denial rather than an error.
            val granted = index >= 0 &&
                index < grantResults.size &&
                grantResults[index] == PackageManager.PERMISSION_GRANTED

            keyFor(permission) to if (granted) GRANTED else deniedStateFor(permission)
        }

        result.success(statuses)
        return true
    }

    /**
     * After a request has been answered, shouldShowRequestPermissionRationale
     * is meaningful: false now means the user chose "don't ask again", so no
     * further dialog will ever appear.
     */
    private fun deniedStateFor(permission: String): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return DENIED
        val currentActivity = activity ?: return DENIED
        return if (currentActivity.shouldShowRequestPermissionRationale(permission)) {
            DENIED
        } else {
            PERMANENTLY_DENIED
        }
    }

    /** Opens this app's settings page - the only route out of PERMANENTLY_DENIED. */
    private fun openAppSettings(): Boolean {
        return try {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", context.packageName, null),
            ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun isGranted(permission: String): Boolean {
        return context.packageManager.checkPermission(
            permission, context.packageName
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun keyFor(permission: String): String {
        return when (permission) {
            Manifest.permission.ACCESS_FINE_LOCATION -> KEY_FINE_LOCATION
            Manifest.permission.READ_PHONE_STATE -> KEY_PHONE_STATE
            else -> permission
        }
    }
}

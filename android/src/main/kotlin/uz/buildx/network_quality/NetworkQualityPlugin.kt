package uz.buildx.network_quality

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Registers the network_quality method channels with the Flutter engine.
 *
 * Activity-aware because the permission prompt needs an Activity to show
 * on, and the OS delivers its answer to that Activity's
 * onRequestPermissionsResult - which this plugin listens to via the
 * binding, so host apps need no MainActivity changes.
 */
class NetworkQualityPlugin : FlutterPlugin, ActivityAware {

    private val channels = mutableListOf<MethodChannel>()
    private var permissionHandler: PermissionChannelHandler? = null
    private var activityBinding: ActivityPluginBinding? = null

    private val permissionResultListener =
        PluginRegistry.RequestPermissionsResultListener { requestCode, permissions, grantResults ->
            // False for any request code that isn't ours, so other plugins
            // still get their answers.
            permissionHandler?.onRequestPermissionsResult(
                requestCode, permissions, grantResults
            ) == true
        }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        val messenger = binding.binaryMessenger

        fun register(name: String, handler: MethodChannel.MethodCallHandler) {
            channels += MethodChannel(messenger, name).apply { setMethodCallHandler(handler) }
        }

        register(CellularChannelHandler.CHANNEL_NAME, CellularChannelHandler(context))
        register(ConnectivityChannelHandler.CHANNEL_NAME, ConnectivityChannelHandler(context))
        register(GnssChannelHandler.CHANNEL_NAME, GnssChannelHandler(context))
        register(ContextChannelHandler.CHANNEL_NAME, ContextChannelHandler(context))
        val permissions = PermissionChannelHandler(context)
        permissionHandler = permissions
        register(PermissionChannelHandler.CHANNEL_NAME, permissions)

        // Start listening to the radio now, so handovers and time per
        // technology cover the time before the first reading. A no-op until
        // permissions are granted; collectors call it again after that.
        RadioMonitor.ensureStarted(context)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channels.forEach { it.setMethodCallHandler(null) }
        channels.clear()
        permissionHandler = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        permissionHandler?.activity = binding.activity
        binding.addRequestPermissionsResultListener(permissionResultListener)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(permissionResultListener)
        activityBinding = null
        // Drop the Activity reference so the handler can't leak it.
        permissionHandler?.activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
}

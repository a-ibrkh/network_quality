import 'package:flutter/services.dart';

import '../models/cellular_info.dart';
import '../models/radio_stats.dart';

/// Android-only collector for raw cellular radio metrics.
///
/// Backed by a native MethodChannel that calls
/// `TelephonyManager.getAllCellInfo()` / `requestCellInfoUpdate()` in
/// Kotlin (see `android/app/src/main/kotlin/.../networkquality/CellularChannelHandler.kt`),
/// because no well-maintained pub.dev plugin exposes the full `CellInfo`
/// API (RSRP/RSRQ/CQI/PCI/etc). Requires `READ_PHONE_STATE` and
/// `ACCESS_FINE_LOCATION` permissions to return non-null values; without
/// them this degrades gracefully to an empty [CellularInfo].
///
/// There is no iOS equivalent of this collector - see
/// `CellularCollectorIos` for the iOS stub.
class CellularCollector {
  static const MethodChannel _channel = MethodChannel('network_quality/cellular');

  /// Handovers and time per technology since the previous call, then
  /// resets. Null when the radio isn't being listened to (no phone-state
  /// permission). See `RadioMonitor.kt`.
  Future<RadioStats?> takeRadioStats() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('getRadioStats');
      if (result == null) return null;
      return RadioStats.fromJson({
        ...result,
        'timestamp': DateTime.now().toIso8601String(),
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<CellularInfo> collect() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('getCellularInfo');
      if (result == null) {
        return CellularInfo(timestamp: DateTime.now());
      }
      // Same keys as the wire format, so the model's own parser applies.
      return CellularInfo.fromJson({
        ...result,
        'timestamp': DateTime.now().toIso8601String(),
      });
    } on PlatformException {
      // e.g. missing permissions, or no cell info currently available.
      return CellularInfo(timestamp: DateTime.now());
    } on MissingPluginException {
      return CellularInfo(timestamp: DateTime.now());
    }
  }
}

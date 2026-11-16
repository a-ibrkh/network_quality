import 'package:flutter/services.dart';

import '../models/cellular_info.dart';

/// iOS-only stub collector for cellular radio info.
///
/// iOS has no public API exposing signal-strength metrics (RSRP, RSSI,
/// RSRQ, SINR, CQI, ASU, cell/PCI/LAC/TAC identifiers, timing advance).
/// Apple does not surface `CTCellularData`/`CoreTelephony` equivalents of
/// Android's `CellInfo`, so all of those fields are permanently `null` on
/// this platform - this is a platform limitation, not a TODO.
///
/// The only thing available is a coarse radio access technology label via
/// `CTTelephonyNetworkInfo.serviceCurrentRadioAccessTechnology`, fetched
/// through a MethodChannel to a small native shim in
/// `ios/Runner/AppDelegate.swift`. That label is `null` when the device
/// isn't on cellular at all.
class CellularCollectorIos {
  static const MethodChannel _channel = MethodChannel('network_quality/cellular_ios');

  Future<CellularInfo> collect() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('getRadioAccessTechnology');
      return CellularInfo(
        radioAccessTechnology: result?['radioAccessTechnology'] as String?,
        timestamp: DateTime.now(),
      );
    } on PlatformException {
      return CellularInfo(timestamp: DateTime.now());
    } on MissingPluginException {
      // Native shim absent (e.g. running on a platform other than iOS).
      return CellularInfo(timestamp: DateTime.now());
    }
  }
}

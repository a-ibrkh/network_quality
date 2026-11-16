import 'dart:io';

import 'package:flutter/services.dart';

import '../models/gnss_info.dart';

/// Samples satellite visibility as an indoor/outdoor hint.
///
/// Android-only, backed by a native MethodChannel (see
/// `android/app/src/main/kotlin/.../networkquality/GnssChannelHandler.kt`):
/// the location plugin exposes positions but not satellite status. iOS has
/// no public GNSS status API, so it always reports
/// [GnssSampleStatus.unsupported].
///
/// [collect] turns GPS on for [duration], so it takes that long and costs
/// a little battery. Never throws.
class GnssCollector {
  static const MethodChannel _channel = MethodChannel('network_quality/gnss');

  const GnssCollector();

  Future<GnssInfo> collect({Duration duration = const Duration(seconds: 6)}) async {
    if (!Platform.isAndroid) {
      return GnssInfo.unavailable(
        status: GnssSampleStatus.unsupported,
        timestamp: DateTime.now(),
      );
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'sampleGnss',
        {'durationMs': duration.inMilliseconds},
      );
      if (result == null) {
        return GnssInfo.unavailable(
          status: GnssSampleStatus.noData,
          timestamp: DateTime.now(),
        );
      }
      return GnssInfo.fromJson({...result, 'timestamp': DateTime.now().toIso8601String()});
    } on PlatformException {
      return GnssInfo.unavailable(
        status: GnssSampleStatus.noData,
        timestamp: DateTime.now(),
      );
    } on MissingPluginException {
      return GnssInfo.unavailable(
        status: GnssSampleStatus.unsupported,
        timestamp: DateTime.now(),
      );
    }
  }
}

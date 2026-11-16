import 'dart:io';

import 'package:flutter/services.dart';

import '../models/environment_info.dart';

/// Samples ambient light, motion and Wi-Fi counts over a window, as
/// indoor/outdoor and moving/still hints.
///
/// Android: `ContextChannelHandler.kt` (light, accelerometer, Wi-Fi scan
/// counts). iOS: device motion only, via `AppDelegate.swift` - iOS has no
/// public light sensor or Wi-Fi scan API. Takes [collect]'s `duration`.
/// Never throws.
class EnvironmentCollector {
  static const MethodChannel _androidChannel = MethodChannel('network_quality/context');
  static const MethodChannel _iosChannel = MethodChannel('network_quality/context_ios');

  const EnvironmentCollector();

  Future<EnvironmentInfo?> collect({Duration duration = const Duration(seconds: 6)}) async {
    final channel = Platform.isAndroid
        ? _androidChannel
        : Platform.isIOS
            ? _iosChannel
            : null;
    if (channel == null) return null;
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'sampleEnvironment',
        {'durationMs': duration.inMilliseconds},
      );
      if (result == null) return null;
      return EnvironmentInfo.fromJson({
        ...result,
        'timestamp': DateTime.now().toIso8601String(),
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

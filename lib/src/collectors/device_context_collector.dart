import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../models/device_context.dart';

/// Collects [DeviceContext]: battery state via `battery_plus`, device
/// model/OS version via `device_info_plus`, and app foreground/background
/// state via `WidgetsBinding`'s current `AppLifecycleState`.
class DeviceContextCollector {
  static const MethodChannel _androidChannel = MethodChannel('network_quality/context');
  static const MethodChannel _iosChannel = MethodChannel('network_quality/context_ios');

  final Battery _battery;
  final DeviceInfoPlugin _deviceInfo;

  DeviceContextCollector({Battery? battery, DeviceInfoPlugin? deviceInfo})
      : _battery = battery ?? Battery(),
        _deviceInfo = deviceInfo ?? DeviceInfoPlugin();

  Future<DeviceContext> collect() async {
    final batteryLevel = await _safeBatteryLevel();
    final isCharging = await _safeChargingState();
    final deviceModel = await _safeDeviceModel();
    final osVersion = await _safeOsVersion();
    final extras = await _safeExtras();

    return DeviceContext(
      batteryLevel: batteryLevel,
      isCharging: isCharging,
      deviceModel: deviceModel,
      osVersion: osVersion,
      isAppInForeground: _isAppInForeground(),
      isPowerSaveMode: extras['isPowerSaveMode'] as bool?,
      thermalStatus: extras['thermalStatus'] as String?,
      timestamp: DateTime.now(),
    );
  }

  /// Battery saver and thermal status, from the native "context" channels.
  Future<Map<String, dynamic>> _safeExtras() async {
    final channel = Platform.isAndroid
        ? _androidChannel
        : Platform.isIOS
            ? _iosChannel
            : null;
    if (channel == null) return const {};
    try {
      return await channel.invokeMapMethod<String, dynamic>('getDeviceExtras') ??
          const {};
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }

  bool _isAppInForeground() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  Future<int?> _safeBatteryLevel() async {
    try {
      return await _battery.batteryLevel;
    } catch (_) {
      return null;
    }
  }

  Future<bool?> _safeChargingState() async {
    try {
      final state = await _battery.batteryState;
      return state == BatteryState.charging || state == BatteryState.full;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _safeDeviceModel() async {
    try {
      if (Platform.isAndroid) {
        final info = await _deviceInfo.androidInfo;
        return info.model;
      } else if (Platform.isIOS) {
        final info = await _deviceInfo.iosInfo;
        return info.utsname.machine;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _safeOsVersion() async {
    try {
      if (Platform.isAndroid) {
        final info = await _deviceInfo.androidInfo;
        return 'Android ${info.version.release}';
      } else if (Platform.isIOS) {
        final info = await _deviceInfo.iosInfo;
        return 'iOS ${info.systemVersion}';
      }
      return Platform.operatingSystemVersion;
    } catch (_) {
      return null;
    }
  }
}

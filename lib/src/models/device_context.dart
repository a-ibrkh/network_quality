import 'wire_privacy.dart';

/// Device/system context surrounding a measurement: battery, device
/// identity, and app lifecycle state. Populated by `DeviceContextCollector`.
class DeviceContext {
  /// Battery level, 0-100.
  final int? batteryLevel;

  final bool? isCharging;

  /// e.g. "Pixel 7", "iPhone14,5".
  final String? deviceModel;

  /// e.g. "Android 14", "iOS 17.4".
  final String? osVersion;

  final bool isAppInForeground;

  /// Battery saver (Android) / Low Power Mode (iOS) is on. Both throttle the modem.
  final bool? isPowerSaveMode;

  /// `none`, `light`, `moderate`, `severe`, `critical`, `emergency` or `shutdown` (Android 10+; iOS maps nominal/fair/serious/critical to none/light/severe/critical). Hot phones throttle the modem.
  final String? thermalStatus;

  final DateTime timestamp;

  const DeviceContext({
    this.batteryLevel,
    this.isCharging,
    this.deviceModel,
    this.osVersion,
    this.isPowerSaveMode,
    this.thermalStatus,
    required this.isAppInForeground,
    required this.timestamp,
  });

  factory DeviceContext.fromJson(Map<String, dynamic> json) {
    return DeviceContext(
      batteryLevel: json['batteryLevel'] as int?,
      isCharging: json['isCharging'] as bool?,
      deviceModel: json['deviceModel'] as String?,
      osVersion: json['osVersion'] as String?,
      isAppInForeground: json['isAppInForeground'] as bool? ?? true,
      isPowerSaveMode: json['isPowerSaveMode'] as bool?,
      thermalStatus: json['thermalStatus'] as String?,
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'batteryLevel': batteryLevel,
      'isCharging': isCharging,
      'deviceModel': deviceModel,
      'osVersion': osVersion,
      'isAppInForeground': isAppInForeground,
      'isPowerSaveMode': isPowerSaveMode,
      'thermalStatus': thermalStatus,
      'timestamp': wireTimestamp(timestamp),
    };
  }
}

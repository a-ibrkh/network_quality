import 'wire_privacy.dart';

/// Moving/still reading of the motion hints.
enum MotionHint { still, moving, inVehicle, unknown }

/// Sensor and Wi-Fi hints sampled over a short window, alongside GNSS:
/// indoor/outdoor (light, Wi-Fi) and moving/still (accelerometer).
///
/// Wi-Fi is counts and the strongest signal only - never network names or
/// BSSIDs, which identify places as precisely as GPS.
class EnvironmentInfo {
  /// Brightest ambient light in the window, in lux. Daylight outdoors is
  /// typically over 1,000; indoor lighting 100-500. Android only.
  final double? ambientLux;

  /// Standard deviation of acceleration magnitude, in m/s². Still is
  /// around 0.05 or less; walking is typically over 1.
  final double? accelStdDevMps2;

  /// Wi-Fi networks in the OS's latest scan (last 2 minutes). Android only;
  /// null when Wi-Fi scanning is off or precise location isn't granted.
  final int? wifiNetworksVisible;

  /// Strongest Wi-Fi signal in that scan, in dBm.
  final int? wifiStrongestRssiDbm;

  /// How long sensors were sampled, in seconds.
  final double? sampleSeconds;

  final DateTime timestamp;

  const EnvironmentInfo({
    this.ambientLux,
    this.accelStdDevMps2,
    this.wifiNetworksVisible,
    this.wifiStrongestRssiDbm,
    this.sampleSeconds,
    required this.timestamp,
  });

  /// Thresholds behind [motionHint]; on-device display only.
  static const double stillMaxStdDev = 0.3;
  static const double vehicleMinSpeedMps = 7;

  /// Still / moving from the accelerometer; in a vehicle when GPS speed
  /// ([speedMps], from `LocationInfo`) is above walking pace.
  MotionHint motionHint({double? speedMps}) {
    if (speedMps != null && speedMps >= vehicleMinSpeedMps) {
      return MotionHint.inVehicle;
    }
    final spread = accelStdDevMps2;
    if (spread == null) return MotionHint.unknown;
    return spread <= stillMaxStdDev ? MotionHint.still : MotionHint.moving;
  }

  static double? _d(Object? v) => (v as num?)?.toDouble();

  factory EnvironmentInfo.fromJson(Map<String, dynamic> json) {
    return EnvironmentInfo(
      ambientLux: _d(json['ambientLux']),
      accelStdDevMps2: _d(json['accelStdDevMps2']),
      wifiNetworksVisible: json['wifiNetworksVisible'] as int?,
      wifiStrongestRssiDbm: json['wifiStrongestRssiDbm'] as int?,
      sampleSeconds: _d(json['sampleSeconds']),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'ambientLux': ambientLux,
      'accelStdDevMps2': accelStdDevMps2,
      'wifiNetworksVisible': wifiNetworksVisible,
      'wifiStrongestRssiDbm': wifiStrongestRssiDbm,
      'sampleSeconds': sampleSeconds,
      'timestamp': wireTimestamp(timestamp),
    };
  }
}

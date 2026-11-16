import 'cellular_info.dart';
import 'connectivity_info.dart';
import 'device_context.dart';
import 'environment_info.dart';
import 'gnss_info.dart';
import 'location_info.dart';
import 'radio_stats.dart';
import 'wire_privacy.dart';

/// Combined result of `NetworkQualityService.collectSnapshot()`: all
/// passive/instant data gathered in one pass, tagged with a [sessionId] so
/// it can later be correlated with `ActiveMeasurement` results and sent to
/// a backend.
/// Timestamps are serialized as UTC (`toUtc()`) throughout the module.
/// `DateTime.now()` is local, and `toIso8601String()` on a local DateTime
/// emits no `Z` suffix - a server parsing that as UTC lands every record
/// hours away from when it happened.
class NetworkQualitySnapshot {
  final String sessionId;
  final DateTime timestamp;
  final ConnectivityInfo connectivityInfo;

  /// `null` when no cellular radio data was available (e.g. on Wi-Fi, or
  /// on iOS where only [CellularInfo.radioAccessTechnology] is populated).
  final CellularInfo? cellularInfo;
  final DeviceContext deviceContext;

  /// Where the device was, so radio metrics can be mapped geographically.
  ///
  /// Never null: when no fix is available the record still explains why
  /// via `LocationInfo.status`, which is more useful downstream than an
  /// absent object.
  final LocationInfo locationInfo;

  /// Satellite visibility, as an indoor/outdoor hint. Null when sampling
  /// was disabled, and in reports queued before this field existed.
  final GnssInfo? gnssInfo;

  /// Light, motion and Wi-Fi-count hints. Null when sampling was disabled,
  /// unsupported, and in older queued reports.
  final EnvironmentInfo? environmentInfo;

  /// Handovers and time per technology since the previous reading.
  /// Android only; null without phone-state permission.
  final RadioStats? radioStats;

  const NetworkQualitySnapshot({
    required this.sessionId,
    required this.timestamp,
    required this.connectivityInfo,
    this.cellularInfo,
    required this.deviceContext,
    required this.locationInfo,
    this.gnssInfo,
    this.environmentInfo,
    this.radioStats,
  });

  factory NetworkQualitySnapshot.fromJson(Map<String, dynamic> json) {
    return NetworkQualitySnapshot(
      sessionId: json['sessionId'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      connectivityInfo: ConnectivityInfo.fromJson(
        json['connectivityInfo'] as Map<String, dynamic>,
      ),
      cellularInfo: json['cellularInfo'] == null
          ? null
          : CellularInfo.fromJson(json['cellularInfo'] as Map<String, dynamic>),
      deviceContext: DeviceContext.fromJson(
        json['deviceContext'] as Map<String, dynamic>,
      ),
      locationInfo: LocationInfo.fromJson(
        json['locationInfo'] as Map<String, dynamic>,
      ),
      gnssInfo: json['gnssInfo'] == null
          ? null
          : GnssInfo.fromJson(json['gnssInfo'] as Map<String, dynamic>),
      environmentInfo: json['environmentInfo'] == null
          ? null
          : EnvironmentInfo.fromJson(
              json['environmentInfo'] as Map<String, dynamic>),
      radioStats: json['radioStats'] == null
          ? null
          : RadioStats.fromJson(json['radioStats'] as Map<String, dynamic>),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'timestamp': wireTimestamp(timestamp),
      'connectivityInfo': connectivityInfo.toJson(),
      'cellularInfo': cellularInfo?.toJson(),
      'deviceContext': deviceContext.toJson(),
      'locationInfo': locationInfo.toJson(),
      'gnssInfo': gnssInfo?.toJson(),
      'environmentInfo': environmentInfo?.toJson(),
      'radioStats': radioStats?.toJson(),
    };
  }
}

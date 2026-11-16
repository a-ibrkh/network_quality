import 'wire_privacy.dart';

/// Outcome of a GNSS sampling window.
enum GnssSampleStatus {
  /// The window ran and satellite status was received.
  ok,

  /// The GPS engine ran but reported nothing within the window.
  noData,

  /// No precise-location grant. Android withholds GNSS status from an
  /// approximate-only grant.
  permissionDenied,

  /// The GPS provider is switched off.
  gpsDisabled,

  /// No GNSS status API on this platform (iOS, Android < 7).
  unsupported;

  static GnssSampleStatus fromName(String? name) =>
      GnssSampleStatus.values.firstWhere(
        (e) => e.name == name,
        orElse: () => GnssSampleStatus.unsupported,
      );
}

/// Which side of indoor/outdoor the GNSS hints lean towards.
enum EnvironmentHint { likelyOutdoors, inBetween, likelyIndoors, unknown }

/// Satellite visibility over a short window, as raw hints for whether a
/// reading was taken indoors or outdoors.
///
/// Only the raw values are sent; the server decides the label, so the
/// thresholds can change without an app release. [environmentHint] is the
/// same rule applied on-device for display.
class GnssInfo {
  final GnssSampleStatus status;

  /// Most satellites used in a position fix at any point in the window.
  /// Can stay 0 for several seconds even outdoors while the engine starts.
  final int? satellitesUsed;

  /// Most satellites received with a measurable signal.
  final int? satellitesVisible;

  /// Mean carrier-to-noise density of the 4 strongest satellites, in
  /// dB-Hz - the best value seen in the window. Open sky is typically
  /// 35-45, indoors below 25.
  final double? topCn0DbHz;

  /// How long the GPS engine was listened to, in seconds.
  final double? sampleSeconds;

  final DateTime timestamp;

  const GnssInfo({
    required this.status,
    this.satellitesUsed,
    this.satellitesVisible,
    this.topCn0DbHz,
    this.sampleSeconds,
    required this.timestamp,
  });

  const GnssInfo.unavailable({required this.status, required this.timestamp})
      : satellitesUsed = null,
        satellitesVisible = null,
        topCn0DbHz = null,
        sampleSeconds = null;

  /// Thresholds behind [environmentHint]. Tuned from published typical
  /// values, not from this app's own data - revisit once there is some.
  static const double outdoorCn0DbHz = 33;
  static const double indoorCn0DbHz = 25;
  static const int outdoorMinVisible = 6;
  static const int indoorMaxVisible = 3;

  EnvironmentHint get environmentHint {
    if (status == GnssSampleStatus.noData) return EnvironmentHint.likelyIndoors;
    if (status != GnssSampleStatus.ok) return EnvironmentHint.unknown;
    final visible = satellitesVisible ?? 0;
    final cn0 = topCn0DbHz;
    if (cn0 == null || visible <= indoorMaxVisible || cn0 < indoorCn0DbHz) {
      return EnvironmentHint.likelyIndoors;
    }
    if (visible >= outdoorMinVisible && cn0 >= outdoorCn0DbHz) {
      return EnvironmentHint.likelyOutdoors;
    }
    return EnvironmentHint.inBetween;
  }

  factory GnssInfo.fromJson(Map<String, dynamic> json) {
    return GnssInfo(
      status: GnssSampleStatus.fromName(json['status'] as String?),
      satellitesUsed: json['satellitesUsed'] as int?,
      satellitesVisible: json['satellitesVisible'] as int?,
      topCn0DbHz: (json['topCn0DbHz'] as num?)?.toDouble(),
      sampleSeconds: (json['sampleSeconds'] as num?)?.toDouble(),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'status': status.name,
      'satellitesUsed': satellitesUsed,
      'satellitesVisible': satellitesVisible,
      'topCn0DbHz': topCn0DbHz,
      'sampleSeconds': sampleSeconds,
      'timestamp': wireTimestamp(timestamp),
    };
  }
}

import 'wire_privacy.dart';

/// Why a location fix is or isn't present on a [LocationInfo].
///
/// Sent alongside the coordinates so a consumer can tell "the user is
/// somewhere we couldn't determine" from "the user declined location" -
/// both produce null coordinates but mean very different things for
/// coverage analysis.
enum LocationStatus {
  /// Coordinates are present.
  available,

  /// Denied, but the OS will prompt again if asked.
  permissionDenied,

  /// Denied with "don't ask again" / "never" - no further prompt appears.
  permissionPermanentlyDenied,

  /// Location services are switched off device-wide.
  servicesDisabled,

  /// Permission held and services on, but no fix was obtainable (no
  /// last-known position yet, or a fresh fix timed out).
  unavailable,

  /// Collection was not attempted.
  notCollected;

  static LocationStatus fromName(String? name) {
    return LocationStatus.values.firstWhere(
      (e) => e.name == name,
      orElse: () => LocationStatus.notCollected,
    );
  }
}

/// A geographic fix captured alongside a network measurement, so radio
/// metrics can be mapped geographically.
///
/// Every coordinate field is null unless [status] is
/// [LocationStatus.available].
class LocationInfo {
  final LocationStatus status;

  final double? latitude;
  final double? longitude;

  /// Horizontal accuracy radius in metres. Large values mean a coarse fix
  /// (network/cell-derived rather than GPS) - Android 12+ lets users grant
  /// approximate-only location, which typically lands around 1-3 km.
  /// Filter on this before treating a point as precise.
  final double? accuracyMeters;

  final double? altitudeMeters;

  /// Ground speed in metres/second. Useful for separating stationary
  /// readings from drive-test data.
  final double? speedMps;

  /// Heading in degrees clockwise from true north.
  final double? headingDegrees;

  /// Whether the OS reported this as a mock/simulated location.
  ///
  /// Worth keeping: a coverage dataset polluted by spoofed GPS is worse
  /// than one with gaps, so these points should be excluded server-side.
  final bool? isMocked;

  /// When the fix itself was taken, which is **not** the same as
  /// [timestamp]. The default collection path uses the OS's last-known
  /// position, so a fix can be minutes old; compare the two to get its age
  /// before trusting it.
  final DateTime? fixTimestamp;

  /// When this record was assembled.
  final DateTime timestamp;

  const LocationInfo({
    required this.status,
    this.latitude,
    this.longitude,
    this.accuracyMeters,
    this.altitudeMeters,
    this.speedMps,
    this.headingDegrees,
    this.isMocked,
    this.fixTimestamp,
    required this.timestamp,
  });

  /// A record carrying no fix, explaining why via [status].
  LocationInfo.unavailable({
    required this.status,
    required this.timestamp,
  })  : latitude = null,
        longitude = null,
        accuracyMeters = null,
        altitudeMeters = null,
        speedMps = null,
        headingDegrees = null,
        isMocked = null,
        fixTimestamp = null;

  bool get hasFix => latitude != null && longitude != null;

  /// How stale the fix is, or null when there is no fix.
  Duration? get fixAge =>
      fixTimestamp == null ? null : timestamp.difference(fixTimestamp!);

  factory LocationInfo.fromJson(Map<String, dynamic> json) {
    return LocationInfo(
      status: LocationStatus.fromName(json['status'] as String?),
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      accuracyMeters: (json['accuracyMeters'] as num?)?.toDouble(),
      altitudeMeters: (json['altitudeMeters'] as num?)?.toDouble(),
      speedMps: (json['speedMps'] as num?)?.toDouble(),
      headingDegrees: (json['headingDegrees'] as num?)?.toDouble(),
      isMocked: json['isMocked'] as bool?,
      fixTimestamp: json['fixTimestamp'] == null
          ? null
          : DateTime.parse(json['fixTimestamp'] as String),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'status': status.name,
      'latitude': coarsenCoordinate(latitude),
      'longitude': coarsenCoordinate(longitude),
      'accuracyMeters': accuracyMeters,
      'altitudeMeters': altitudeMeters,
      'speedMps': speedMps,
      'headingDegrees': headingDegrees,
      'isMocked': isMocked,
      'fixTimestamp': fixTimestamp == null ? null : wireTimestamp(fixTimestamp!),
      'timestamp': wireTimestamp(timestamp),
    };
  }
}

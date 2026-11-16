import 'package:geolocator/geolocator.dart';

import '../models/location_info.dart';

/// Collects a geographic fix to attach to network measurements.
///
/// Uses `geolocator` rather than the module's own MethodChannels: unlike
/// the cellular metrics, location has a well-maintained cross-platform
/// plugin, and hand-rolling `FusedLocationProviderClient` plus
/// `CLLocationManager` would be a lot of native surface for no gain.
///
/// By default [collect] returns the OS's **last known** position, which is
/// instantaneous and keeps `collectSnapshot()` fast. That fix may be
/// minutes old, so `LocationInfo.fixTimestamp` / `fixAge` are recorded
/// alongside it - always check the age before trusting a point. Pass
/// `forceFresh: true` to wait for a new fix instead.
class LocationCollector {
  /// Accuracy requested when [collect] is called with `forceFresh: true`.
  ///
  /// `medium` rather than `best`: a coverage map doesn't need sub-metre
  /// precision, and lower accuracy settles faster and costs far less
  /// battery - which matters in a module whose own readings include the
  /// battery level.
  static const LocationAccuracy _freshAccuracy = LocationAccuracy.medium;

  const LocationCollector();

  /// Returns the current location, or a [LocationInfo] explaining why one
  /// isn't available. Never throws.
  ///
  /// Does **not** prompt for permission - see [requestPermission]. Callers
  /// that haven't been granted location get
  /// [LocationStatus.permissionDenied] back rather than a dialog appearing
  /// as a side effect of reading data.
  Future<LocationInfo> collect({
    bool forceFresh = false,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final now = DateTime.now();
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return LocationInfo.unavailable(
          status: LocationStatus.servicesDisabled,
          timestamp: now,
        );
      }

      final permission = await Geolocator.checkPermission();
      final permissionStatus = _statusForPermission(permission);
      if (permissionStatus != null) {
        return LocationInfo.unavailable(
          status: permissionStatus,
          timestamp: now,
        );
      }

      final position = forceFresh
          ? await Geolocator.getCurrentPosition(
              locationSettings: LocationSettings(
                accuracy: _freshAccuracy,
                timeLimit: timeout,
              ),
            )
          : await Geolocator.getLastKnownPosition();

      if (position == null) {
        // Permission held and services on, but the OS has no cached fix -
        // common right after boot or a permission grant.
        return LocationInfo.unavailable(
          status: LocationStatus.unavailable,
          timestamp: DateTime.now(),
        );
      }

      return LocationInfo(
        status: LocationStatus.available,
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyMeters: position.accuracy,
        altitudeMeters: position.altitude,
        speedMps: position.speed,
        headingDegrees: position.heading,
        isMocked: position.isMocked,
        fixTimestamp: position.timestamp,
        timestamp: DateTime.now(),
      );
    } catch (_) {
      // Timeouts on a fresh fix, and platform errors, degrade to a status
      // rather than propagating - a missing location must never take down
      // an otherwise good snapshot.
      return LocationInfo.unavailable(
        status: LocationStatus.unavailable,
        timestamp: DateTime.now(),
      );
    }
  }

  /// Prompts for location permission, returning the resulting status.
  ///
  /// Separate from [collect] on purpose, so the host app controls when the
  /// dialog appears. On Android this is the same `ACCESS_FINE_LOCATION`
  /// grant that `CellularCollector` needs for radio metrics, so a single
  /// prompt satisfies both; on iOS it's the only permission this module
  /// asks for.
  Future<LocationStatus> requestPermission() async {
    try {
      final permission = await Geolocator.requestPermission();
      return _statusForPermission(permission) ?? LocationStatus.available;
    } catch (_) {
      return LocationStatus.unavailable;
    }
  }

  /// Maps a geolocator permission to a failure status, or null when the
  /// permission is sufficient to read a position.
  LocationStatus? _statusForPermission(LocationPermission permission) {
    switch (permission) {
      case LocationPermission.denied:
      case LocationPermission.unableToDetermine:
        return LocationStatus.permissionDenied;
      case LocationPermission.deniedForever:
        return LocationStatus.permissionPermanentlyDenied;
      case LocationPermission.whileInUse:
      case LocationPermission.always:
        return null;
    }
  }
}

import 'package:shared_preferences/shared_preferences.dart';

import 'measurement_throttle.dart';

/// Default [MeasurementTimestampStore], backed by `shared_preferences`
/// (SharedPreferences on Android, NSUserDefaults on iOS).
///
/// Persists across app restarts, which the throttle depends on -
/// measurements run at app open, so an in-memory timestamp would reset
/// exactly when it matters.
///
/// Stored as epoch milliseconds rather than a formatted string: no parsing
/// to fail, no timezone ambiguity.
class SharedPreferencesTimestampStore implements MeasurementTimestampStore {
  /// Namespaced so it can't collide with a host app's own preferences.
  static const String storageKey = 'network_quality.last_measurement_at_ms';

  const SharedPreferencesTimestampStore();

  @override
  Future<DateTime?> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final millis = prefs.getInt(storageKey);
      if (millis == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(millis);
    } catch (_) {
      // Storage unavailable - fall back to "never measured" so a broken
      // preferences store can't permanently block measurement.
      return null;
    }
  }

  @override
  Future<void> write(DateTime at) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(storageKey, at.millisecondsSinceEpoch);
    } catch (_) {
      // Losing the timestamp costs an extra measurement next launch, which
      // is preferable to failing the measurement that just succeeded.
    }
  }

  @override
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(storageKey);
    } catch (_) {
      // Nothing useful to do; next read falls back to null anyway.
    }
  }
}

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models/queued_report.dart';
import 'telemetry_queue.dart';

/// Default [TelemetryQueueStore], backed by `shared_preferences`.
///
/// Stores the queue as a list of JSON strings. Adequate for the volumes
/// involved - a device produces at most two reports per measurement, and
/// the queue is capped - but it rewrites the whole list on every change,
/// so a much larger queue would want sqlite instead.
class SharedPreferencesTelemetryQueueStore implements TelemetryQueueStore {
  static const String storageKey = 'network_quality.telemetry_queue';

  const SharedPreferencesTelemetryQueueStore();

  @override
  Future<List<QueuedReport>> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(storageKey) ?? const [];
      final reports = <QueuedReport>[];
      for (final entry in raw) {
        try {
          reports.add(
            QueuedReport.fromJson(jsonDecode(entry) as Map<String, dynamic>),
          );
        } catch (_) {
          // Skip an unparseable entry rather than losing the whole queue -
          // one corrupt record shouldn't discard the others.
          continue;
        }
      }
      return reports;
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> write(List<QueuedReport> reports) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        storageKey,
        [for (final r in reports) jsonEncode(r.toJson())],
      );
    } catch (_) {
      // Storage failure costs us the queued reports, which is no worse
      // than not having a queue; it must not fail the caller.
    }
  }
}

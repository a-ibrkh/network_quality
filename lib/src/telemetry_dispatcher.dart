import 'package:uuid/uuid.dart';

import 'collectors/telemetry_sender.dart';
import 'models/active_measurement.dart';
import 'models/network_quality_snapshot.dart';
import 'models/queued_report.dart';
import 'shared_preferences_telemetry_queue_store.dart';
import 'telemetry_queue.dart';

/// Durable delivery for telemetry: queue first, then send.
///
/// Every report is written to the [TelemetryQueue] *before* a send is
/// attempted, so nothing is lost if the request fails or the process dies
/// mid-flight. Submitting then immediately flushes, which delivers the new
/// report and any backlog in one pass.
///
/// [submitSnapshot] and [submitTestResult] therefore do not throw on a
/// failed send - a failure just means the report stays queued for the next
/// attempt. Use the returned [FlushResult] to see what actually happened.
class TelemetryDispatcher {
  static const _uuid = Uuid();

  final TelemetrySender sender;
  final TelemetryQueue queue;

  TelemetryDispatcher({
    required this.sender,
    TelemetryQueue? queue,
  }) : queue = queue ??
            const TelemetryQueue(SharedPreferencesTelemetryQueueStore());

  Future<FlushResult> submitSnapshot(NetworkQualitySnapshot snapshot) {
    return _submit(TelemetryReportKind.location, snapshot.toJson());
  }

  Future<FlushResult> submitTestResult(ActiveMeasurement result) {
    return _submit(TelemetryReportKind.speedtest, result.toJson());
  }

  /// Delivers whatever is already queued without adding anything.
  ///
  /// Worth calling on connectivity-restored, or at app start before a new
  /// measurement, to drain a backlog left by an earlier bad connection.
  Future<FlushResult> flushPending() => queue.flush(_send);

  Future<int> pendingCount() => queue.pendingCount();

  Future<FlushResult> _submit(
    TelemetryReportKind kind,
    Map<String, dynamic> payload,
  ) async {
    final eventId = _uuid.v4();
    await queue.enqueue(
      QueuedReport(
        eventId: eventId,
        kind: kind,
        // The idempotency key travels inside the payload so a retry is
        // recognisable server-side once the backend supports it.
        payload: {...payload, 'eventId': eventId},
        queuedAt: DateTime.now(),
      ),
    );
    return queue.flush(_send);
  }

  Future<void> _send(QueuedReport report) {
    return switch (report.kind) {
      TelemetryReportKind.location => sender.postLocation(report.payload),
      TelemetryReportKind.speedtest => sender.postSpeedtest(report.payload),
    };
  }
}

import 'models/queued_report.dart';

/// Persists pending reports between app launches.
///
/// Abstracted so the queue's logic carries no plugin dependency and stays
/// unit-testable, and so a host app can substitute its own storage.
abstract class TelemetryQueueStore {
  Future<List<QueuedReport>> read();
  Future<void> write(List<QueuedReport> reports);
}

/// In-memory store. Fine for tests; useless in production, where the whole
/// point is surviving a restart.
class InMemoryTelemetryQueueStore implements TelemetryQueueStore {
  List<QueuedReport> _reports;

  InMemoryTelemetryQueueStore([List<QueuedReport>? initial])
      : _reports = List.of(initial ?? const []);

  @override
  Future<List<QueuedReport>> read() async => List.of(_reports);

  @override
  Future<void> write(List<QueuedReport> reports) async =>
      _reports = List.of(reports);
}

/// Outcome of a [TelemetryQueue.flush].
class FlushResult {
  final int sent;
  final int failed;

  /// Dropped for being too old or having exhausted their attempts.
  final int discarded;

  /// Still queued afterwards, including ones not yet due.
  final int remaining;

  const FlushResult({
    required this.sent,
    required this.failed,
    required this.discarded,
    required this.remaining,
  });

  @override
  String toString() =>
      'FlushResult(sent: $sent, failed: $failed, discarded: $discarded, '
      'remaining: $remaining)';
}

/// A durable, backing-off outbox for telemetry.
///
/// Reports are written to storage *before* any send is attempted and
/// removed only once the backend has accepted them. That ordering is the
/// point: this SDK measures bad connections, so a send failing is the
/// expected path, not the exceptional one, and results must not be lost
/// with it.
class TelemetryQueue {
  /// Reports are dropped past this many failures. A report that has failed
  /// this often is either malformed or describes conditions long gone.
  static const int defaultMaxAttempts = 8;

  /// Reports older than this are dropped unsent - a week-old measurement
  /// describes a network that no longer exists.
  static const Duration defaultMaxAge = Duration(days: 3);

  /// Cap on stored reports, oldest evicted first. Bounds disk use on a
  /// device that has been offline for a long time.
  static const int defaultMaxItems = 100;

  final TelemetryQueueStore store;
  final int maxAttempts;
  final Duration maxAge;
  final int maxItems;

  const TelemetryQueue(
    this.store, {
    this.maxAttempts = defaultMaxAttempts,
    this.maxAge = defaultMaxAge,
    this.maxItems = defaultMaxItems,
  });

  /// Delay before retrying a report that has failed [attempts] times.
  ///
  /// Exponential from 30s, capped at an hour. Pure and static so the curve
  /// can be tested without touching storage.
  static Duration backoffFor(int attempts) {
    if (attempts <= 0) return Duration.zero;
    const base = 30;
    const capSeconds = 3600;
    // Shift rather than pow, and clamp the exponent so a large attempt
    // count can't overflow into a negative or absurd delay.
    final exponent = attempts - 1 > 20 ? 20 : attempts - 1;
    final seconds = base * (1 << exponent);
    return Duration(seconds: seconds > capSeconds ? capSeconds : seconds);
  }

  Future<int> pendingCount() async => (await store.read()).length;

  Future<List<QueuedReport>> pending() => store.read();

  /// Adds a report, evicting the oldest if [maxItems] would be exceeded.
  Future<void> enqueue(QueuedReport report) async {
    final reports = await store.read()..add(report);
    if (reports.length > maxItems) {
      reports.removeRange(0, reports.length - maxItems);
    }
    await store.write(reports);
  }

  /// Attempts delivery of every due report via [send].
  ///
  /// [send] should throw to signal failure. Reports that succeed are
  /// removed; those that fail are kept with an incremented attempt count
  /// and a later [nextAttemptAt]. Reports too old or too often failed are
  /// discarded rather than retried forever.
  Future<FlushResult> flush(
    Future<void> Function(QueuedReport report) send, {
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final reports = await store.read();
    if (reports.isEmpty) {
      return const FlushResult(sent: 0, failed: 0, discarded: 0, remaining: 0);
    }

    final keep = <QueuedReport>[];
    var sent = 0;
    var failed = 0;
    var discarded = 0;

    for (final report in reports) {
      if (at.difference(report.queuedAt) > maxAge) {
        discarded++;
        continue;
      }
      if (!report.isDue(at)) {
        keep.add(report);
        continue;
      }

      try {
        await send(report);
        sent++;
      } catch (_) {
        final next = report.withFailure(
          now: at,
          backoff: backoffFor(report.attempts + 1),
        );
        if (next.attempts >= maxAttempts) {
          discarded++;
        } else {
          failed++;
          keep.add(next);
        }
      }
    }

    await store.write(keep);
    return FlushResult(
      sent: sent,
      failed: failed,
      discarded: discarded,
      remaining: keep.length,
    );
  }

  Future<void> clear() => store.write(const []);
}

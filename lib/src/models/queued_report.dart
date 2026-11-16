/// Which endpoint a queued report is destined for.
enum TelemetryReportKind {
  location,
  speedtest;

  static TelemetryReportKind? fromName(String? name) {
    if (name == null) return null;
    for (final value in TelemetryReportKind.values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// A report waiting to be delivered.
///
/// Stored on device before any send is attempted, so a report survives the
/// process dying mid-request - which, in an SDK that exists to measure bad
/// connections, is the case that matters.
class QueuedReport {
  /// Client-generated idempotency key, sent inside the payload as
  /// `eventId`.
  ///
  /// Stays the same across every retry of this report. The server assigns
  /// its own row id after the fact and so cannot recognise a retry of
  /// something it already stored; without this, a send that times out
  /// *after* the server committed will duplicate on the next attempt. The
  /// live backend ignores the field today - it's sent so the fix is a
  /// server-side change only, with no client release needed.
  final String eventId;

  final TelemetryReportKind kind;
  final Map<String, dynamic> payload;

  /// When the report was first queued - used to discard stale data.
  final DateTime queuedAt;

  /// Failed delivery attempts so far. Drives the backoff.
  final int attempts;

  /// Earliest time the next attempt may run, or null to attempt now.
  final DateTime? nextAttemptAt;

  const QueuedReport({
    required this.eventId,
    required this.kind,
    required this.payload,
    required this.queuedAt,
    this.attempts = 0,
    this.nextAttemptAt,
  });

  /// Whether this report is eligible to be sent at [now].
  bool isDue(DateTime now) {
    final next = nextAttemptAt;
    // A future timestamp means the clock moved backwards; send rather than
    // stall, matching how the measurement throttle handles the same case.
    if (next == null || next.isAfter(now.add(const Duration(days: 1)))) {
      return true;
    }
    return !next.isAfter(now);
  }

  QueuedReport withFailure({
    required DateTime now,
    required Duration backoff,
  }) {
    return QueuedReport(
      eventId: eventId,
      kind: kind,
      payload: payload,
      queuedAt: queuedAt,
      attempts: attempts + 1,
      nextAttemptAt: now.add(backoff),
    );
  }

  factory QueuedReport.fromJson(Map<String, dynamic> json) {
    return QueuedReport(
      eventId: json['eventId'] as String,
      kind: TelemetryReportKind.fromName(json['kind'] as String?) ??
          TelemetryReportKind.location,
      payload: Map<String, dynamic>.from(json['payload'] as Map),
      queuedAt: DateTime.parse(json['queuedAt'] as String),
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      nextAttemptAt: json['nextAttemptAt'] == null
          ? null
          : DateTime.parse(json['nextAttemptAt'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'eventId': eventId,
      'kind': kind.name,
      'payload': payload,
      'queuedAt': queuedAt.toUtc().toIso8601String(),
      'attempts': attempts,
      'nextAttemptAt': nextAttemptAt?.toUtc().toIso8601String(),
    };
  }
}

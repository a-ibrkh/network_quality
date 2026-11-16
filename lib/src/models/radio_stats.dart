import 'wire_privacy.dart';

/// What the radio did *between* readings: handovers and time spent per
/// generation, accumulated by a native listener that runs while the app
/// process lives (Android only - see `RadioMonitor.kt`).
///
/// The window starts at the previous reading, or when listening began
/// (app start, or the moment phone-state permission was granted). Time
/// before the first radio callback, and on Wi-Fi with no cellular data
/// connection, falls in no bucket - so the buckets can sum to less than
/// [windowSeconds].
class RadioStats {
  /// Length of the window, in seconds.
  final double? windowSeconds;

  /// Serving-cell changes in the window. Null without precise location,
  /// which Android requires for cell info.
  final int? handoverCount;

  /// Seconds on each generation. 5G NSA counts as 5G, not 4G.
  final double? secondsOn2g;
  final double? secondsOn3g;
  final double? secondsOn4g;
  final double? secondsOn5g;

  /// Seconds out of service or emergency-calls-only.
  final double? secondsOutOfService;

  final DateTime timestamp;

  const RadioStats({
    this.windowSeconds,
    this.handoverCount,
    this.secondsOn2g,
    this.secondsOn3g,
    this.secondsOn4g,
    this.secondsOn5g,
    this.secondsOutOfService,
    required this.timestamp,
  });

  static double? _d(Object? v) => (v as num?)?.toDouble();

  factory RadioStats.fromJson(Map<String, dynamic> json) {
    return RadioStats(
      windowSeconds: _d(json['windowSeconds']),
      handoverCount: json['handoverCount'] as int?,
      secondsOn2g: _d(json['secondsOn2g']),
      secondsOn3g: _d(json['secondsOn3g']),
      secondsOn4g: _d(json['secondsOn4g']),
      secondsOn5g: _d(json['secondsOn5g']),
      secondsOutOfService: _d(json['secondsOutOfService']),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'windowSeconds': windowSeconds,
      'handoverCount': handoverCount,
      'secondsOn2g': secondsOn2g,
      'secondsOn3g': secondsOn3g,
      'secondsOn4g': secondsOn4g,
      'secondsOn5g': secondsOn5g,
      'secondsOutOfService': secondsOutOfService,
      'timestamp': wireTimestamp(timestamp),
    };
  }
}

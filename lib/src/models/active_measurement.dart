import 'connectivity_info.dart';
import 'wire_privacy.dart';

/// Why an active test produced no measurements.
///
/// `null` on a result means the test actually ran; a non-null value means
/// every metric below is null by design rather than by failure. Without
/// this the backend cannot tell "we measured and the network was
/// unreachable" from "we never measured".
enum MeasurementSkipReason {
  /// The device wasn't on cellular. This SDK exists to characterise the
  /// cellular network, and a throughput figure taken over Wi-Fi or ethernet
  /// measures a different link entirely, so it would corrupt the dataset.
  notCellular,

  /// A measurement already ran inside the cooldown window, so this one was
  /// suppressed. Measurements are triggered by app open, and without this
  /// a user who reopens the app repeatedly would burn their mobile data on
  /// near-duplicate readings. Purely a client-side decision - these
  /// records carry no information about the network and are generally not
  /// worth sending to the backend.
  recentlyMeasured;

  static MeasurementSkipReason? fromName(String? name) {
    if (name == null) return null;
    for (final value in MeasurementSkipReason.values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// Result of an active network measurement pass.
///
/// Every metric is nullable: a measurement can fail on its own without
/// invalidating the rest. [sessionId] ties this result back to the
/// `NetworkQualitySnapshot` it was measured alongside.
///
/// Check [wasSkipped] before treating null metrics as a signal about
/// network conditions.
class ActiveMeasurement {
  final String sessionId;
  final DateTime timestamp;

  /// Connection type at the moment of the test. Recorded even when the
  /// test was skipped, so the backend can see what the device was on.
  final ConnectionType connectionType;

  /// Non-null when the test deliberately did not run - see
  /// [MeasurementSkipReason].
  final MeasurementSkipReason? skipReason;

  /// Download throughput, in Mbps. Measured against Cloudflare.
  final double? downloadMbps;

  /// Upload throughput, in Mbps. Measured against Cloudflare.
  final double? uploadMbps;

  /// Mean RTT in ms, sampled against the backend's ping endpoint.
  final double? latencyMs;

  /// Jitter in ms: mean absolute difference between consecutive RTT
  /// samples from the same run that produced [latencyMs].
  final double? jitterMs;

  /// DNS resolution time, in ms. Implemented via `InternetAddress.lookup`.
  final double? dnsResolutionMs;

  /// TCP connection time, in ms. Implemented via `Socket.connect`.
  final double? tcpConnectionMs;

  /// TLS handshake time, in ms. Implemented via `SecureSocket.connect`.
  final double? tlsHandshakeMs;

  /// Share of latency probes that got no response, in percent (0-100). HTTP requests, not ICMP - a timeout or reset counts as lost.
  final double? packetLossPercent;

  /// Time to first byte, in ms: mean over download requests from sending the request to the first body byte. Includes connection setup for each connection's first request.
  final double? ttfbMs;

  /// Bytes the download test transferred, warmup included - what it cost the user's data plan.
  final int? downloadBytes;

  /// Bytes the upload test transferred and the server acknowledged.
  final int? uploadBytes;

  /// Whether the test deliberately did not run, leaving every metric null.
  bool get wasSkipped => skipReason != null;

  const ActiveMeasurement({
    required this.sessionId,
    required this.timestamp,
    required this.connectionType,
    this.skipReason,
    this.downloadMbps,
    this.uploadMbps,
    this.latencyMs,
    this.jitterMs,
    this.dnsResolutionMs,
    this.tcpConnectionMs,
    this.tlsHandshakeMs,
    this.packetLossPercent,
    this.ttfbMs,
    this.downloadBytes,
    this.uploadBytes,
  });

  factory ActiveMeasurement.fromJson(Map<String, dynamic> json) {
    return ActiveMeasurement(
      sessionId: json['sessionId'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      connectionType: ConnectionType.fromName(json['connectionType'] as String?),
      skipReason: MeasurementSkipReason.fromName(json['skipReason'] as String?),
      downloadMbps: (json['downloadMbps'] as num?)?.toDouble(),
      uploadMbps: (json['uploadMbps'] as num?)?.toDouble(),
      latencyMs: (json['latencyMs'] as num?)?.toDouble(),
      jitterMs: (json['jitterMs'] as num?)?.toDouble(),
      dnsResolutionMs: (json['dnsResolutionMs'] as num?)?.toDouble(),
      tcpConnectionMs: (json['tcpConnectionMs'] as num?)?.toDouble(),
      tlsHandshakeMs: (json['tlsHandshakeMs'] as num?)?.toDouble(),
      packetLossPercent: (json['packetLossPercent'] as num?)?.toDouble(),
      ttfbMs: (json['ttfbMs'] as num?)?.toDouble(),
      downloadBytes: json['downloadBytes'] as int?,
      uploadBytes: json['uploadBytes'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'timestamp': wireTimestamp(timestamp),
      'connectionType': connectionType.name,
      'skipReason': skipReason?.name,
      'downloadMbps': downloadMbps,
      'uploadMbps': uploadMbps,
      'latencyMs': latencyMs,
      'jitterMs': jitterMs,
      'dnsResolutionMs': dnsResolutionMs,
      'tcpConnectionMs': tcpConnectionMs,
      'tlsHandshakeMs': tlsHandshakeMs,
      'packetLossPercent': packetLossPercent,
      'ttfbMs': ttfbMs,
      'downloadBytes': downloadBytes,
      'uploadBytes': uploadBytes,
    };
  }
}

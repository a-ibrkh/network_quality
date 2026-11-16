import 'dart:convert';
import 'dart:io';

import '../http_log.dart';
import '../models/active_measurement.dart';
import '../models/network_quality_config.dart';
import '../models/network_quality_snapshot.dart';

/// Thrown when the backend rejects or fails to accept a report.
class TelemetryException implements Exception {
  final String message;

  /// HTTP status, or null when the request never got a response.
  final int? statusCode;

  /// Response body, truncated. FastAPI returns a useful validation detail
  /// on 422, which is the difference between "schema drifted" and "server
  /// is down" when debugging.
  final String? body;

  TelemetryException(this.message, {this.statusCode, this.body});

  @override
  String toString() => 'TelemetryException($statusCode): $message'
      '${body == null ? '' : ' - $body'}';
}

/// Posts collected data to the backend.
///
/// Both methods **throw** [TelemetryException] on failure rather than
/// swallowing it. Sends are the operation most likely to fail here - this
/// SDK exists to measure bad connections - so the caller has to be able to
/// tell a successful send from a lost one in order to retry.
///
/// This class is the raw transport only. For delivery that survives a
/// failed send, use `TelemetryDispatcher`, which queues to disk first and
/// retries with backoff.
class TelemetrySender {
  final NetworkQualityConfig config;
  final Duration timeout;

  TelemetrySender({required this.config, this.timeout = const Duration(seconds: 15)});

  /// Sends a passive-data snapshot to `POST /api/telemetry/location`.
  ///
  /// The snapshot's JSON is sent as-is; the server ignores the per-section
  /// `timestamp` fields it doesn't model and keys off the top-level one.
  Future<void> sendSnapshot(NetworkQualitySnapshot snapshot) =>
      postLocation(snapshot.toJson());

  /// Sends an active measurement result to `POST /api/telemetry/speedtest`.
  Future<void> sendTestResult(ActiveMeasurement result) =>
      postSpeedtest(result.toJson());

  /// Posts an already-serialized location payload.
  ///
  /// Exists for `TelemetryQueue`, which stores JSON rather than models and
  /// must resend the exact bytes it persisted - re-serializing from a
  /// model would change the timestamps.
  Future<void> postLocation(Map<String, dynamic> payload) =>
      _post(config.locationEndpoint, payload);

  /// Posts an already-serialized speedtest payload. See [postLocation].
  Future<void> postSpeedtest(Map<String, dynamic> payload) =>
      _post(config.speedtestEndpoint, payload);

  Future<void> _post(Uri uri, Map<String, dynamic> payload) async {
    final client = HttpClient()..connectionTimeout = timeout;
    final encoded = jsonEncode(payload);
    final stopwatch = Stopwatch()..start();
    logHttp('→ REQUEST POST $uri\n$encoded');
    try {
      final request = await client.postUrl(uri);
      config.headers.forEach(request.headers.set);
      request.headers.contentType = ContentType.json;
      request.write(encoded);

      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join();
      logHttp('← RESPONSE status=${response.statusCode} POST $uri '
          '(${stopwatch.elapsedMilliseconds} ms)\n${truncateForLog(body)}');

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw TelemetryException(
          'Backend rejected the report',
          statusCode: response.statusCode,
          body: body.length > 500 ? '${body.substring(0, 500)}...' : body,
        );
      }
    } on TelemetryException {
      rethrow;
    } catch (e) {
      // Connection refused, DNS failure, timeout - indistinguishable to the
      // caller, and all mean "not delivered, safe to retry".
      logHttp('✗ POST $uri failed after ${stopwatch.elapsedMilliseconds} ms: $e');
      throw TelemetryException('Failed to reach $uri: $e');
    } finally {
      client.close(force: true);
    }
  }
}

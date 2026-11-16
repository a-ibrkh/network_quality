import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../http_log.dart';
import '../models/network_quality_config.dart';

/// Active/computed network measurements.
///
/// Everything here is implemented. DNS/TCP/TLS timings and both
/// throughput figures need no first-party infrastructure; latency samples
/// the backend's ping endpoint.
///
/// This class deliberately returns raw numbers rather than an
/// `ActiveMeasurement`; `NetworkQualityService.runActiveTest()` assembles
/// the model from whichever of these succeed.
class SpeedTestCollector {
  /// Host used for the DNS/TCP/TLS timing probes below. These measure
  /// generic internet reachability, not our own infrastructure, so any
  /// stable public host works.
  static const String _probeHost = 'example.com';
  static const int _probeTlsPort = 443;

  /// Default download payload, owned by [NetworkQualityConfig] so there is
  /// one source of truth. Overridable per call, and per service instance
  /// via that config.
  ///
  /// HTTPS, so no cleartext exemption is needed.
  static Uri get defaultDownloadEndpoint =>
      NetworkQualityConfig.defaultDownloadEndpoint;

  /// Default upload sink, owned by [NetworkQualityConfig].
  static Uri get defaultUploadEndpoint =>
      NetworkQualityConfig.defaultUploadEndpoint;

  /// Makes each request URL unique; see [_cacheBusted].
  int _cacheBuster = 0;

  /// Bytes actually transferred by the most recent [measureDownloadMbps]
  /// call, including data discarded as warmup. This is what the
  /// measurement cost the user's data allowance, not what was counted
  /// toward the reported rate.
  int lastDownloadBytes = 0;

  /// Bytes uploaded by the most recent [measureUploadMbps] call.
  int lastUploadBytes = 0;

  /// Mean time to first byte over the most recent [measureDownloadMbps]
  /// call's requests, in ms: request sent to first body byte. Null when no
  /// request got that far.
  double? lastTtfbMs;

  /// Share of the most recent [measureLatencySamplesMs] call's probes that
  /// failed (timeout, reset, refused), in percent. Includes the discarded
  /// first probe - a lost packet is lost either way. Null before any run.
  double? lastPacketLossPercent;

  /// Measures DNS resolution time for [hostname], in ms.
  ///
  /// Implemented via `InternetAddress.lookup`; does not require our server.
  Future<double> measureDnsResolutionMs({String hostname = _probeHost}) async {
    final stopwatch = Stopwatch()..start();
    await InternetAddress.lookup(hostname);
    stopwatch.stop();
    return stopwatch.elapsedMicroseconds / 1000;
  }

  /// Measures raw TCP connection (handshake) time to [host]:[port], in ms.
  ///
  /// Implemented via `Socket.connect`; does not require our server.
  Future<double> measureTcpConnectionMs({
    String host = _probeHost,
    int port = 80,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final stopwatch = Stopwatch()..start();
    final socket = await Socket.connect(host, port, timeout: timeout);
    stopwatch.stop();
    await socket.close();
    return stopwatch.elapsedMicroseconds / 1000;
  }

  /// Measures TLS handshake time to [host]:[port] (including the
  /// underlying TCP connect), in ms.
  ///
  /// Implemented via `SecureSocket.connect`; does not require our server.
  Future<double> measureTlsHandshakeMs({
    String host = _probeHost,
    int port = _probeTlsPort,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final stopwatch = Stopwatch()..start();
    final socket = await SecureSocket.connect(host, port, timeout: timeout);
    stopwatch.stop();
    socket.destroy();
    return stopwatch.elapsedMicroseconds / 1000;
  }

  /// Computes jitter (mean absolute difference between consecutive RTT
  /// samples), in ms, from samples gathered by
  /// [measureLatencySamplesMs]. Pure math, no network access.
  double computeJitterMs(List<double> latencySamplesMs) {
    if (latencySamplesMs.length < 2) return 0;
    var sumOfDiffs = 0.0;
    for (var i = 1; i < latencySamplesMs.length; i++) {
      sumOfDiffs += (latencySamplesMs[i] - latencySamplesMs[i - 1]).abs();
    }
    return sumOfDiffs / (latencySamplesMs.length - 1);
  }

  /// Measures download throughput, in Mbps, against [endpoint].
  ///
  /// Runs for [testDuration] using [parallelConnections] concurrent GETs,
  /// stopping early if [maxBytes] is reached. Returns 0 if nothing could be
  /// downloaded.
  ///
  /// Bytes received during [warmup] are excluded from the result. Without
  /// that exclusion TCP slow-start dominates on a short test and the figure
  /// comes out far too low - which matters here because the default file is
  /// only 3 MiB, less than a second of transfer on a fast link.
  ///
  /// Several details are deliberate:
  /// - **Parallel connections.** A single TCP stream frequently fails to
  ///   fill a high-bandwidth path; concurrency is what makes the number
  ///   reflect the link rather than one connection's congestion window.
  /// - **Cache busting.** Each request gets a unique query parameter. The
  ///   server already sends `no-store`, but carrier networks run transparent
  ///   proxies, and a cached response would report a fabricated speed.
  /// - **`autoUncompress = false`.** Measures bytes actually on the wire.
  ///
  /// Note this measures the path to whichever host [endpoint] names, so it
  /// reflects that server's location and capacity as well as the client's
  /// connection.
  Future<double> measureDownloadMbps({
    Uri? endpoint,
    Duration testDuration = const Duration(seconds: 5),
    Duration warmup = const Duration(milliseconds: 500),
    int parallelConnections = 4,
    int maxBytes = 32 * 1024 * 1024,
  }) async {
    final uri = endpoint ?? defaultDownloadEndpoint;
    lastTtfbMs = null;
    final client = HttpClient()..autoUncompress = false;

    var totalBytes = 0;
    var measuredBytes = 0;
    var stopped = false;
    final ttfbsMs = <double>[];
    final stopwatch = Stopwatch()..start();

    bool shouldStop() =>
        stopped || stopwatch.elapsed >= testDuration || totalBytes >= maxBytes;

    Future<void> worker() async {
      while (!shouldStop()) {
        final requestUri = _cacheBusted(uri);
        logHttp('→ REQUEST GET $requestUri');
        final requestStopwatch = Stopwatch()..start();
        final request = await client.getUrl(requestUri);
        final response = await request.close();
        logHttp('← RESPONSE status=${response.statusCode} GET $requestUri '
            '(content-length ${response.contentLength})');
        var firstChunk = true;
        await for (final chunk in response) {
          if (firstChunk) {
            firstChunk = false;
            ttfbsMs.add(requestStopwatch.elapsedMicroseconds / 1000);
          }
          totalBytes += chunk.length;
          // Only traffic after warmup counts toward the reported rate.
          if (stopwatch.elapsed >= warmup) measuredBytes += chunk.length;
          if (shouldStop()) {
            stopped = true;
            break;
          }
        }
      }
    }

    try {
      await Future.wait([
        for (var i = 0; i < parallelConnections; i++) worker(),
      ]);
    } finally {
      stopwatch.stop();
      client.close(force: true);
    }

    lastDownloadBytes = totalBytes;
    lastTtfbMs = ttfbsMs.isEmpty
        ? null
        : ttfbsMs.reduce((a, b) => a + b) / ttfbsMs.length;
    logHttp('download done: $totalBytes bytes in '
        '${stopwatch.elapsedMilliseconds} ms');

    final measuredWindow = stopwatch.elapsed - warmup;
    // If the transfer finished before warmup elapsed there is no post-warmup
    // window to divide by, so fall back to the whole run rather than
    // reporting a bogus zero.
    if (measuredWindow <= Duration.zero || measuredBytes == 0) {
      return _toMbps(totalBytes, stopwatch.elapsed);
    }
    return _toMbps(measuredBytes, measuredWindow);
  }

  double _toMbps(int bytes, Duration elapsed) {
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds <= 0 || bytes <= 0) return 0;
    return (bytes * 8) / seconds / 1000000;
  }

  /// Appends a unique query parameter so no intermediary can serve a cached
  /// response and inflate the measurement.
  Uri _cacheBusted(Uri uri) {
    _cacheBuster++;
    return uri.replace(queryParameters: {
      ...uri.queryParameters,
      '_nq': '${DateTime.now().microsecondsSinceEpoch}_$_cacheBuster',
    });
  }

  /// Measures upload throughput, in Mbps, against [endpoint].
  ///
  /// Repeatedly POSTs a [chunkBytes] body on [parallelConnections]
  /// concurrent requests until [testDuration] elapses or [maxBytes] is
  /// reached. Returns 0 if nothing could be uploaded.
  ///
  /// **Only acknowledged bytes count.** A chunk is added to the total once
  /// the server has responded, never when it is handed to the socket -
  /// writes return as soon as the kernel buffers them, so counting at that
  /// point measures local memory bandwidth and reports absurd speeds. This
  /// is why the endpoint must not reply until it has read the body to EOF.
  ///
  /// Two consequences of counting whole chunks:
  /// - A chunk still in flight when the clock runs out contributes
  ///   nothing, so the result is slightly conservative.
  /// - An in-flight request is allowed to finish rather than being torn
  ///   down, so on a very slow uplink the call can overrun [testDuration].
  ///   That is deliberate: aborting would leave nothing to measure and
  ///   report 0, which reads as "no connection" instead of "slow".
  ///
  /// Unlike the download path there is no warmup exclusion - upload
  /// progress isn't observable at chunk granularity, so subtracting a
  /// window would distort more than it corrects. The figure therefore
  /// includes TCP slow-start and slightly understates a fast uplink; a
  /// larger [chunkBytes] amortises that.
  Future<double> measureUploadMbps({
    Uri? endpoint,
    Duration testDuration = const Duration(seconds: 5),
    int parallelConnections = 3,
    int chunkBytes = 1024 * 1024,
    int maxBytes = 8 * 1024 * 1024,
  }) async {
    final uri = endpoint ?? defaultUploadEndpoint;
    final client = HttpClient();
    final payload = _incompressiblePayload(chunkBytes);

    var acknowledgedBytes = 0;
    // Counts bytes already committed to a request, including in-flight
    // ones. Budgeting against acknowledged bytes instead would let every
    // worker start one last chunk after the cap was reached, overshooting
    // by parallelConnections * chunkBytes - 25% over budget at the
    // defaults, spent from the user's data allowance.
    var committedBytes = 0;
    final stopwatch = Stopwatch()..start();

    bool shouldStop() =>
        stopwatch.elapsed >= testDuration || committedBytes >= maxBytes;

    Future<void> worker() async {
      while (!shouldStop()) {
        committedBytes += payload.length;
        logHttp('→ REQUEST POST $uri (${payload.length} bytes)');
        final request = await client.postUrl(uri);
        request.headers.contentType = ContentType.binary;
        request.contentLength = payload.length;
        request.add(payload);
        final response = await request.close();
        await response.drain<void>();
        logHttp('← RESPONSE status=${response.statusCode} POST $uri');
        // Counted here, after the server acknowledged the whole body.
        acknowledgedBytes += payload.length;
      }
    }

    try {
      await Future.wait([
        for (var i = 0; i < parallelConnections; i++) worker(),
      ]);
    } finally {
      stopwatch.stop();
      client.close(force: true);
    }

    lastUploadBytes = acknowledgedBytes;
    logHttp('upload done: $acknowledgedBytes bytes acknowledged in '
        '${stopwatch.elapsedMilliseconds} ms');
    return _toMbps(acknowledgedBytes, stopwatch.elapsed);
  }

  /// Random bytes, generated once and reused for every chunk.
  ///
  /// Random rather than zeros so nothing along the path can compress the
  /// body and make the uplink look faster than it is.
  static Uint8List _incompressiblePayload(int bytes) {
    final random = Random();
    final payload = Uint8List(bytes);
    // Filled a word at a time - byte-by-byte on a multi-megabyte buffer is
    // slow enough to show up in the measurement itself.
    final words = Uint32List.view(
      payload.buffer,
      0,
      payload.lengthInBytes ~/ Uint32List.bytesPerElement,
    );
    for (var i = 0; i < words.length; i++) {
      words[i] = random.nextInt(0xFFFFFFFF);
    }
    return payload;
  }

  /// Samples round-trip time against [endpoint], in ms.
  ///
  /// Returns one entry per successful round trip. **The first round trip is
  /// discarded**: it pays DNS resolution and the TCP handshake, so
  /// including it would inflate both the mean and - much worse - the
  /// jitter, since one large outlier dominates a mean-absolute-difference.
  /// Subsequent requests reuse the kept-alive connection and measure
  /// something close to true RTT.
  ///
  /// Failed requests are skipped rather than aborting the run, so a single
  /// dropped packet doesn't discard the whole sample set. Returns an empty
  /// list if nothing succeeded.
  ///
  /// [headers] are added to every probe, for a backend that requires auth.
  Future<List<double>> measureLatencySamplesMs({
    required Uri endpoint,
    int samples = 11,
    Duration timeout = const Duration(seconds: 5),
    Map<String, String> headers = const {},
  }) async {
    final uri = endpoint;
    lastPacketLossPercent = null;
    final client = HttpClient()..connectionTimeout = timeout;
    final results = <double>[];
    var failures = 0;

    try {
      for (var i = 0; i < samples; i++) {
        try {
          logHttp('→ REQUEST GET $uri');
          final stopwatch = Stopwatch()..start();
          final request = await client.getUrl(uri);
          headers.forEach(request.headers.set);
          // connectionTimeout only covers connecting; without these a
          // probe whose reply never comes would hang rather than count
          // as lost.
          final response = await request.close().timeout(timeout);
          await response.drain<void>().timeout(timeout);
          stopwatch.stop();
          logHttp('← RESPONSE status=${response.statusCode} GET $uri '
              '(${stopwatch.elapsedMicroseconds / 1000} ms'
              '${i == 0 ? ', setup - discarded' : ''})');
          // i == 0 covers connection setup; measure, then throw it away.
          if (i > 0) results.add(stopwatch.elapsedMicroseconds / 1000);
        } catch (e) {
          logHttp('✗ GET $uri failed: $e');
          failures++;
          continue;
        }
      }
    } finally {
      client.close(force: true);
    }
    lastPacketLossPercent = samples > 0 ? failures * 100 / samples : null;
    return results;
  }

  /// Mean RTT in ms, or 0 if no sample succeeded.
  ///
  /// Use [measureLatencySamplesMs] directly when jitter is also wanted -
  /// it avoids paying for a second set of round trips.
  Future<double> measureLatencyMs({
    required Uri endpoint,
    int samples = 11,
    Duration timeout = const Duration(seconds: 5),
    Map<String, String> headers = const {},
  }) async {
    final results = await measureLatencySamplesMs(
      endpoint: endpoint,
      samples: samples,
      timeout: timeout,
      headers: headers,
    );
    if (results.isEmpty) return 0;
    return results.reduce((a, b) => a + b) / results.length;
  }

}

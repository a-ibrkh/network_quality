/// Tunable settings for the module.
///
/// Passed to `NetworkQualityService` at construction, so the host app can
/// point measurements at a different server, or change how long a
/// throughput test runs, without touching module code.
///
/// Deliberately not JSON-serializable: there is no remote-config endpoint,
/// and values come from the host app's own source rather than over the
/// network. Should that ever change, note that this object decides what
/// URL a fleet of devices fetches, on how many parallel connections - so a
/// remotely-supplied version would need its input treated as hostile
/// (clamped ranges, URL allowlist, HTTPS-only transport), which is a
/// different design from the plain value object below.
class NetworkQualityConfig {
  /// Where [SpeedTestCollector.measureDownloadMbps] pulls from by default.
  ///
  /// Cloudflare's speed-test origin. `bytes` sets the response size, and
  /// the collector's cache-buster merges into the existing query string.
  ///
  /// Caveat worth keeping in mind when reading the numbers: Cloudflare
  /// peers with, and often caches inside, carrier networks. Throughput to
  /// it is close to best case and won't match what users get to an
  /// arbitrary destination. Point [downloadEndpoint] at a first-party
  /// server if you need that.
  static final Uri defaultDownloadEndpoint =
      Uri.parse('https://speed.cloudflare.com/__down?bytes=10000000');

  /// Where [SpeedTestCollector.measureUploadMbps] posts to by default.
  ///
  /// Cloudflare's upload sink: accepts an arbitrary body, discards it, and
  /// - crucially for measurement - responds only once the whole body has
  /// been received. Same caveat as [defaultDownloadEndpoint] applies.
  static final Uri defaultUploadEndpoint =
      Uri.parse('https://speed.cloudflare.com/__up');

  /// Paths on [baseUrl] that the telemetry and ping endpoints default to.
  static const String locationPath = '/api/telemetry/location';
  static const String speedtestPath = '/api/telemetry/speedtest';
  static const String pingPath = '/speedtest/ping';

  /// Round trips sampled per latency measurement. The first is discarded
  /// (it pays DNS + TCP + connection setup), so this must exceed 1.
  static const int defaultLatencySamples = 11;

  static const Duration defaultDownloadTestDuration = Duration(seconds: 4);
  static const Duration defaultDownloadWarmup = Duration(milliseconds: 500);
  static const int defaultDownloadParallelConnections = 4;
  static const int defaultDownloadMaxBytes = 10 * 1024 * 1024;
  static const Duration defaultMeasurementCooldown = Duration(hours: 12);
  static const Duration defaultGnssSampleDuration = Duration(seconds: 6);

  static const Duration defaultUploadTestDuration = Duration(seconds: 4);
  static const int defaultUploadParallelConnections = 3;
  static const int defaultUploadChunkBytes = 512 * 1024;
  static const int defaultUploadMaxBytes = 4 * 1024 * 1024;

  /// Backend the telemetry is sent to, and the latency probe hits.
  /// [locationEndpoint], [speedtestEndpoint] and [pingEndpoint] are derived
  /// from it unless set explicitly.
  ///
  /// Required: the SDK has no backend of its own, so each host app names
  /// the one its data belongs in.
  final Uri baseUrl;

  /// Extra headers sent with every request to [baseUrl] (telemetry posts
  /// and latency probes), e.g. `{'Authorization': 'Bearer …'}`. Not sent
  /// to the throughput endpoints, which are third-party by default.
  final Map<String, String> headers;

  final Uri downloadEndpoint;
  final Duration downloadTestDuration;

  /// Leading portion of the test excluded from the reported rate, so TCP
  /// slow-start doesn't drag the figure down. Must be shorter than
  /// [downloadTestDuration] or there'd be no measurement window left.
  final Duration downloadWarmup;

  final int downloadParallelConnections;

  /// Hard ceiling on bytes transferred, so a fast link can't run up the
  /// user's mobile data allowance before [downloadTestDuration] elapses.
  ///
  /// This is the binding limit on any reasonably fast connection: at
  /// 80 Mbps the default cap is reached in about a second, well inside
  /// [downloadTestDuration]. Slow links hit the duration limit first and
  /// use proportionally less. Raising it buys accuracy on fast links and
  /// costs the user data; see the data-cost table in the README.
  final int downloadMaxBytes;

  final Uri uploadEndpoint;

  /// `POST` target for `NetworkQualitySnapshot` - passive data + location.
  final Uri locationEndpoint;

  /// `POST` target for `ActiveMeasurement`.
  final Uri speedtestEndpoint;

  /// `GET` target for latency sampling; expected to be trivial (the live
  /// endpoint returns 204 No Content).
  final Uri pingEndpoint;

  final int latencySamples;
  final Duration uploadTestDuration;
  final int uploadParallelConnections;

  /// Size of each POST body. Uploads are counted only once the server
  /// acknowledges a whole chunk, so this also sets the measurement's
  /// granularity: too large and a slow uplink finishes none of them, too
  /// small and per-request overhead dominates.
  final int uploadChunkBytes;

  /// Hard ceiling on bytes uploaded. Lower than the download ceiling on
  /// purpose - uplink is typically far slower, and this is the user's
  /// mobile data being spent.
  final int uploadMaxBytes;

  /// Minimum gap between active measurements.
  final Duration measurementCooldown;

  /// Whether active measurements run only on a cellular connection.
  final bool cellularOnly;

  /// How long `collectSnapshot()` listens to GPS satellites for the
  /// indoor/outdoor hint. Long enough for a warm engine to report signal
  /// strengths; every snapshot takes at least this long. [Duration.zero]
  /// disables sampling.
  final Duration gnssSampleDuration;

  /// Asserts guard against values that would silently produce nonsense
  /// (a warmup longer than the test, zero connections). They're debug-only
  /// by design - this comes from the app's own code, so a wrong value is a
  /// programming error worth catching loudly in development rather than a
  /// runtime condition to defend against.
  NetworkQualityConfig({
    required this.baseUrl,
    this.headers = const {},
    Uri? downloadEndpoint,
    Uri? uploadEndpoint,
    Uri? locationEndpoint,
    Uri? speedtestEndpoint,
    Uri? pingEndpoint,
    this.latencySamples = defaultLatencySamples,
    this.downloadTestDuration = defaultDownloadTestDuration,
    this.downloadWarmup = defaultDownloadWarmup,
    this.downloadParallelConnections = defaultDownloadParallelConnections,
    this.downloadMaxBytes = defaultDownloadMaxBytes,
    this.uploadTestDuration = defaultUploadTestDuration,
    this.uploadParallelConnections = defaultUploadParallelConnections,
    this.uploadChunkBytes = defaultUploadChunkBytes,
    this.uploadMaxBytes = defaultUploadMaxBytes,
    this.measurementCooldown = defaultMeasurementCooldown,
    this.cellularOnly = true,
    this.gnssSampleDuration = defaultGnssSampleDuration,
  })  : downloadEndpoint = downloadEndpoint ?? defaultDownloadEndpoint,
        uploadEndpoint = uploadEndpoint ?? defaultUploadEndpoint,
        locationEndpoint = locationEndpoint ?? baseUrl.resolve(locationPath),
        speedtestEndpoint = speedtestEndpoint ?? baseUrl.resolve(speedtestPath),
        pingEndpoint = pingEndpoint ?? baseUrl.resolve(pingPath),
        assert(baseUrl.hasScheme && baseUrl.host.isNotEmpty,
            'baseUrl must be absolute, e.g. https://api.example.com'),
        assert(latencySamples > 1,
            'latencySamples must exceed 1: the first sample is discarded '
            'because it includes connection setup'),
        assert(downloadParallelConnections > 0,
            'downloadParallelConnections must be at least 1'),
        assert(downloadMaxBytes > 0, 'downloadMaxBytes must be positive'),
        assert(downloadTestDuration > Duration.zero,
            'downloadTestDuration must be positive'),
        assert(!downloadWarmup.isNegative, 'downloadWarmup cannot be negative'),
        assert(downloadWarmup < downloadTestDuration,
            'downloadWarmup must be shorter than downloadTestDuration, '
            'or no measurement window remains'),
        assert(uploadParallelConnections > 0,
            'uploadParallelConnections must be at least 1'),
        assert(uploadChunkBytes > 0, 'uploadChunkBytes must be positive'),
        assert(uploadMaxBytes >= uploadChunkBytes,
            'uploadMaxBytes must allow at least one chunk'),
        assert(uploadTestDuration > Duration.zero,
            'uploadTestDuration must be positive'),
        assert(!measurementCooldown.isNegative,
            'measurementCooldown cannot be negative'),
        assert(!gnssSampleDuration.isNegative,
            'gnssSampleDuration cannot be negative');

  /// A copy with the given fields replaced. Changing [baseUrl] re-derives
  /// the telemetry and ping endpoints from it, unless they are passed too.
  NetworkQualityConfig copyWith({
    Uri? baseUrl,
    Map<String, String>? headers,
    Uri? downloadEndpoint,
    Uri? uploadEndpoint,
    Uri? locationEndpoint,
    Uri? speedtestEndpoint,
    Uri? pingEndpoint,
    int? latencySamples,
    Duration? downloadTestDuration,
    Duration? downloadWarmup,
    int? downloadParallelConnections,
    int? downloadMaxBytes,
    Duration? uploadTestDuration,
    int? uploadParallelConnections,
    int? uploadChunkBytes,
    int? uploadMaxBytes,
    Duration? measurementCooldown,
    bool? cellularOnly,
    Duration? gnssSampleDuration,
  }) {
    final keepDerived = baseUrl == null;
    return NetworkQualityConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      headers: headers ?? this.headers,
      downloadEndpoint: downloadEndpoint ?? this.downloadEndpoint,
      uploadEndpoint: uploadEndpoint ?? this.uploadEndpoint,
      locationEndpoint:
          locationEndpoint ?? (keepDerived ? this.locationEndpoint : null),
      speedtestEndpoint:
          speedtestEndpoint ?? (keepDerived ? this.speedtestEndpoint : null),
      pingEndpoint: pingEndpoint ?? (keepDerived ? this.pingEndpoint : null),
      latencySamples: latencySamples ?? this.latencySamples,
      uploadTestDuration: uploadTestDuration ?? this.uploadTestDuration,
      uploadParallelConnections:
          uploadParallelConnections ?? this.uploadParallelConnections,
      uploadChunkBytes: uploadChunkBytes ?? this.uploadChunkBytes,
      uploadMaxBytes: uploadMaxBytes ?? this.uploadMaxBytes,
      downloadTestDuration: downloadTestDuration ?? this.downloadTestDuration,
      downloadWarmup: downloadWarmup ?? this.downloadWarmup,
      downloadParallelConnections:
          downloadParallelConnections ?? this.downloadParallelConnections,
      downloadMaxBytes: downloadMaxBytes ?? this.downloadMaxBytes,
      measurementCooldown: measurementCooldown ?? this.measurementCooldown,
      cellularOnly: cellularOnly ?? this.cellularOnly,
      gnssSampleDuration: gnssSampleDuration ?? this.gnssSampleDuration,
    );
  }

  @override
  String toString() => 'NetworkQualityConfig('
      'baseUrl: $baseUrl, '
      // Names only: values are typically credentials.
      'headers: ${headers.keys.toList()}, '
      'downloadEndpoint: $downloadEndpoint, '
      'uploadEndpoint: $uploadEndpoint, '
      'locationEndpoint: $locationEndpoint, '
      'speedtestEndpoint: $speedtestEndpoint, '
      'pingEndpoint: $pingEndpoint, '
      'downloadTestDuration: $downloadTestDuration, '
      'downloadWarmup: $downloadWarmup, '
      'downloadParallelConnections: $downloadParallelConnections, '
      'downloadMaxBytes: $downloadMaxBytes, '
      'measurementCooldown: $measurementCooldown, '
      'cellularOnly: $cellularOnly, '
      'gnssSampleDuration: $gnssSampleDuration)';
}

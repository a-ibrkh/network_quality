import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:geolocator/geolocator.dart' show Geolocator;
import 'package:uuid/uuid.dart';

import 'collectors/cellular_collector.dart';
import 'collectors/cellular_collector_ios.dart';
import 'collectors/connectivity_collector.dart';
import 'collectors/device_context_collector.dart';
import 'collectors/environment_collector.dart';
import 'collectors/gnss_collector.dart';
import 'collectors/location_collector.dart';
import 'collectors/telemetry_sender.dart';
import 'collectors/speed_test_collector.dart';
import 'models/active_measurement.dart';
import 'models/cellular_info.dart';
import 'models/connectivity_info.dart';
import 'models/environment_info.dart';
import 'models/gnss_info.dart';
import 'models/location_info.dart';
import 'models/network_quality_config.dart';
import 'models/network_quality_snapshot.dart';
import 'models/permission_state.dart';
import 'models/radio_stats.dart';
import 'measurement_throttle.dart';
import 'telemetry_dispatcher.dart';
import 'telemetry_queue.dart';
import 'permission_manager.dart';
import 'shared_preferences_timestamp_store.dart';

/// Facade that orchestrates the individual collectors.
///
/// This is the SDK's entry point: construct one instance (typically
/// long-lived, e.g. as a singleton in the host app) and call
/// [collectSnapshot] for fast passive data or [runActiveTest] for the
/// active measurements, then [sendSnapshot] / [sendTestResult].
class NetworkQualityService {
  static const _uuid = Uuid();

  final String sessionId;

  /// Tunables for this instance; see [NetworkQualityConfig].
  final NetworkQualityConfig config;
  final ConnectivityCollector _connectivityCollector;
  final CellularCollector? _cellularCollector;
  final CellularCollectorIos? _cellularCollectorIos;
  final DeviceContextCollector _deviceContextCollector;
  final SpeedTestCollector _speedTestCollector;
  final LocationCollector _locationCollector;
  final GnssCollector _gnssCollector;
  final EnvironmentCollector _environmentCollector;
  final TelemetryDispatcher _dispatcher;
  final PermissionManager _permissionManager;
  final MeasurementThrottle _throttle;

  /// [config] names the backend and tunes the tests; see
  /// [NetworkQualityConfig].
  ///
  /// [sessionId] identifies this service instance's measurements so they
  /// can be correlated once sent to a backend. Defaults to a fresh v4 uuid;
  /// pass one in to continue an existing session (e.g. restored from disk).
  ///
  /// [timestampStore] and [queueStore] replace the default
  /// `SharedPreferences` storage for the cooldown timestamp and the
  /// undelivered-report queue, for a host app with its own persistence.
  NetworkQualityService({
    required NetworkQualityConfig config,
    String? sessionId,
    MeasurementTimestampStore? timestampStore,
    TelemetryQueueStore? queueStore,
  }) : this.withDependencies(
          config: config,
          sessionId: sessionId,
          throttle: timestampStore == null
              ? null
              : MeasurementThrottle(timestampStore),
          dispatcher: queueStore == null
              ? null
              : TelemetryDispatcher(
                  sender: TelemetrySender(config: config),
                  queue: TelemetryQueue(queueStore),
                ),
        );

  /// Every collaborator injectable, for tests. Host apps use the default
  /// constructor; the collectors are not part of the public API.
  @visibleForTesting
  NetworkQualityService.withDependencies({
    required NetworkQualityConfig config,
    String? sessionId,
    ConnectivityCollector? connectivityCollector,
    CellularCollector? cellularCollector,
    CellularCollectorIos? cellularCollectorIos,
    DeviceContextCollector? deviceContextCollector,
    SpeedTestCollector? speedTestCollector,
    LocationCollector? locationCollector,
    GnssCollector? gnssCollector,
    EnvironmentCollector? environmentCollector,
    TelemetrySender? telemetrySender,
    TelemetryDispatcher? dispatcher,
    PermissionManager? permissionManager,
    MeasurementThrottle? throttle,
  })  : sessionId = sessionId ?? _uuid.v4(),
        config = config,
        _dispatcher = dispatcher ??
            TelemetryDispatcher(
              sender: telemetrySender ?? TelemetrySender(config: config),
            ),
        _throttle = throttle ??
            const MeasurementThrottle(SharedPreferencesTimestampStore()),
        _locationCollector = locationCollector ?? const LocationCollector(),
        _gnssCollector = gnssCollector ?? const GnssCollector(),
        _environmentCollector =
            environmentCollector ?? const EnvironmentCollector(),
        _permissionManager = permissionManager ?? const PermissionManager(),
        _connectivityCollector = connectivityCollector ?? ConnectivityCollector(),
        _cellularCollector = Platform.isAndroid ? (cellularCollector ?? CellularCollector()) : null,
        _cellularCollectorIos = Platform.isIOS ? (cellularCollectorIos ?? CellularCollectorIos()) : null,
        _deviceContextCollector = deviceContextCollector ?? DeviceContextCollector(),
        _speedTestCollector = speedTestCollector ?? SpeedTestCollector();

  /// Gathers all passive data in one call. Makes no network calls, only
  /// reads local OS/radio state.
  ///
  /// Takes about `config.gnssSampleDuration` (6 s by default): GPS is
  /// switched on for that long to sample satellite visibility as an
  /// indoor/outdoor hint, and light/motion/Wi-Fi are sampled over the same
  /// window, while the other collectors run. Location is read
  /// after the window, so the OS's cached position benefits from the GPS
  /// having just run.
  ///
  /// Location uses the OS's cached last-known position by default, which
  /// returns immediately and preserves that speed. Set [freshLocation] to
  /// wait for a new fix instead - accurate but slow (seconds, sometimes
  /// much longer indoors) and a meaningful battery cost, so it belongs in
  /// deliberate drive-test style flows rather than routine collection.
  /// Either way the fix's own timestamp is recorded, so staleness is
  /// visible downstream rather than implied.
  Future<NetworkQualitySnapshot> collectSnapshot({
    bool freshLocation = false,
  }) async {
    final sampleGnss = config.gnssSampleDuration > Duration.zero;
    final gnssFuture = sampleGnss
        ? _gnssCollector.collect(duration: config.gnssSampleDuration)
        : Future<GnssInfo?>.value();
    final environmentFuture = sampleGnss
        ? _environmentCollector.collect(duration: config.gnssSampleDuration)
        : Future<EnvironmentInfo?>.value();

    final connectivityInfo = await _connectivityCollector.collect();

    CellularInfo? cellularInfo;
    RadioStats? radioStats;
    if (_cellularCollector != null) {
      cellularInfo = await _cellularCollector.collect();
      radioStats = await _cellularCollector.takeRadioStats();
    } else if (_cellularCollectorIos != null) {
      cellularInfo = await _cellularCollectorIos.collect();
    }

    final deviceContext = await _deviceContextCollector.collect();
    final gnssInfo = await gnssFuture;
    final environmentInfo = await environmentFuture;
    final locationInfo =
        await _locationCollector.collect(forceFresh: freshLocation);

    return NetworkQualitySnapshot(
      sessionId: sessionId,
      timestamp: DateTime.now(),
      connectivityInfo: connectivityInfo,
      cellularInfo: cellularInfo,
      deviceContext: deviceContext,
      locationInfo: locationInfo,
      gnssInfo: gnssInfo,
      environmentInfo: environmentInfo,
      radioStats: radioStats,
    );
  }

  /// Runs the active measurements that are currently possible: DNS
  /// resolution, TCP connect, TLS handshake timing, latency and jitter,
  /// and - when [includeDownload] / [includeUpload] are set - throughput in
  /// each direction.
  ///
  /// By default the test **only runs on a cellular connection**. This SDK
  /// exists to characterise the cellular network, and timings taken over
  /// Wi-Fi or ethernet describe a different link entirely - recording them
  /// would corrupt the dataset rather than add to it. Off cellular, the
  /// returned result has every metric `null` and
  /// `skipReason == MeasurementSkipReason.notCellular`, which is how the
  /// backend distinguishes "did not measure" from "measured and failed".
  /// Pass [cellularOnly] as false to measure on any connection.
  ///
  /// [includeDownload] defaults to true but is worth turning off on a
  /// metered connection: the throughput test deliberately transfers as much
  /// as it can for several seconds, so it is by far the most data-hungry
  /// thing this module does - and on cellular the user is usually paying
  /// for those bytes. `ConnectivityInfo.isMetered` from [collectSnapshot]
  /// is the signal to base that decision on.
  ///
  /// A measurement is also suppressed if one already ran within
  /// [cooldown] (12 hours by default), returning
  /// `skipReason == MeasurementSkipReason.recentlyMeasured`. Measurements
  /// are triggered by app open, so without this a user who reopens the app
  /// repeatedly would spend their mobile data on near-duplicate readings.
  /// The timestamp is persisted, so the window survives an app restart.
  /// Pass [ignoreCooldown] for a user-initiated "test again" action.
  ///
  /// Only a run that actually measured updates the timestamp - skipped runs
  /// don't, so being on Wi-Fi never consumes the window.
  ///
  /// Each measurement is isolated - one failing (no connectivity, blocked
  /// port, cleartext rejection) leaves its field `null` without preventing
  /// the others from running.
  Future<ActiveMeasurement> runActiveTest({
    bool includeDownload = true,
    bool includeUpload = true,
    bool? cellularOnly,
    Duration? cooldown,
    bool ignoreCooldown = false,
  }) async {
    // Per-call arguments override the instance config, which overrides the
    // built-in defaults.
    final requireCellular = cellularOnly ?? config.cellularOnly;
    final effectiveCooldown = cooldown ?? config.measurementCooldown;
    // Cheap and local - no network access - so this gate costs nothing.
    final connectivityInfo = await _connectivityCollector.collect();
    final connectionType = connectivityInfo.connectionType;

    if (requireCellular && connectionType != ConnectionType.cellular) {
      return ActiveMeasurement(
        sessionId: sessionId,
        timestamp: DateTime.now(),
        connectionType: connectionType,
        skipReason: MeasurementSkipReason.notCellular,
      );
    }

    // Checked after the cellular gate so a Wi-Fi session reports the more
    // fundamental reason, and so being on Wi-Fi never consumes the
    // cooldown window.
    if (!ignoreCooldown &&
        await _throttle.shouldSkip(cooldown: effectiveCooldown)) {
      return ActiveMeasurement(
        sessionId: sessionId,
        timestamp: DateTime.now(),
        connectionType: connectionType,
        skipReason: MeasurementSkipReason.recentlyMeasured,
      );
    }

    double? dnsResolutionMs;
    double? tcpConnectionMs;
    double? tlsHandshakeMs;
    double? downloadMbps;
    double? uploadMbps;
    double? latencyMs;
    double? jitterMs;

    try {
      dnsResolutionMs = await _speedTestCollector.measureDnsResolutionMs();
    } catch (_) {
      dnsResolutionMs = null;
    }
    try {
      tcpConnectionMs = await _speedTestCollector.measureTcpConnectionMs();
    } catch (_) {
      tcpConnectionMs = null;
    }
    try {
      tlsHandshakeMs = await _speedTestCollector.measureTlsHandshakeMs();
    } catch (_) {
      tlsHandshakeMs = null;
    }
    if (includeDownload) {
      try {
        downloadMbps = await _speedTestCollector.measureDownloadMbps(
          endpoint: config.downloadEndpoint,
          testDuration: config.downloadTestDuration,
          warmup: config.downloadWarmup,
          parallelConnections: config.downloadParallelConnections,
          maxBytes: config.downloadMaxBytes,
        );
      } catch (_) {
        downloadMbps = null;
      }
    }

    try {
      // One set of round trips feeds both figures - sampling twice would
      // double the requests and still not agree with itself.
      final samples = await _speedTestCollector.measureLatencySamplesMs(
        endpoint: config.pingEndpoint,
        samples: config.latencySamples,
        headers: config.headers,
      );
      if (samples.isNotEmpty) {
        latencyMs = samples.reduce((a, b) => a + b) / samples.length;
        jitterMs = _speedTestCollector.computeJitterMs(samples);
      }
    } catch (_) {
      latencyMs = null;
      jitterMs = null;
    }
    if (includeUpload) {
      try {
        uploadMbps = await _speedTestCollector.measureUploadMbps(
          endpoint: config.uploadEndpoint,
          testDuration: config.uploadTestDuration,
          parallelConnections: config.uploadParallelConnections,
          chunkBytes: config.uploadChunkBytes,
          maxBytes: config.uploadMaxBytes,
        );
      } catch (_) {
        uploadMbps = null;
      }
    }

    // Recorded only on a run that actually measured - marking a skipped run
    // would push the next one a further full cooldown away.
    await _throttle.recordMeasurement();

    return ActiveMeasurement(
      sessionId: sessionId,
      timestamp: DateTime.now(),
      connectionType: connectionType,
      uploadMbps: uploadMbps,
      latencyMs: latencyMs,
      jitterMs: jitterMs,
      dnsResolutionMs: dnsResolutionMs,
      tcpConnectionMs: tcpConnectionMs,
      tlsHandshakeMs: tlsHandshakeMs,
      downloadMbps: downloadMbps,
      packetLossPercent: _speedTestCollector.lastPacketLossPercent,
      ttfbMs: includeDownload ? _speedTestCollector.lastTtfbMs : null,
      downloadBytes: includeDownload ? _speedTestCollector.lastDownloadBytes : null,
      uploadBytes: includeUpload ? _speedTestCollector.lastUploadBytes : null,
    );
  }

  /// Queues a snapshot and attempts delivery, along with any backlog.
  ///
  /// Does **not** throw on a failed send: the report is persisted before
  /// the attempt, so a failure just leaves it queued for later. Inspect
  /// the [FlushResult] to see what was actually delivered.
  Future<FlushResult> sendSnapshot(NetworkQualitySnapshot snapshot) =>
      _dispatcher.submitSnapshot(snapshot);

  /// Queues an active measurement result and attempts delivery. Same
  /// contract as [sendSnapshot].
  Future<FlushResult> sendTestResult(ActiveMeasurement result) =>
      _dispatcher.submitTestResult(result);

  /// Retries whatever is still queued, without adding anything new. Worth
  /// calling at app start, or when connectivity is restored.
  Future<FlushResult> flushPendingTelemetry() => _dispatcher.flushPending();

  /// How many reports are waiting to be delivered.
  Future<int> pendingTelemetryCount() => _dispatcher.pendingCount();

  /// When the last measurement ran, or null if there hasn't been one on
  /// this device. Persisted across restarts. Useful for a "checked N
  /// minutes ago" label.
  Future<DateTime?> lastMeasurementAt() => _throttle.lastMeasurementAt();

  /// How long until [runActiveTest] will measure again rather than skip,
  /// or null if it would measure now. Lets the host app disable a "test
  /// again" button, or show a countdown, instead of calling and getting a
  /// `recentlyMeasured` skip back.
  Future<Duration?> timeUntilNextMeasurement({Duration? cooldown}) =>
      _throttle.timeUntilNextAllowed(
        cooldown: cooldown ?? config.measurementCooldown,
      );

  /// Reports whether the OS permissions this module needs are already
  /// held, without prompting the user.
  Future<PermissionStatuses> checkPermissions() async {
    if (Platform.isAndroid) return _permissionManager.check();
    return _iosLocationOnlyStatuses(await _locationCollector.collect());
  }

  /// Requests the OS permissions this module needs (fine location + phone
  /// state on Android for cellular radio info; nothing on other platforms).
  ///
  /// Deliberately *not* called automatically by [collectSnapshot] - a
  /// permission dialog appearing as a side effect of reading data would be
  /// a poor experience, and only the host app knows where in its UX flow to
  /// prompt. Call it at a natural point (e.g. during onboarding, or after
  /// [checkPermissions] reveals cellular data will come back empty).
  ///
  /// If the result [PermissionStatuses.isPermanentlyDenied], re-requesting
  /// will not show a dialog; use [openAppSettings] instead.
  ///
  /// On iOS the native handler doesn't apply - location is the only
  /// permission the module needs there, so this prompts for that via
  /// `LocationCollector` and reports it in
  /// [PermissionStatuses.fineLocation], leaving `phoneState` as
  /// `notRequired`.
  Future<PermissionStatuses> requestPermissions() async {
    if (Platform.isAndroid) {
      // ACCESS_FINE_LOCATION covers both the cellular metrics and the
      // location fix, so the single native prompt satisfies everything.
      return _permissionManager.request();
    }
    final status = await _locationCollector.requestPermission();
    return PermissionStatuses(
      fineLocation: _permissionStateForLocation(status),
      phoneState: PermissionState.notRequired,
    );
  }

  /// Opens this app's page in the system settings - the only way left to
  /// grant a permission once it is permanently denied. Returns whether the
  /// settings screen opened.
  Future<bool> openAppSettings() {
    if (Platform.isAndroid) return _permissionManager.openAppSettings();
    return Geolocator.openAppSettings();
  }

  PermissionStatuses _iosLocationOnlyStatuses(LocationInfo info) {
    return PermissionStatuses(
      fineLocation: _permissionStateForLocation(info.status),
      phoneState: PermissionState.notRequired,
    );
  }

  PermissionState _permissionStateForLocation(LocationStatus status) {
    switch (status) {
      case LocationStatus.available:
        return PermissionState.granted;
      case LocationStatus.permissionPermanentlyDenied:
        return PermissionState.permanentlyDenied;
      case LocationStatus.permissionDenied:
      case LocationStatus.servicesDisabled:
      case LocationStatus.unavailable:
      case LocationStatus.notCollected:
        return PermissionState.denied;
    }
  }
}

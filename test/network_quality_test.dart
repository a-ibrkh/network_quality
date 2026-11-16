import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_quality/network_quality.dart';
// Internals under test that aren't part of the public API.
import 'package:network_quality/src/collectors/speed_test_collector.dart';
import 'package:network_quality/src/measurement_throttle.dart';
import 'package:network_quality/src/models/wire_privacy.dart';
import 'package:network_quality/src/telemetry_queue.dart';

final _backend = Uri.parse('https://backend.example');

void main() {
  group('SpeedTestCollector.computeJitterMs', () {
    final collector = SpeedTestCollector();

    test('returns 0 for fewer than two samples', () {
      expect(collector.computeJitterMs([]), 0);
      expect(collector.computeJitterMs([12.5]), 0);
    });

    test('returns 0 for constant latency', () {
      expect(collector.computeJitterMs([20, 20, 20, 20]), 0);
    });

    test('averages absolute differences between consecutive samples', () {
      // diffs: 10, 5, 15 -> mean 10
      expect(collector.computeJitterMs([10, 20, 15, 30]), 10);
    });

    test('is direction-insensitive', () {
      expect(
        collector.computeJitterMs([10, 20, 10]),
        collector.computeJitterMs([20, 10, 20]),
      );
    });
  });

  group('model serialization round-trips', () {
    test('ConnectivityInfo', () {
      final original = ConnectivityInfo(
        connectionType: ConnectionType.cellular,
        isVpnActive: false,
        isMetered: true,
        isAirplaneModeOn: false,
        isDataRoaming: true,
        carrierName: 'Test Carrier',
        mcc: '434',
        mnc: '04',
        cellularGeneration: CellularGeneration.g5,
        dataNetworkType: DataNetworkType.nr,
        timestamp: DateTime.parse('2026-07-30T12:00:00.000Z'),
      );

      final restored = ConnectivityInfo.fromJson(original.toJson());

      expect(restored.connectionType, ConnectionType.cellular);
      expect(restored.isMetered, true);
      expect(restored.isDataRoaming, true);
      expect(restored.carrierName, 'Test Carrier');
      expect(restored.mcc, '434');
      expect(restored.mnc, '04');
      expect(restored.cellularGeneration, CellularGeneration.g5);
      expect(restored.dataNetworkType, DataNetworkType.nr);
      expect(restored.timestamp, original.timestamp);
    });

    test('CellularInfo preserves nulls for unavailable metrics', () {
      final original = CellularInfo(
        rsrp: -95,
        rsrq: -11,
        signalLevel: 3,
        cellId: 12345678,
        timestamp: DateTime.parse('2026-07-30T12:00:00.000Z'),
      );

      final restored = CellularInfo.fromJson(original.toJson());

      expect(restored.rsrp, -95);
      expect(restored.rsrq, -11);
      expect(restored.signalLevel, 3);
      expect(restored.cellId, 12345678);
      // Not set above - must survive as null rather than becoming 0.
      expect(restored.rssi, isNull);
      expect(restored.cqi, isNull);
      expect(restored.timingAdvance, isNull);
    });

    test('NetworkQualitySnapshot nests its sub-models', () {
      final snapshot = NetworkQualitySnapshot(
        sessionId: 'session-abc',
        timestamp: DateTime.parse('2026-07-30T12:00:00.000Z'),
        connectivityInfo: ConnectivityInfo(
          connectionType: ConnectionType.wifi,
          timestamp: DateTime.parse('2026-07-30T12:00:00.000Z'),
        ),
        cellularInfo: null,
        deviceContext: DeviceContext(
          batteryLevel: 77,
          isCharging: true,
          deviceModel: 'Pixel 7',
          osVersion: 'Android 14',
          isAppInForeground: true,
          timestamp: DateTime.parse('2026-07-30T12:00:00.000Z'),
        ),
        locationInfo: LocationInfo(
          status: LocationStatus.available,
          latitude: 41.311081,
          longitude: 69.240562,
          accuracyMeters: 12.5,
          isMocked: false,
          fixTimestamp: DateTime.parse('2026-07-30T11:59:30.000Z'),
          timestamp: DateTime.parse('2026-07-30T12:00:00.000Z'),
        ),
      );

      final restored = NetworkQualitySnapshot.fromJson(snapshot.toJson());

      expect(restored.sessionId, 'session-abc');
      expect(restored.connectivityInfo.connectionType, ConnectionType.wifi);
      expect(restored.cellularInfo, isNull);
      expect(restored.deviceContext.batteryLevel, 77);
      expect(restored.deviceContext.deviceModel, 'Pixel 7');
      // Coarsened on the wire; see wire_privacy.dart.
      expect(restored.locationInfo.latitude, 41.311);
      expect(restored.locationInfo.longitude, 69.241);
      expect(restored.locationInfo.status, LocationStatus.available);
    });

    test('ActiveMeasurement keeps server-dependent fields absent', () {
      final original = ActiveMeasurement(
        sessionId: 'session-abc',
        timestamp: DateTime.parse('2026-07-30T12:00:00.000Z'),
        connectionType: ConnectionType.cellular,
        dnsResolutionMs: 23.5,
        tcpConnectionMs: 41.25,
        tlsHandshakeMs: 88.0,
      );

      final restored = ActiveMeasurement.fromJson(original.toJson());

      expect(restored.sessionId, 'session-abc');
      expect(restored.connectionType, ConnectionType.cellular);
      expect(restored.dnsResolutionMs, 23.5);
      expect(restored.tcpConnectionMs, 41.25);
      expect(restored.tlsHandshakeMs, 88.0);
      expect(restored.downloadMbps, isNull);
      expect(restored.uploadMbps, isNull);
      expect(restored.latencyMs, isNull);
      // Ran for real, so it must not look like a skip.
      expect(restored.skipReason, isNull);
      expect(restored.wasSkipped, isFalse);
    });

    test('ActiveMeasurement round-trips a non-cellular skip', () {
      final skipped = ActiveMeasurement(
        sessionId: 'session-abc',
        timestamp: DateTime.parse('2026-07-30T12:00:00.000Z'),
        connectionType: ConnectionType.wifi,
        skipReason: MeasurementSkipReason.notCellular,
      );

      final restored = ActiveMeasurement.fromJson(skipped.toJson());

      expect(restored.wasSkipped, isTrue);
      expect(restored.skipReason, MeasurementSkipReason.notCellular);
      // The connection it was on is preserved even though nothing was run.
      expect(restored.connectionType, ConnectionType.wifi);
      expect(restored.downloadMbps, isNull);
      expect(restored.dnsResolutionMs, isNull);
    });

    test('absent skipReason parses as null, not a default enum value', () {
      expect(MeasurementSkipReason.fromName(null), isNull);
      expect(MeasurementSkipReason.fromName('bogus'), isNull);
      expect(
        MeasurementSkipReason.fromName('notCellular'),
        MeasurementSkipReason.notCellular,
      );
    });
  });

  group('NetworkQualityConfig', () {
    test('defaults are usable with only a backend', () {
      final config = NetworkQualityConfig(baseUrl: _backend);
      expect(config.downloadParallelConnections, 4);
      expect(config.cellularOnly, isTrue);
      expect(config.measurementCooldown, const Duration(hours: 12));
      expect(config.downloadWarmup, lessThan(config.downloadTestDuration));
      expect(config.headers, isEmpty);
    });

    test('derives the backend endpoints from baseUrl', () {
      final config = NetworkQualityConfig(baseUrl: _backend);
      expect(config.locationEndpoint.toString(),
          'https://backend.example/api/telemetry/location');
      expect(config.speedtestEndpoint.toString(),
          'https://backend.example/api/telemetry/speedtest');
      expect(config.pingEndpoint.toString(),
          'https://backend.example/speedtest/ping');
    });

    test('an explicit endpoint wins over the derived one', () {
      final config = NetworkQualityConfig(
        baseUrl: _backend,
        pingEndpoint: Uri.parse('https://ping.example/p'),
      );
      expect(config.pingEndpoint.host, 'ping.example');
      expect(config.locationEndpoint.host, 'backend.example');
    });

    test('copyWith(baseUrl) re-derives the backend endpoints', () {
      final moved = NetworkQualityConfig(baseUrl: _backend)
          .copyWith(baseUrl: Uri.parse('https://new.example'));
      expect(moved.locationEndpoint.host, 'new.example');
      expect(moved.pingEndpoint.host, 'new.example');
    });

    test('toString lists header names but not their values', () {
      final config = NetworkQualityConfig(
        baseUrl: _backend,
        headers: const {'Authorization': 'Bearer secret'},
      );
      expect(config.toString(), contains('Authorization'));
      expect(config.toString(), isNot(contains('secret')));
    });

    test('rejects a relative baseUrl', () {
      expect(
        () => NetworkQualityConfig(baseUrl: Uri.parse('/api')),
        throwsA(isA<AssertionError>()),
      );
    });

    test('accepts an alternate endpoint', () {
      final config = NetworkQualityConfig(
        baseUrl: _backend,
        downloadEndpoint: Uri.parse('https://speed.example.com/test.bin'),
        downloadParallelConnections: 8,
        cellularOnly: false,
      );
      expect(config.downloadEndpoint.host, 'speed.example.com');
      expect(config.downloadParallelConnections, 8);
      expect(config.cellularOnly, isFalse);
    });

    test('copyWith changes one field and preserves the rest', () {
      final base = NetworkQualityConfig(
        baseUrl: _backend,
        downloadEndpoint: Uri.parse('https://a.example/f.bin'),
        downloadParallelConnections: 8,
      );
      final copy = base.copyWith(downloadParallelConnections: 2);
      expect(copy.downloadParallelConnections, 2);
      expect(copy.downloadEndpoint, base.downloadEndpoint);
      expect(copy.measurementCooldown, base.measurementCooldown);
      expect(copy.locationEndpoint, base.locationEndpoint);
    });

    test('rejects a warmup that leaves no measurement window', () {
      expect(
        () => NetworkQualityConfig(
          baseUrl: _backend,
          downloadTestDuration: const Duration(seconds: 2),
          downloadWarmup: const Duration(seconds: 5),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects zero parallel connections', () {
      expect(
        () => NetworkQualityConfig(
            baseUrl: _backend, downloadParallelConnections: 0),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('TelemetryQueue', () {
    final t0 = DateTime.parse('2026-07-31T12:00:00.000Z');

    QueuedReport report(String id,
            {DateTime? at, int attempts = 0, DateTime? next}) =>
        QueuedReport(
          eventId: id,
          kind: TelemetryReportKind.speedtest,
          payload: {'sessionId': 's', 'eventId': id},
          queuedAt: at ?? t0,
          attempts: attempts,
          nextAttemptAt: next,
        );

    test('backoff grows exponentially and caps at an hour', () {
      expect(TelemetryQueue.backoffFor(0), Duration.zero);
      expect(TelemetryQueue.backoffFor(1), const Duration(seconds: 30));
      expect(TelemetryQueue.backoffFor(2), const Duration(seconds: 60));
      expect(TelemetryQueue.backoffFor(3), const Duration(minutes: 2));
      expect(TelemetryQueue.backoffFor(30), const Duration(hours: 1));
      // Must not overflow into a negative or absurd delay.
      expect(TelemetryQueue.backoffFor(1000), const Duration(hours: 1));
    });

    test('a report survives storage round-trip with its idempotency key', () {
      final restored =
          QueuedReport.fromJson(report('e1', attempts: 2).toJson());
      expect(restored.eventId, 'e1');
      expect(restored.kind, TelemetryReportKind.speedtest);
      expect(restored.attempts, 2);
      // The key must travel inside the payload, not just alongside it.
      expect(restored.payload['eventId'], 'e1');
    });

    test('delivered reports are removed', () async {
      final queue = TelemetryQueue(
          InMemoryTelemetryQueueStore([report('a'), report('b')]));
      final result = await queue.flush((_) async {}, now: t0);
      expect(result.sent, 2);
      expect(result.remaining, 0);
      expect(await queue.pendingCount(), 0);
    });

    test('a failed send is kept and backed off, not lost', () async {
      final queue = TelemetryQueue(InMemoryTelemetryQueueStore([report('a')]));
      final result =
          await queue.flush((_) async => throw Exception('offline'), now: t0);
      expect(result.failed, 1);
      expect(result.remaining, 1);

      final kept = (await queue.pending()).single;
      expect(kept.attempts, 1);
      expect(kept.nextAttemptAt, t0.add(const Duration(seconds: 30)));
    });

    test('a report still in backoff is skipped, then sent once due', () async {
      var sent = 0;
      final queue = TelemetryQueue(InMemoryTelemetryQueueStore([
        report('a', attempts: 1, next: t0.add(const Duration(minutes: 5))),
      ]));

      await queue.flush((_) async => sent++, now: t0);
      expect(sent, 0, reason: 'must respect the backoff window');

      await queue.flush((_) async => sent++,
          now: t0.add(const Duration(minutes: 6)));
      expect(sent, 1);
      expect(await queue.pendingCount(), 0);
    });

    test('stale reports are discarded unsent', () async {
      var sent = 0;
      final queue = TelemetryQueue(InMemoryTelemetryQueueStore(
          [report('old', at: t0.subtract(const Duration(days: 5)))]));
      final result = await queue.flush((_) async => sent++, now: t0);
      // A days-old measurement describes a network that no longer exists.
      expect(sent, 0);
      expect(result.discarded, 1);
      expect(result.remaining, 0);
    });

    test('reports are dropped once attempts are exhausted', () async {
      final queue = TelemetryQueue(InMemoryTelemetryQueueStore(
          [report('doomed', attempts: TelemetryQueue.defaultMaxAttempts - 1)]));
      final result =
          await queue.flush((_) async => throw Exception('nope'), now: t0);
      expect(result.discarded, 1);
      expect(result.remaining, 0);
    });

    test('the queue is capped, evicting oldest first', () async {
      final queue =
          TelemetryQueue(InMemoryTelemetryQueueStore(), maxItems: 3);
      for (final id in ['1', '2', '3', '4', '5']) {
        await queue.enqueue(report(id));
      }
      expect(
        (await queue.pending()).map((r) => r.eventId).toList(),
        ['3', '4', '5'],
      );
    });

    test('a backwards clock does not stall delivery', () {
      // Mirrors MeasurementThrottle: a far-future timestamp means the
      // device clock moved, not that we should wait years.
      expect(
        report('x', next: t0.add(const Duration(days: 400))).isDue(t0),
        isTrue,
      );
    });
  });

  group('MeasurementThrottle', () {
    final now = DateTime.parse('2026-07-30T12:00:00.000Z');

    test('measures when there is no previous measurement', () {
      expect(
        MeasurementThrottle.isWithinCooldown(
          lastMeasurementAt: null,
          now: now,
        ),
        isFalse,
      );
    });

    test('skips inside the 12 hour window', () {
      expect(
        MeasurementThrottle.isWithinCooldown(
          lastMeasurementAt: now.subtract(const Duration(hours: 11, minutes: 59)),
          now: now,
        ),
        isTrue,
      );
    });

    test('measures once the window has passed', () {
      expect(
        MeasurementThrottle.isWithinCooldown(
          lastMeasurementAt: now.subtract(const Duration(hours: 12, minutes: 1)),
          now: now,
        ),
        isFalse,
      );
    });

    test('the boundary itself is allowed', () {
      // Exactly one cooldown must measure, not skip - otherwise a caller
      // polling on exactly that interval would skip forever.
      expect(
        MeasurementThrottle.isWithinCooldown(
          lastMeasurementAt: now.subtract(const Duration(hours: 12)),
          now: now,
        ),
        isFalse,
      );
    });

    test('a future timestamp measures rather than blocking', () {
      // Device clock moved backwards. Reading this as "within cooldown"
      // would suppress measurement until real time caught up.
      expect(
        MeasurementThrottle.isWithinCooldown(
          lastMeasurementAt: now.add(const Duration(days: 400)),
          now: now,
        ),
        isFalse,
      );
    });

    test('honours a custom cooldown', () {
      expect(
        MeasurementThrottle.isWithinCooldown(
          lastMeasurementAt: now.subtract(const Duration(minutes: 5)),
          now: now,
          cooldown: const Duration(minutes: 1),
        ),
        isFalse,
      );
    });

    test('records and reports through a store', () async {
      final throttle =
          MeasurementThrottle(InMemoryMeasurementTimestampStore());

      expect(await throttle.shouldSkip(now: now), isFalse);
      expect(await throttle.lastMeasurementAt(), isNull);
      expect(await throttle.timeUntilNextAllowed(now: now), isNull);

      await throttle.recordMeasurement(now);

      expect(await throttle.lastMeasurementAt(), now);
      expect(
        await throttle.shouldSkip(now: now.add(const Duration(hours: 1))),
        isTrue,
      );
      expect(
        await throttle.timeUntilNextAllowed(
          now: now.add(const Duration(hours: 1)),
        ),
        const Duration(hours: 11),
      );
      expect(
        await throttle.shouldSkip(now: now.add(const Duration(hours: 13))),
        isFalse,
      );

      await throttle.reset();
      expect(await throttle.shouldSkip(now: now), isFalse);
    });
  });

  group('LocationInfo', () {
    final fix = DateTime.parse('2026-07-30T11:59:30.000Z');
    final now = DateTime.parse('2026-07-30T12:00:00.000Z');

    test('round-trips a full fix', () {
      final original = LocationInfo(
        status: LocationStatus.available,
        latitude: 41.311081,
        longitude: 69.240562,
        accuracyMeters: 12.5,
        altitudeMeters: 455.0,
        speedMps: 1.4,
        headingDegrees: 275.0,
        isMocked: false,
        fixTimestamp: fix,
        timestamp: now,
      );

      final restored = LocationInfo.fromJson(original.toJson());

      expect(restored.latitude, 41.311);
      expect(restored.longitude, 69.241);
      expect(restored.accuracyMeters, 12.5);
      expect(restored.speedMps, 1.4);
      expect(restored.isMocked, isFalse);
      // 11:59:30 rounds down to the 15-minute boundary.
      expect(restored.fixTimestamp, DateTime.parse('2026-07-30T11:45:00.000Z'));
      expect(restored.hasFix, isTrue);
    });

    test('exposes fix age, since a cached fix can be stale', () {
      final info = LocationInfo(
        status: LocationStatus.available,
        latitude: 1,
        longitude: 2,
        fixTimestamp: fix,
        timestamp: now,
      );
      expect(info.fixAge, const Duration(seconds: 30));
    });

    test('a record with no fix carries the reason', () {
      final denied = LocationInfo.unavailable(
        status: LocationStatus.permissionPermanentlyDenied,
        timestamp: now,
      );

      final restored = LocationInfo.fromJson(denied.toJson());

      expect(restored.status, LocationStatus.permissionPermanentlyDenied);
      expect(restored.hasFix, isFalse);
      expect(restored.latitude, isNull);
      expect(restored.fixAge, isNull);
    });

    test('distinguishes the reasons a fix can be missing', () {
      // These must not collapse into one another: "user said no" and
      // "GPS is off" call for different handling.
      for (final status in [
        LocationStatus.permissionDenied,
        LocationStatus.permissionPermanentlyDenied,
        LocationStatus.servicesDisabled,
        LocationStatus.unavailable,
        LocationStatus.notCollected,
      ]) {
        final restored = LocationInfo.fromJson(
          LocationInfo.unavailable(status: status, timestamp: now).toJson(),
        );
        expect(restored.status, status);
      }
    });

    test('unknown status parses as notCollected', () {
      expect(LocationStatus.fromName('bogus'), LocationStatus.notCollected);
      expect(LocationStatus.fromName(null), LocationStatus.notCollected);
    });
  });

  group('PermissionStatuses', () {
    test('requires every permission to be granted', () {
      const bothGranted = PermissionStatuses(
        fineLocation: PermissionState.granted,
        phoneState: PermissionState.granted,
      );
      const onlyLocation = PermissionStatuses(
        fineLocation: PermissionState.granted,
        phoneState: PermissionState.denied,
      );

      expect(bothGranted.hasRequiredPermissions, isTrue);
      // Android returns an empty cell list unless *both* are held.
      expect(onlyLocation.hasRequiredPermissions, isFalse);
    });

    test('treats notRequired as satisfied', () {
      const iosLike = PermissionStatuses.notRequired();
      expect(iosLike.hasRequiredPermissions, isTrue);
      expect(iosLike.isPermanentlyDenied, isFalse);
    });

    test('flags permanent denial on any permission', () {
      const statuses = PermissionStatuses(
        fineLocation: PermissionState.granted,
        phoneState: PermissionState.permanentlyDenied,
      );
      expect(statuses.isPermanentlyDenied, isTrue);
      expect(statuses.hasRequiredPermissions, isFalse);
    });

    test('round-trips through JSON', () {
      const original = PermissionStatuses(
        fineLocation: PermissionState.permanentlyDenied,
        phoneState: PermissionState.granted,
      );
      final restored = PermissionStatuses.fromJson(original.toJson());
      expect(restored.fineLocation, PermissionState.permanentlyDenied);
      expect(restored.phoneState, PermissionState.granted);
    });

    test('parses the state strings the Kotlin side emits', () {
      // Must stay in sync with PermissionChannelHandler.kt.
      for (final name in ['granted', 'denied', 'permanentlyDenied']) {
        expect(PermissionState.fromName(name).name, name);
      }
    });

    test('falls back to denied rather than granted on unknown input', () {
      // Guessing "granted" would silently yield empty cellular metrics.
      expect(PermissionState.fromName('bogus'), PermissionState.denied);
      expect(PermissionState.fromName(null), PermissionState.denied);
    });
  });

  group('enum parsing', () {
    test('falls back to safe defaults on unknown values', () {
      expect(ConnectionType.fromName('bogus'), ConnectionType.none);
      expect(ConnectionType.fromName(null), ConnectionType.none);
      expect(CellularGeneration.fromName('bogus'), CellularGeneration.unknown);
      expect(DataNetworkType.fromName('bogus'), DataNetworkType.unknown);
    });

    test('parses the values the Kotlin side emits', () {
      // These strings are produced by ConnectivityChannelHandler.kt and must
      // stay in sync with the Dart enum names.
      for (final name in ['g2', 'g3', 'g4', 'g5', 'unknown']) {
        expect(CellularGeneration.fromName(name).name, name);
      }
      for (final name in [
        'gprs', 'edge', 'umts', 'hsdpa', 'hsupa', 'hspa', 'hspap',
        'cdma', 'evdo0', 'evdoA', 'evdoB', 'ehrpd', 'lte', 'lteCa',
        'nr', 'gsm', 'tdScdma', 'iwlan', 'unknown',
      ]) {
        expect(DataNetworkType.fromName(name).name, name);
      }
    });
  });

  group('wire privacy', () {
    test('coordinates are rounded to 3 decimal places', () {
      expect(coarsenCoordinate(41.311081), 41.311);
      expect(coarsenCoordinate(69.240562), 69.241);
      expect(coarsenCoordinate(-0.0004), -0.0);
      expect(coarsenCoordinate(null), isNull);
    });

    test('timestamps round down to 15 minutes, in UTC', () {
      expect(wireTimestamp(DateTime.parse('2026-07-30T12:14:59.999Z')),
          '2026-07-30T12:00:00.000Z');
      expect(wireTimestamp(DateTime.parse('2026-07-30T12:15:00.000Z')),
          '2026-07-30T12:15:00.000Z');
      // Local times are converted first: 17:20 at UTC+5 is 12:20Z.
      expect(wireTimestamp(DateTime.parse('2026-07-30T17:20:00+05:00')),
          '2026-07-30T12:15:00.000Z');
    });

    test('every serialized timestamp is coarsened', () {
      final t = DateTime.parse('2026-07-30T12:07:42.123Z');
      const expected = '2026-07-30T12:00:00.000Z';
      final json = NetworkQualitySnapshot(
        sessionId: 's',
        timestamp: t,
        connectivityInfo:
            ConnectivityInfo(connectionType: ConnectionType.wifi, timestamp: t),
        cellularInfo: CellularInfo(timestamp: t),
        deviceContext: DeviceContext(isAppInForeground: true, timestamp: t),
        locationInfo: LocationInfo(
          status: LocationStatus.available,
          latitude: 41.311081,
          longitude: 69.240562,
          fixTimestamp: t,
          timestamp: t,
        ),
      ).toJson();

      expect(json['timestamp'], expected);
      for (final section in [
        'connectivityInfo',
        'cellularInfo',
        'deviceContext',
        'locationInfo',
      ]) {
        expect((json[section] as Map)['timestamp'], expected, reason: section);
      }
      expect((json['locationInfo'] as Map)['fixTimestamp'], expected);
      expect(
        ActiveMeasurement(
          sessionId: 's',
          timestamp: t,
          connectionType: ConnectionType.cellular,
        ).toJson()['timestamp'],
        expected,
      );
    });
  });

  group('GnssInfo', () {
    final t = DateTime.parse('2026-07-30T12:00:00.000Z');
    GnssInfo ok({required int visible, double? cn0, int used = 0}) => GnssInfo(
          status: GnssSampleStatus.ok,
          satellitesUsed: used,
          satellitesVisible: visible,
          topCn0DbHz: cn0,
          sampleSeconds: 6,
          timestamp: t,
        );

    test('many strong satellites lean outdoors', () {
      expect(ok(visible: 12, cn0: 40, used: 9).environmentHint,
          EnvironmentHint.likelyOutdoors);
      // Engine still starting: nothing used in a fix yet, signal says open sky.
      expect(ok(visible: 8, cn0: 36).environmentHint,
          EnvironmentHint.likelyOutdoors);
    });

    test('few or weak satellites lean indoors', () {
      expect(ok(visible: 2, cn0: 38).environmentHint,
          EnvironmentHint.likelyIndoors);
      expect(ok(visible: 9, cn0: 20).environmentHint,
          EnvironmentHint.likelyIndoors);
      expect(ok(visible: 0).environmentHint, EnvironmentHint.likelyIndoors);
      expect(
        GnssInfo.unavailable(status: GnssSampleStatus.noData, timestamp: t)
            .environmentHint,
        EnvironmentHint.likelyIndoors,
      );
    });

    test('mixed hints fall in between', () {
      expect(ok(visible: 5, cn0: 36).environmentHint, EnvironmentHint.inBetween);
      expect(ok(visible: 10, cn0: 29).environmentHint, EnvironmentHint.inBetween);
    });

    test('no data source means unknown, not indoors', () {
      for (final status in [
        GnssSampleStatus.permissionDenied,
        GnssSampleStatus.gpsDisabled,
        GnssSampleStatus.unsupported,
      ]) {
        expect(
          GnssInfo.unavailable(status: status, timestamp: t).environmentHint,
          EnvironmentHint.unknown,
          reason: status.name,
        );
      }
    });

    test('round-trips inside a snapshot, and old snapshots still parse', () {
      final snapshot = NetworkQualitySnapshot(
        sessionId: 's',
        timestamp: t,
        connectivityInfo:
            ConnectivityInfo(connectionType: ConnectionType.cellular, timestamp: t),
        deviceContext: DeviceContext(isAppInForeground: true, timestamp: t),
        locationInfo:
            LocationInfo.unavailable(status: LocationStatus.unavailable, timestamp: t),
        gnssInfo: ok(visible: 11, cn0: 41.5, used: 8),
      );
      final restored = NetworkQualitySnapshot.fromJson(snapshot.toJson());
      expect(restored.gnssInfo!.status, GnssSampleStatus.ok);
      expect(restored.gnssInfo!.satellitesUsed, 8);
      expect(restored.gnssInfo!.satellitesVisible, 11);
      expect(restored.gnssInfo!.topCn0DbHz, 41.5);

      final legacy = snapshot.toJson()..remove('gnssInfo');
      expect(NetworkQualitySnapshot.fromJson(legacy).gnssInfo, isNull);
    });
  });

  group('new data fields', () {
    final t = DateTime.parse('2026-07-30T12:00:00.000Z');

    test('CellularInfo round-trips band, channel and neighbours', () {
      final original = CellularInfo(
        technology: 'lte',
        rsrp: -95,
        arfcn: 1300,
        band: 3,
        bandwidthKhz: 20000,
        neighborCells: const [
          NeighborCell(technology: 'lte', pci: 101, arfcn: 1300, rsrp: -104),
          NeighborCell(technology: 'wcdma', pci: 22, rscp: -88),
        ],
        timestamp: t,
      );
      final restored = CellularInfo.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);
      expect(restored.technology, 'lte');
      expect(restored.band, 3);
      expect(restored.arfcn, 1300);
      expect(restored.bandwidthKhz, 20000);
      expect(restored.neighborCells, hasLength(2));
      expect(restored.neighborCells[0].pci, 101);
      expect(restored.neighborCells[1].rscp, -88);
    });

    test('older reports without the new fields still parse', () {
      final cellular = CellularInfo(rsrp: -90, timestamp: t).toJson()
        ..remove('neighborCells')
        ..remove('band');
      expect(CellularInfo.fromJson(cellular).neighborCells, isEmpty);

      final measurement = ActiveMeasurement(
        sessionId: 's',
        timestamp: t,
        connectionType: ConnectionType.cellular,
      ).toJson()
        ..remove('packetLossPercent');
      expect(ActiveMeasurement.fromJson(measurement).packetLossPercent, isNull);
    });

    test('ConnectivityInfo round-trips the new network fields', () {
      final restored = ConnectivityInfo.fromJson(ConnectivityInfo(
        connectionType: ConnectionType.cellular,
        serviceState: 'inService',
        overrideNetworkType: 'nrNsa',
        aggregatedChannelCount: 2,
        aggregatedBandwidthKhz: 35000,
        isValidated: true,
        estimatedDownstreamKbps: 48000,
        hasIpv6: true,
        isLowDataMode: false,
        activeSimCount: 2,
        otherSimMcc: '434',
        timestamp: t,
      ).toJson());
      expect(restored.serviceState, 'inService');
      expect(restored.overrideNetworkType, 'nrNsa');
      expect(restored.aggregatedChannelCount, 2);
      expect(restored.estimatedDownstreamKbps, 48000);
      expect(restored.hasIpv6, isTrue);
      expect(restored.activeSimCount, 2);
      expect(restored.otherSimMcc, '434');
    });

    test('ActiveMeasurement round-trips loss, TTFB and bytes', () {
      final restored = ActiveMeasurement.fromJson(ActiveMeasurement(
        sessionId: 's',
        timestamp: t,
        connectionType: ConnectionType.cellular,
        packetLossPercent: 9.1,
        ttfbMs: 142.5,
        downloadBytes: 10485760,
        uploadBytes: 2097152,
      ).toJson());
      expect(restored.packetLossPercent, 9.1);
      expect(restored.ttfbMs, 142.5);
      expect(restored.downloadBytes, 10485760);
      expect(restored.uploadBytes, 2097152);
    });

    test('snapshot carries radioStats and environmentInfo', () {
      final snapshot = NetworkQualitySnapshot(
        sessionId: 's',
        timestamp: t,
        connectivityInfo:
            ConnectivityInfo(connectionType: ConnectionType.cellular, timestamp: t),
        deviceContext: DeviceContext(
          isAppInForeground: true,
          isPowerSaveMode: true,
          thermalStatus: 'moderate',
          timestamp: t,
        ),
        locationInfo:
            LocationInfo.unavailable(status: LocationStatus.unavailable, timestamp: t),
        radioStats: RadioStats(
          windowSeconds: 300,
          handoverCount: 4,
          secondsOn4g: 240,
          secondsOn5g: 50,
          secondsOutOfService: 10,
          timestamp: t,
        ),
        environmentInfo: EnvironmentInfo(
          ambientLux: 12000,
          accelStdDevMps2: 0.02,
          wifiNetworksVisible: 3,
          wifiStrongestRssiDbm: -81,
          sampleSeconds: 6,
          timestamp: t,
        ),
      );
      final restored = NetworkQualitySnapshot.fromJson(
          jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, dynamic>);
      expect(restored.radioStats!.handoverCount, 4);
      expect(restored.radioStats!.secondsOutOfService, 10);
      expect(restored.environmentInfo!.ambientLux, 12000);
      expect(restored.environmentInfo!.wifiNetworksVisible, 3);
      expect(restored.deviceContext.isPowerSaveMode, isTrue);
      expect(restored.deviceContext.thermalStatus, 'moderate');
    });

    test('motion hint: still, moving, vehicle, unknown', () {
      EnvironmentInfo env(double? spread) =>
          EnvironmentInfo(accelStdDevMps2: spread, timestamp: t);
      expect(env(0.02).motionHint(), MotionHint.still);
      expect(env(1.4).motionHint(), MotionHint.moving);
      expect(env(0.1).motionHint(speedMps: 15), MotionHint.inVehicle);
      expect(env(null).motionHint(), MotionHint.unknown);
    });
  });

  group('userReportedEnvironment', () {
    final t = DateTime.parse('2026-07-30T12:00:00.000Z');

    // Asking indoors/outdoors is the host app's job; the SDK sends no key.
    test('is not part of either report', () {
      final snapshot = NetworkQualitySnapshot(
        sessionId: 's',
        timestamp: t,
        connectivityInfo:
            ConnectivityInfo(connectionType: ConnectionType.cellular, timestamp: t),
        deviceContext: DeviceContext(isAppInForeground: true, timestamp: t),
        locationInfo:
            LocationInfo.unavailable(status: LocationStatus.unavailable, timestamp: t),
      );
      final measurement = ActiveMeasurement(
        sessionId: 's',
        timestamp: t,
        connectionType: ConnectionType.cellular,
      );
      expect(snapshot.toJson().containsKey('userReportedEnvironment'), isFalse);
      expect(
          measurement.toJson().containsKey('userReportedEnvironment'), isFalse);
    });
  });
}

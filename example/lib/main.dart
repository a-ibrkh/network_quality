import 'package:flutter/material.dart';
import 'package:network_quality/network_quality.dart';

/// Backend this demo reports to. Host apps pass their own.
final Uri _backendUrl = Uri.parse('https://dev.uzproger.ru');

/// The user's own answer to "indoors or outdoors?". Asking is the host
/// app's job, not the SDK's; this demo asks and shows the answer.
enum UserEnvironment { indoors, outdoors }

void main() {
  // Plugins (connectivity, battery, device info, geolocator, prefs) are
  // touched before the first frame, so the binding must exist first.
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NetworkQualityDemoApp());
}

class NetworkQualityDemoApp extends StatelessWidget {
  const NetworkQualityDemoApp({super.key});

  static const _seed = Color(0xFF3B6FF5);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Network Quality',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const DashboardPage(),
    );
  }

  ThemeData _theme(Brightness brightness) {
    final scheme =
        ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? scheme.surface
          : const Color(0xFFF6F7FB),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        color: brightness == Brightness.dark
            ? scheme.surfaceContainerHigh
            : Colors.white,
      ),
    );
  }
}

/// Which stage of a run is currently executing, for progress reporting.
enum RunStage { idle, permissions, snapshot, activeTest, asking, sending, done }

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  /// Held rather than constructed per run so the sessionId stays stable for
  /// the app's lifetime, which is what correlates snapshots with results.
  late final NetworkQualityService _service;

  NetworkQualitySnapshot? _snapshot;
  ActiveMeasurement? _measurement;
  PermissionStatuses? _permissions;
  DateTime? _lastMeasurementAt;
  Duration? _nextAllowedIn;

  RunStage _stage = RunStage.idle;
  String? _error;
  String? _locationSendResult;
  String? _speedtestSendResult;
  int _downloadBytes = 0;
  int _uploadBytes = 0;
  int _pendingTelemetry = 0;

  /// The user's answer for the latest run; null when skipped.
  UserEnvironment? _userEnvironment;

  /// Mirrors the SDK default. Exposed because a demo is usually run on
  /// Wi-Fi, where the default would (correctly) skip every measurement.
  bool _cellularOnly = true;

  bool get _busy => _stage != RunStage.idle && _stage != RunStage.done;

  @override
  void initState() {
    super.initState();
    _service = NetworkQualityService(
      config: NetworkQualityConfig(baseUrl: _backendUrl),
    );
    // Measure on launch, honouring the cooldown so its behaviour is visible.
    WidgetsBinding.instance.addPostFrameCallback((_) => _run(force: false));
  }

  Future<void> _run({required bool force}) async {
    if (_busy) return;
    setState(() {
      _stage = RunStage.permissions;
      _error = null;
      _userEnvironment = null;
      _locationSendResult = null;
      _speedtestSendResult = null;
    });

    try {
      var permissions = await _service.checkPermissions();
      if (!permissions.hasRequiredPermissions &&
          !permissions.isPermanentlyDenied) {
        permissions = await _service.requestPermissions();
      }
      if (!mounted) return;
      setState(() {
        _permissions = permissions;
        _stage = RunStage.snapshot;
      });

      final snapshot = await _service.collectSnapshot();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _stage = RunStage.activeTest;
      });

      final measurement = await _service.runActiveTest(
        cellularOnly: _cellularOnly,
        ignoreCooldown: force,
      );
      if (!mounted) return;
      setState(() {
        _measurement = measurement;
        _downloadBytes = measurement.downloadBytes ?? 0;
        _uploadBytes = measurement.uploadBytes ?? 0;
        _stage = RunStage.asking;
      });

      // A client-side check on the SDK's indoor/outdoor hints. The SDK
      // doesn't send it; the answer is only shown on screen here.
      final answer = await _askEnvironment();
      if (!mounted) return;
      setState(() {
        _userEnvironment = answer;
        _stage = RunStage.sending;
      });

      // Reports are queued to disk before sending, so these never throw -
      // a failure leaves the report queued rather than losing it.
      final locationFlush = await _service.sendSnapshot(snapshot);
      _locationSendResult = _describeFlush(locationFlush);
      final speedtestFlush = await _service.sendTestResult(measurement);
      _speedtestSendResult = _describeFlush(speedtestFlush);
      final pending = await _service.pendingTelemetryCount();

      final last = await _service.lastMeasurementAt();
      final next = await _service.timeUntilNextMeasurement();
      if (!mounted) return;
      setState(() {
        _lastMeasurementAt = last;
        _nextAllowedIn = next;
        _pendingTelemetry = pending;
        _stage = RunStage.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _stage = RunStage.done;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _run(force: true),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _header(theme)),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
                sliver: SliverList.list(children: _sections(theme)),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: _measureButton(theme),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  // ---------------------------------------------------------------- header

  Widget _header(ThemeData theme) {
    final m = _measurement;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.primary,
            Color.alphaBlend(
              Colors.black.withValues(alpha: 0.22),
              theme.colorScheme.primary,
            ),
          ],
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cell_tower, color: Colors.white, size: 26),
              const SizedBox(width: 10),
              Text(
                'Network Quality',
                style: theme.textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              _statusPill(theme),
            ],
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: _heroMetric(
                  theme,
                  Icons.download_rounded,
                  'Download',
                  _fmtNum(m?.downloadMbps, 1),
                  'Mbps',
                ),
              ),
              _heroDivider(),
              Expanded(
                child: _heroMetric(
                  theme,
                  Icons.upload_rounded,
                  'Upload',
                  _fmtNum(m?.uploadMbps, 1),
                  'Mbps',
                ),
              ),
              _heroDivider(),
              Expanded(
                child: _heroMetric(
                  theme,
                  Icons.timer_outlined,
                  'Latency',
                  _fmtNum(m?.latencyMs, 0),
                  'ms',
                ),
              ),
            ],
          ),
          if (m != null && m.wasSkipped) ...[
            const SizedBox(height: 18),
            _skipBanner(theme, m.skipReason!),
          ],
          if (_error != null) ...[
            const SizedBox(height: 18),
            _errorBanner(theme, _error!),
          ],
        ],
      ),
    );
  }

  Widget _heroDivider() => Container(
        width: 1,
        height: 42,
        color: Colors.white.withValues(alpha: 0.22),
      );

  Widget _heroMetric(
    ThemeData theme,
    IconData icon,
    String label,
    String value,
    String unit,
  ) {
    return Column(
      children: [
        Icon(icon, color: Colors.white.withValues(alpha: 0.75), size: 18),
        const SizedBox(height: 6),
        RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            children: [
              TextSpan(
                text: value,
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              TextSpan(
                text: ' $unit',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: Colors.white.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }

  Widget _statusPill(ThemeData theme) {
    final (label, icon) = switch (_stage) {
      RunStage.idle => ('Idle', Icons.circle_outlined),
      RunStage.permissions => ('Permissions', Icons.lock_outline),
      RunStage.snapshot => ('Snapshot', Icons.sensors),
      RunStage.activeTest => ('Measuring', Icons.speed),
      RunStage.asking => ('Your answer', Icons.help_outline),
      RunStage.sending => ('Sending', Icons.cloud_upload_outlined),
      RunStage.done => ('Ready', Icons.check_circle_outline),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_busy)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          else
            Icon(icon, size: 13, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _skipBanner(ThemeData theme, MeasurementSkipReason reason) {
    final (text, hint) = switch (reason) {
      MeasurementSkipReason.notCellular => (
          'Skipped — not on cellular',
          'Turn off "Cellular only" to measure anyway.'
        ),
      MeasurementSkipReason.recentlyMeasured => (
          'Skipped — measured recently',
          'Cooldown is ${_fmtDuration(_service.config.measurementCooldown)}. '
              'Tap Measure to force a run.',
        ),
    };
    return _banner(theme, Icons.info_outline, text, hint);
  }

  Widget _errorBanner(ThemeData theme, String error) =>
      _banner(theme, Icons.error_outline, 'Run failed', error);

  Widget _banner(ThemeData theme, IconData icon, String title, String body) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- sections

  List<Widget> _sections(ThemeData theme) {
    final snapshot = _snapshot;
    final m = _measurement;
    final connectivity = snapshot?.connectivityInfo;
    final cellular = snapshot?.cellularInfo;
    final location = snapshot?.locationInfo;
    final gnss = snapshot?.gnssInfo;
    final environment = snapshot?.environmentInfo;
    final radio = snapshot?.radioStats;
    final device = snapshot?.deviceContext;

    return [
      const SizedBox(height: 20),
      _card(theme, 'Run', Icons.tune, [
        _SwitchRow(
          label: 'Cellular only',
          subtitle: 'SDK default. Skips measuring on Wi-Fi.',
          value: _cellularOnly,
          onChanged: _busy ? null : (v) => setState(() => _cellularOnly = v),
        ),
        _row('Session ID', _service.sessionId, mono: true),
        _row(
            'You said',
            switch (_userEnvironment) {
              UserEnvironment.indoors => 'Indoors',
              UserEnvironment.outdoors => 'Outdoors',
              null => _stage == RunStage.done ? 'Skipped' : '—',
            }),
        _row('Last measured', _fmtTime(_lastMeasurementAt)),
        _row(
            'Next automatic',
            _nextAllowedIn == null
                ? 'Now'
                : 'in ${_fmtDuration(_nextAllowedIn!)}'),
        _row('Cooldown', _fmtDuration(_service.config.measurementCooldown)),
        _row(
            'Data used',
            _downloadBytes + _uploadBytes == 0
                ? '—'
                : '${_fmtMb(_downloadBytes + _uploadBytes)} '
                    '(↓${_fmtMb(_downloadBytes)} ↑${_fmtMb(_uploadBytes)})'),
      ]),
      _card(
        theme,
        'Telemetry',
        Icons.cloud_upload_outlined,
        [
          _row('Location report', _locationSendResult ?? '—',
              status: _statusOf(_locationSendResult)),
          _row('Speedtest report', _speedtestSendResult ?? '—',
              status: _statusOf(_speedtestSendResult)),
          _row('Queued for retry', '$_pendingTelemetry',
              status: _pendingTelemetry > 0 ? _RowStatus.warn : null),
          _row('Base URL', _service.config.baseUrl.toString(), mono: true),
        ],
        footnote: 'Reports are written to disk before sending, so a failed '
            'send is retried with backoff rather than lost.',
      ),
      _card(theme, 'Permissions', Icons.lock_outline, [
        _row('Fine location', _permissions?.fineLocation.name ?? '—',
            status: _permStatus(_permissions?.fineLocation)),
        _row('Phone state', _permissions?.phoneState.name ?? '—',
            status: _permStatus(_permissions?.phoneState)),
      ]),
      _card(theme, 'Active measurement', Icons.speed, [
        _row('Download', _unit(m?.downloadMbps, 'Mbps', 2)),
        _row('Upload', _unit(m?.uploadMbps, 'Mbps', 2)),
        _row('Latency', _unit(m?.latencyMs, 'ms', 1)),
        _row('Jitter', _unit(m?.jitterMs, 'ms', 2)),
        _row('DNS resolution', _unit(m?.dnsResolutionMs, 'ms', 1)),
        _row('TCP connect', _unit(m?.tcpConnectionMs, 'ms', 1)),
        _row('TLS handshake', _unit(m?.tlsHandshakeMs, 'ms', 1)),
        _row('Packet loss', _unit(m?.packetLossPercent, '%', 1)),
        _row('Time to first byte', _unit(m?.ttfbMs, 'ms', 1)),
        _row(
            'Bytes ↓ / ↑',
            m?.downloadBytes == null && m?.uploadBytes == null
                ? '—'
                : '${_fmtMb(m?.downloadBytes ?? 0)} / ${_fmtMb(m?.uploadBytes ?? 0)}'),
        _row('Connection at test', m?.connectionType.name ?? '—'),
        _row('Skip reason', m?.skipReason?.name ?? 'none'),
        _row('Measured at', _fmtTime(m?.timestamp)),
      ]),
      _card(theme, 'Connectivity', Icons.wifi_tethering, [
        _row('Type', connectivity?.connectionType.name ?? '—'),
        _row('Carrier', connectivity?.carrierName ?? '—'),
        _row(
            'MCC / MNC',
            connectivity == null
                ? '—'
                : '${connectivity.mcc ?? '—'} / ${connectivity.mnc ?? '—'}'),
        _row('Generation', connectivity?.cellularGeneration?.name ?? '—'),
        _row('Data network', connectivity?.dataNetworkType?.name ?? '—'),
        _row('VPN active', _bool(connectivity?.isVpnActive)),
        _row('Metered', _bool(connectivity?.isMetered)),
        _row('Airplane mode', _bool(connectivity?.isAirplaneModeOn)),
        _row('Data roaming', _bool(connectivity?.isDataRoaming)),
        _row('Service state', connectivity?.serviceState ?? '—',
            status: connectivity?.serviceState == null
                ? null
                : connectivity!.serviceState == 'inService'
                    ? _RowStatus.good
                    : _RowStatus.bad),
        _row(
            'Shown as (5G NSA etc.)', connectivity?.overrideNetworkType ?? '—'),
        _row(
            'Carrier aggregation',
            connectivity?.aggregatedChannelCount == null
                ? '—'
                : '${connectivity!.aggregatedChannelCount} ch, '
                    '${_fmtNum((connectivity.aggregatedBandwidthKhz ?? 0) / 1000, 0)} MHz'),
        _row('Internet validated', _bool(connectivity?.isValidated)),
        _row('Captive portal', _bool(connectivity?.isCaptivePortal)),
        _row('Congested', _bool(connectivity?.isCongested)),
        _row(
            'OS estimate ↓ / ↑',
            connectivity?.estimatedDownstreamKbps == null
                ? '—'
                : '${_fmtNum(connectivity!.estimatedDownstreamKbps! / 1000, 1)} / '
                    '${_fmtNum((connectivity.estimatedUpstreamKbps ?? 0) / 1000, 1)} Mbps'),
        _row('MTU', _unit(connectivity?.mtu, 'B', 0)),
        _row(
            'IPv4 / IPv6',
            connectivity == null
                ? '—'
                : '${_bool(connectivity.hasIpv4)} / ${_bool(connectivity.hasIpv6)}'),
        _row('Private DNS', _bool(connectivity?.isPrivateDnsActive)),
        _row('Data saver / Low Data', _bool(connectivity?.isLowDataMode)),
        _row('Active SIMs', _fmtNum(connectivity?.activeSimCount, 0)),
        _row('Data SIM slot', _fmtNum(connectivity?.dataSimSlot, 0)),
        _row(
            'Other SIM',
            connectivity?.otherSimCarrierName == null
                ? '—'
                : '${connectivity!.otherSimCarrierName} '
                    '(${connectivity.otherSimMcc ?? '—'}/${connectivity.otherSimMnc ?? '—'})'),
      ]),
      _card(
        theme,
        'Cellular radio',
        Icons.signal_cellular_alt,
        [
          if (cellular?.signalLevel != null)
            _SignalRow(level: cellular!.signalLevel!),
          _row('Technology', cellular?.technology ?? '—'),
          _row('Band', cellular?.band == null ? '—' : 'B${cellular!.band}'),
          _row('Channel (ARFCN)', _fmtNum(cellular?.arfcn, 0)),
          _row(
              'Bandwidth',
              _unit(
                  cellular?.bandwidthKhz == null
                      ? null
                      : cellular!.bandwidthKhz! / 1000,
                  'MHz',
                  1)),
          _row('RSSI', _unit(cellular?.rssi, 'dBm', 0)),
          _row('RSCP (3G)', _unit(cellular?.rscp, 'dBm', 0)),
          _row(
              'CSI-RSRP / RSRQ / SINR (5G)',
              cellular?.csiRsrp == null
                  ? '—'
                  : '${cellular!.csiRsrp} / ${cellular.csiRsrq ?? '—'} / '
                      '${cellular.csiSinr ?? '—'}'),
          _row('RSRP', _unit(cellular?.rsrp, 'dBm', 0)),
          _row('RSRQ', _unit(cellular?.rsrq, 'dB', 0)),
          _row('RSSNR / SINR', _unit(cellular?.rssnr, 'dB', 0)),
          _row('CQI', _fmtNum(cellular?.cqi, 0)),
          _row('ASU level', _fmtNum(cellular?.asuLevel, 0)),
          _row('Cell ID', _fmtNum(cellular?.cellId, 0), mono: true),
          _row('PCI', _fmtNum(cellular?.pci, 0)),
          _row('LAC', _fmtNum(cellular?.lac, 0)),
          _row('TAC', _fmtNum(cellular?.tac, 0)),
          _row('Timing advance', _fmtNum(cellular?.timingAdvance, 0)),
          _row('Registered', _bool(cellular?.isRegistered)),
          _row('Radio tech (iOS)', cellular?.radioAccessTechnology ?? '—'),
          _row('Neighbour cells',
              cellular == null ? '—' : '${cellular.neighborCells.length}'),
          for (final n
              in cellular?.neighborCells.take(5) ?? const <NeighborCell>[])
            _row('  ${n.technology ?? '?'} PCI ${n.pci ?? '—'}',
                '${n.rsrp ?? n.rscp ?? n.rssi ?? '—'} dBm',
                mono: true),
        ],
        footnote:
            'iOS exposes no signal-strength API — these stay empty there.',
      ),
      _card(
        theme,
        'Location',
        Icons.place_outlined,
        [
          _row('Status', location?.status.name ?? '—',
              status: location?.status == LocationStatus.available
                  ? _RowStatus.good
                  : (location == null ? null : _RowStatus.warn)),
          _row('Latitude', _fmtNum(location?.latitude, 6), mono: true),
          _row('Longitude', _fmtNum(location?.longitude, 6), mono: true),
          _row('Accuracy', _unit(location?.accuracyMeters, 'm', 1)),
          _row('Altitude', _unit(location?.altitudeMeters, 'm', 1)),
          _row('Speed', _unit(location?.speedMps, 'm/s', 2)),
          _row('Heading', _unit(location?.headingDegrees, '°', 0)),
          _row('Mocked', _bool(location?.isMocked),
              status: location?.isMocked == true ? _RowStatus.bad : null),
          _row('Fix taken at', _fmtTime(location?.fixTimestamp)),
          _row('Fix age',
              location?.fixAge == null ? '—' : _fmtDuration(location!.fixAge!)),
          _row(
              'Satellites used / seen',
              gnss?.status == GnssSampleStatus.ok
                  ? '${gnss!.satellitesUsed ?? 0} / ${gnss.satellitesVisible ?? 0}'
                  : (gnss?.status.name ?? '—')),
          _row('Satellite signal (top 4)', _unit(gnss?.topCn0DbHz, 'dB-Hz', 1)),
        ],
        footnote: _environmentText(gnss),
      ),
      _card(
        theme,
        'Radio activity',
        Icons.swap_horiz,
        [
          _row(
              'Window',
              radio?.windowSeconds == null
                  ? '—'
                  : _fmtDuration(
                      Duration(seconds: radio!.windowSeconds!.round()))),
          _row('Handovers', _fmtNum(radio?.handoverCount, 0)),
          _row(
              '2G / 3G',
              radio == null
                  ? '—'
                  : '${_fmtNum(radio.secondsOn2g, 0)}s / ${_fmtNum(radio.secondsOn3g, 0)}s'),
          _row(
              '4G / 5G',
              radio == null
                  ? '—'
                  : '${_fmtNum(radio.secondsOn4g, 0)}s / ${_fmtNum(radio.secondsOn5g, 0)}s'),
          _row(
              'Out of service',
              radio?.secondsOutOfService == null
                  ? '—'
                  : '${_fmtNum(radio!.secondsOutOfService, 0)}s',
              status: (radio?.secondsOutOfService ?? 0) > 0
                  ? _RowStatus.warn
                  : null),
        ],
        footnote: 'Since the previous reading, while the app was running.',
      ),
      _card(
        theme,
        'Surroundings',
        Icons.explore_outlined,
        [
          _row('Ambient light', _unit(environment?.ambientLux, 'lux', 0)),
          _row('Motion (accel spread)',
              _unit(environment?.accelStdDevMps2, 'm/s²', 2)),
          _row('Wi-Fi networks seen',
              _fmtNum(environment?.wifiNetworksVisible, 0)),
          _row('Strongest Wi-Fi',
              _unit(environment?.wifiStrongestRssiDbm, 'dBm', 0)),
        ],
        footnote: environment == null
            ? null
            : switch (environment.motionHint(speedMps: location?.speedMps)) {
                MotionHint.still => 'Phone was still.',
                MotionHint.moving => 'Phone was moving (walking or handled).',
                MotionHint.inVehicle =>
                  'Likely in a vehicle (GPS speed above 7 m/s).',
                MotionHint.unknown => 'Motion unknown: no motion sensor data.',
              },
      ),
      _card(theme, 'Device', Icons.smartphone, [
        _row('Model', device?.deviceModel ?? '—'),
        _row('OS version', device?.osVersion ?? '—'),
        _row('Battery', _unit(device?.batteryLevel, '%', 0)),
        _row('Charging', _bool(device?.isCharging)),
        _row('App in foreground', _bool(device?.isAppInForeground)),
        _row('Battery saver', _bool(device?.isPowerSaveMode),
            status: device?.isPowerSaveMode == true ? _RowStatus.warn : null),
        _row('Thermal', device?.thermalStatus ?? '—',
            status:
                device?.thermalStatus == null || device!.thermalStatus == 'none'
                    ? null
                    : _RowStatus.warn),
        _row('Snapshot at', _fmtTime(snapshot?.timestamp)),
      ]),
    ];
  }

  Widget _card(
    ThemeData theme,
    String title,
    IconData icon,
    List<Widget> children, {
    String? footnote,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 17, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.1,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ...children,
              if (footnote != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 6, 0, 8),
                  child: Text(
                    footnote,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value,
          {bool mono = false, _RowStatus? status}) =>
      _DataRow(label: label, value: value, mono: mono, status: status);

  Widget _measureButton(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: SizedBox(
        width: double.infinity,
        height: 54,
        child: FilledButton.icon(
          // Forces past the cooldown: a demo needs the button to always do
          // something, and it doubles as the user-initiated "test again".
          onPressed: _busy ? null : () => _run(force: true),
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                )
              : const Icon(Icons.play_arrow_rounded),
          label: Text(
            _busy ? _stageLabel() : 'Measure',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ),
    );
  }

  String _stageLabel() => switch (_stage) {
        RunStage.permissions => 'Checking permissions…',
        RunStage.snapshot => 'Reading device & GPS…',
        RunStage.activeTest => 'Running speed test…',
        RunStage.asking => 'Waiting for your answer…',
        RunStage.sending => 'Sending…',
        _ => 'Working…',
      };

  // ------------------------------------------------------------ formatting

  /// A flush can deliver more than the report just submitted, if a backlog
  /// was waiting - so report both.
  String _describeFlush(FlushResult r) {
    if (r.sent > 0 && r.remaining == 0) {
      return r.sent == 1 ? 'Sent' : 'Sent ${r.sent}';
    }
    if (r.sent > 0) return 'Sent ${r.sent}, ${r.remaining} queued';
    if (r.discarded > 0 && r.remaining == 0) return 'Discarded (too old)';
    return 'Queued for retry';
  }

  _RowStatus? _statusOf(String? result) => switch (result) {
        null => null,
        _ when result.startsWith('Sent') => _RowStatus.good,
        _ => _RowStatus.warn,
      };

  _RowStatus? _permStatus(PermissionState? state) => switch (state) {
        null => null,
        PermissionState.granted => _RowStatus.good,
        PermissionState.notRequired => null,
        PermissionState.denied => _RowStatus.warn,
        PermissionState.permanentlyDenied => _RowStatus.bad,
      };

  String _bool(bool? value) => value == null ? '—' : (value ? 'Yes' : 'No');

  /// Asks where the measurement was taken. Returns null when the user
  /// skips or dismisses the sheet - the reports are sent either way.
  Future<UserEnvironment?> _askEnvironment() {
    return showModalBottomSheet<UserEnvironment>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        Widget option(UserEnvironment value, IconData icon, String label) {
          return Expanded(
            child: FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).pop(value),
              icon: Icon(icon),
              label: Text(label),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                textStyle:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Where were you during this measurement?',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  'Walls weaken mobile signal, so this helps us read the '
                  'results correctly.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    option(UserEnvironment.indoors, Icons.home_outlined,
                        'Indoors'),
                    const SizedBox(width: 12),
                    option(UserEnvironment.outdoors, Icons.park_outlined,
                        'Outdoors'),
                  ],
                ),
                const SizedBox(height: 6),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Skip'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// One-line indoor/outdoor reading of the GNSS hints, shown as the
  /// Location card's footnote.
  String? _environmentText(GnssInfo? gnss) {
    if (gnss == null) return null;
    final sats = '${gnss.satellitesVisible ?? 0} satellites seen';
    final signal = gnss.topCn0DbHz == null
        ? 'no satellite signal'
        : 'signal ${gnss.topCn0DbHz!.toStringAsFixed(0)} dB-Hz';
    return switch (gnss.environmentHint) {
      EnvironmentHint.likelyOutdoors =>
        'Closer to outdoors: $sats, strong $signal.',
      EnvironmentHint.inBetween =>
        'Between indoors and outdoors (near a window, or between tall '
            'buildings): $sats, $signal.',
      EnvironmentHint.likelyIndoors => gnss.status == GnssSampleStatus.noData
          ? 'Closer to indoors: GPS saw no satellites.'
          : 'Closer to indoors: $sats, weak $signal.',
      EnvironmentHint.unknown => switch (gnss.status) {
          GnssSampleStatus.permissionDenied =>
            'Indoor/outdoor unknown: needs precise location.',
          GnssSampleStatus.gpsDisabled => 'Indoor/outdoor unknown: GPS is off.',
          _ => 'Indoor/outdoor unknown: no satellite data on this device.',
        },
    };
  }

  String _fmtNum(num? value, int decimals) =>
      value == null ? '—' : value.toStringAsFixed(decimals);

  String _unit(num? value, String unit, int decimals) =>
      value == null ? '—' : '${value.toStringAsFixed(decimals)} $unit';

  String _fmtMb(int bytes) => '${(bytes / 1000000).toStringAsFixed(1)} MB';

  String _fmtTime(DateTime? time) {
    if (time == null) return '—';
    final local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  String _fmtDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    return minutes == 0 ? '${hours}h' : '${hours}h ${minutes}m';
  }
}

enum _RowStatus { good, warn, bad }

/// One label/value line. Values are right-aligned and tabular so columns of
/// numbers line up down the card.
class _DataRow extends StatelessWidget {
  const _DataRow({
    required this.label,
    required this.value,
    this.mono = false,
    this.status,
  });

  final String label;
  final String value;
  final bool mono;
  final _RowStatus? status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final missing = value == '—';
    final color = switch (status) {
      _RowStatus.good => const Color(0xFF15803D),
      _RowStatus.warn => const Color(0xFFB45309),
      _RowStatus.bad => theme.colorScheme.error,
      null => missing
          ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
          : theme.colorScheme.onSurface,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 6,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: color,
                fontWeight: missing ? FontWeight.w400 : FontWeight.w600,
                fontFamily: mono ? 'monospace' : null,
                fontSize: mono ? 12.5 : null,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Signal bars, 0-4, as Android reports them.
class _SignalRow extends StatelessWidget {
  const _SignalRow({required this.level});

  final int level;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Text(
              'Signal level',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            flex: 6,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < 4; i++) ...[
                  Container(
                    width: 6,
                    height: 8.0 + i * 4,
                    decoration: BoxDecoration(
                      color: i < level
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 3),
                ],
                const SizedBox(width: 6),
                Text(
                  '$level / 4',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Label + subtitle + switch, matching the density of [_DataRow].
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodyMedium),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

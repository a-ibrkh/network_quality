import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';

import '../models/connectivity_info.dart';

/// Collects [ConnectivityInfo]: connection type via `connectivity_plus`
/// (cross-platform), plus VPN/metered/airplane-mode/roaming/carrier/
/// MCC-MNC/generation/data-network-type via a native MethodChannel.
///
/// The extra fields require `ConnectivityManager` and `TelephonyManager` on
/// Android, which `connectivity_plus` doesn't expose. On iOS there is no
/// public API for most of them (VPN detection via `NEVPNManager` and
/// carrier info via `CTTelephonyNetworkInfo` are limited/deprecated), so
/// they're left `null` there.
class ConnectivityCollector {
  static const MethodChannel _channel = MethodChannel('network_quality/connectivity');
  static const MethodChannel _iosChannel = MethodChannel('network_quality/context_ios');

  final Connectivity _connectivity;

  ConnectivityCollector({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  Future<ConnectivityInfo> collect() async {
    final results = await _connectivity.checkConnectivity();
    final extras = Platform.isAndroid
        ? await _fetch(_channel, 'getConnectivityExtras')
        : Platform.isIOS
            ? await _fetch(_iosChannel, 'getPath')
            : const <String, dynamic>{};

    // Prefer the native NetworkCapabilities answer (Android, API 23+); fall
    // back to connectivity_plus, which reports a VPN transport on both
    // platforms but shadows the underlying transport when one is active.
    final isVpnActive =
        extras['isVpnActive'] as bool? ?? results.contains(ConnectivityResult.vpn);

    return ConnectivityInfo(
      connectionType: _resolveConnectionType(results),
      isVpnActive: isVpnActive,
      // iOS has no "metered", but "expensive" (cellular, hotspot) is the
      // same idea.
      isMetered: extras['isMetered'] as bool? ?? extras['isExpensive'] as bool?,
      isAirplaneModeOn: extras['isAirplaneModeOn'] as bool?,
      isDataRoaming: extras['isDataRoaming'] as bool?,
      carrierName: extras['carrierName'] as String?,
      mcc: extras['mcc'] as String?,
      mnc: extras['mnc'] as String?,
      cellularGeneration: extras['cellularGeneration'] == null
          ? null
          : CellularGeneration.fromName(extras['cellularGeneration'] as String?),
      dataNetworkType: extras['dataNetworkType'] == null
          ? null
          : DataNetworkType.fromName(extras['dataNetworkType'] as String?),
      serviceState: extras['serviceState'] as String?,
      overrideNetworkType: extras['overrideNetworkType'] as String?,
      aggregatedChannelCount: extras['aggregatedChannelCount'] as int?,
      aggregatedBandwidthKhz: extras['aggregatedBandwidthKhz'] as int?,
      isValidated: extras['isValidated'] as bool?,
      isCaptivePortal: extras['isCaptivePortal'] as bool?,
      isCongested: extras['isCongested'] as bool?,
      estimatedDownstreamKbps: extras['estimatedDownstreamKbps'] as int?,
      estimatedUpstreamKbps: extras['estimatedUpstreamKbps'] as int?,
      mtu: extras['mtu'] as int?,
      hasIpv4: extras['hasIpv4'] as bool?,
      hasIpv6: extras['hasIpv6'] as bool?,
      isPrivateDnsActive: extras['isPrivateDnsActive'] as bool?,
      isLowDataMode: extras['isLowDataMode'] as bool?,
      activeSimCount: extras['activeSimCount'] as int?,
      dataSimSlot: extras['dataSimSlot'] as int?,
      otherSimCarrierName: extras['otherSimCarrierName'] as String?,
      otherSimMcc: extras['otherSimMcc'] as String?,
      otherSimMnc: extras['otherSimMnc'] as String?,
      timestamp: DateTime.now(),
    );
  }

  /// connectivity_plus can report several simultaneous transports; pick the
  /// most relevant single one for our model. VPN is deliberately not mapped
  /// here - it's surfaced separately via `isVpnActive`, so an active VPN
  /// still reports the underlying transport as the connection type.
  ConnectionType _resolveConnectionType(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.wifi)) return ConnectionType.wifi;
    if (results.contains(ConnectivityResult.ethernet)) return ConnectionType.ethernet;
    if (results.contains(ConnectivityResult.mobile)) return ConnectionType.cellular;
    return ConnectionType.none;
  }

  Future<Map<String, dynamic>> _fetch(MethodChannel channel, String method) async {
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(method);
      return result ?? const <String, dynamic>{};
    } on PlatformException {
      // e.g. missing READ_PHONE_STATE permission - degrade gracefully.
      return const <String, dynamic>{};
    } on MissingPluginException {
      return const <String, dynamic>{};
    }
  }
}

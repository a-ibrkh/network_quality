import 'wire_privacy.dart';

/// High-level connection type as reported by the OS.
enum ConnectionType {
  wifi,
  cellular,
  ethernet,
  none;

  static ConnectionType fromName(String? name) {
    return ConnectionType.values.firstWhere(
      (e) => e.name == name,
      orElse: () => ConnectionType.none,
    );
  }
}

/// Coarse cellular generation label (2G/3G/4G/5G).
enum CellularGeneration {
  g2,
  g3,
  g4,
  g5,
  unknown;

  static CellularGeneration fromName(String? name) {
    return CellularGeneration.values.firstWhere(
      (e) => e.name == name,
      orElse: () => CellularGeneration.unknown,
    );
  }
}

/// Radio access / data network type, mirroring Android's
/// `TelephonyManager.NETWORK_TYPE_*` constants (with an iOS-friendly
/// subset available via `CTTelephonyNetworkInfo`).
enum DataNetworkType {
  gprs,
  edge,
  umts,
  hsdpa,
  hsupa,
  hspa,
  hspap,
  cdma,
  evdo0,
  evdoA,
  evdoB,
  ehrpd,
  lte,
  lteCa,
  nr,
  gsm,
  tdScdma,
  iwlan,
  unknown;

  static DataNetworkType fromName(String? name) {
    return DataNetworkType.values.firstWhere(
      (e) => e.name == name,
      orElse: () => DataNetworkType.unknown,
    );
  }
}

/// Passive, instantly-available connectivity and network-type data.
///
/// Populated by `ConnectivityCollector`. Every field beyond [connectionType]
/// and [timestamp] may be `null` on platforms/OS versions where the value
/// isn't obtainable (e.g. most radio metadata is unavailable on iOS).
class ConnectivityInfo {
  final ConnectionType connectionType;
  final bool? isVpnActive;
  final bool? isMetered;
  final bool? isAirplaneModeOn;
  final bool? isDataRoaming;
  final String? carrierName;
  final String? mcc;
  final String? mnc;
  final CellularGeneration? cellularGeneration;
  final DataNetworkType? dataNetworkType;

  /// Registration: `inService`, `outOfService`, `emergencyOnly` or `powerOff`. Android.
  final String? serviceState;

  /// What the status bar shows: `none`, `lteCa`, `lteAdvancedPro`, `nrNsa`, `nrNsaMmwave` or `nrAdvanced`. 5G NSA reports [dataNetworkType] `lte`, so this is the only way to see it. Android 11+.
  final String? overrideNetworkType;

  /// Carrier aggregation: channels in use, primary included. Android 9+.
  final int? aggregatedChannelCount;

  /// Total bandwidth of those channels, in kHz.
  final int? aggregatedBandwidthKhz;

  /// The OS confirmed the network reaches the internet (iOS: path satisfied).
  final bool? isValidated;

  /// Behind a login page (hotel/airport Wi-Fi). Android.
  final bool? isCaptivePortal;

  /// The network reports itself congested. Android 9+.
  final bool? isCongested;

  /// The OS's own download bandwidth estimate, in kbps - no test traffic. Android.
  final int? estimatedDownstreamKbps;

  /// The OS's own upload bandwidth estimate, in kbps. Android.
  final int? estimatedUpstreamKbps;

  /// Link MTU, in bytes. Android 10+.
  final int? mtu;

  /// The link has an IPv4 address.
  final bool? hasIpv4;

  /// The link has a routable IPv6 address (link-local ones don't count).
  final bool? hasIpv6;

  /// Private DNS (DNS-over-TLS) is in use. Android 9+.
  final bool? isPrivateDnsActive;

  /// Data saver (Android 7+) / Low Data Mode (iOS 13+) is on.
  final bool? isLowDataMode;

  /// Active SIMs. Android.
  final int? activeSimCount;

  /// SIM slot (0-based) carrying mobile data. Android 7+.
  final int? dataSimSlot;

  /// Operator of the SIM not carrying data, on a dual-SIM phone.
  final String? otherSimCarrierName;

  /// Its mobile country code.
  final String? otherSimMcc;

  /// Its mobile network code.
  final String? otherSimMnc;
  final DateTime timestamp;

  const ConnectivityInfo({
    required this.connectionType,
    this.isVpnActive,
    this.isMetered,
    this.isAirplaneModeOn,
    this.isDataRoaming,
    this.carrierName,
    this.mcc,
    this.mnc,
    this.cellularGeneration,
    this.dataNetworkType,
    this.serviceState,
    this.overrideNetworkType,
    this.aggregatedChannelCount,
    this.aggregatedBandwidthKhz,
    this.isValidated,
    this.isCaptivePortal,
    this.isCongested,
    this.estimatedDownstreamKbps,
    this.estimatedUpstreamKbps,
    this.mtu,
    this.hasIpv4,
    this.hasIpv6,
    this.isPrivateDnsActive,
    this.isLowDataMode,
    this.activeSimCount,
    this.dataSimSlot,
    this.otherSimCarrierName,
    this.otherSimMcc,
    this.otherSimMnc,
    required this.timestamp,
  });

  factory ConnectivityInfo.fromJson(Map<String, dynamic> json) {
    return ConnectivityInfo(
      connectionType: ConnectionType.fromName(json['connectionType'] as String?),
      isVpnActive: json['isVpnActive'] as bool?,
      isMetered: json['isMetered'] as bool?,
      isAirplaneModeOn: json['isAirplaneModeOn'] as bool?,
      isDataRoaming: json['isDataRoaming'] as bool?,
      carrierName: json['carrierName'] as String?,
      mcc: json['mcc'] as String?,
      mnc: json['mnc'] as String?,
      cellularGeneration: json['cellularGeneration'] == null
          ? null
          : CellularGeneration.fromName(json['cellularGeneration'] as String?),
      dataNetworkType: json['dataNetworkType'] == null
          ? null
          : DataNetworkType.fromName(json['dataNetworkType'] as String?),
      serviceState: json['serviceState'] as String?,
      overrideNetworkType: json['overrideNetworkType'] as String?,
      aggregatedChannelCount: json['aggregatedChannelCount'] as int?,
      aggregatedBandwidthKhz: json['aggregatedBandwidthKhz'] as int?,
      isValidated: json['isValidated'] as bool?,
      isCaptivePortal: json['isCaptivePortal'] as bool?,
      isCongested: json['isCongested'] as bool?,
      estimatedDownstreamKbps: json['estimatedDownstreamKbps'] as int?,
      estimatedUpstreamKbps: json['estimatedUpstreamKbps'] as int?,
      mtu: json['mtu'] as int?,
      hasIpv4: json['hasIpv4'] as bool?,
      hasIpv6: json['hasIpv6'] as bool?,
      isPrivateDnsActive: json['isPrivateDnsActive'] as bool?,
      isLowDataMode: json['isLowDataMode'] as bool?,
      activeSimCount: json['activeSimCount'] as int?,
      dataSimSlot: json['dataSimSlot'] as int?,
      otherSimCarrierName: json['otherSimCarrierName'] as String?,
      otherSimMcc: json['otherSimMcc'] as String?,
      otherSimMnc: json['otherSimMnc'] as String?,
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'connectionType': connectionType.name,
      'isVpnActive': isVpnActive,
      'isMetered': isMetered,
      'isAirplaneModeOn': isAirplaneModeOn,
      'isDataRoaming': isDataRoaming,
      'carrierName': carrierName,
      'mcc': mcc,
      'mnc': mnc,
      'cellularGeneration': cellularGeneration?.name,
      'dataNetworkType': dataNetworkType?.name,
      'serviceState': serviceState,
      'overrideNetworkType': overrideNetworkType,
      'aggregatedChannelCount': aggregatedChannelCount,
      'aggregatedBandwidthKhz': aggregatedBandwidthKhz,
      'isValidated': isValidated,
      'isCaptivePortal': isCaptivePortal,
      'isCongested': isCongested,
      'estimatedDownstreamKbps': estimatedDownstreamKbps,
      'estimatedUpstreamKbps': estimatedUpstreamKbps,
      'mtu': mtu,
      'hasIpv4': hasIpv4,
      'hasIpv6': hasIpv6,
      'isPrivateDnsActive': isPrivateDnsActive,
      'isLowDataMode': isLowDataMode,
      'activeSimCount': activeSimCount,
      'dataSimSlot': dataSimSlot,
      'otherSimCarrierName': otherSimCarrierName,
      'otherSimMcc': otherSimMcc,
      'otherSimMnc': otherSimMnc,
      'timestamp': wireTimestamp(timestamp),
    };
  }
}

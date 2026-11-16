import 'wire_privacy.dart';

/// Raw cellular radio metrics.
///
/// On Android these come from `TelephonyManager.getAllCellInfo()` /
/// `requestCellInfoUpdate()` via `CellularCollector`. On iOS there is no
/// public API exposing signal-level metrics, so every numeric field is
/// `null` there and only [radioAccessTechnology] (from
/// `CTTelephonyNetworkInfo`) is populated, via `CellularCollectorIos`.
class CellularInfo {
  /// Received Signal Strength Indicator, in dBm. Real RSSI on GSM, and on
  /// LTE from Android 10. Null on WCDMA (see [rscp]) and older LTE devices.
  final int? rssi;

  /// Reference Signal Received Power, in dBm (LTE/NR).
  final int? rsrp;

  /// Reference Signal Received Quality, in dB (LTE/NR).
  final int? rsrq;

  /// Reference Signal-to-Noise Ratio / SINR, in dB.
  final int? rssnr;

  /// Channel Quality Indicator, unitless index.
  final int? cqi;

  /// Arbitrary Strength Unit level, unitless index.
  final int? asuLevel;

  /// Signal bar level, 0-4.
  final int? signalLevel;

  /// Cell ID.
  final int? cellId;

  /// Physical Cell ID.
  final int? pci;

  /// Location Area Code (2G/3G).
  final int? lac;

  /// Tracking Area Code (LTE/NR).
  final int? tac;

  /// Timing advance value.
  final int? timingAdvance;

  /// Whether the device is currently registered on this cell.
  final bool? isRegistered;

  /// iOS-only informational label from `CTTelephonyNetworkInfo`
  /// (e.g. "LTE", "5G"). Not available/needed on Android, where
  /// [DataNetworkType] in `ConnectivityInfo` already covers this.
  final String? radioAccessTechnology;

  /// Serving cell technology: `gsm`, `wcdma`, `lte`, `nr` or `other`.
  final String? technology;

  /// Channel number: EARFCN (LTE), NR-ARFCN (5G), UARFCN (3G), ARFCN (2G).
  final int? arfcn;

  /// 3GPP band number, e.g. 3 for LTE B3 (1800 MHz). LTE/5G, Android 11+.
  final int? band;

  /// Channel bandwidth in kHz (LTE, Android 9+).
  final int? bandwidthKhz;

  /// Received Signal Code Power in dBm (3G/WCDMA).
  final int? rscp;

  /// 5G CSI-RSRP in dBm.
  final int? csiRsrp;

  /// 5G CSI-RSRQ in dB.
  final int? csiRsrq;

  /// 5G CSI-SINR in dB.
  final int? csiSinr;

  /// Other cells the modem can hear, up to 16. Empty when none were
  /// reported, which is common on older devices.
  final List<NeighborCell> neighborCells;

  final DateTime timestamp;

  const CellularInfo({
    this.rssi,
    this.rsrp,
    this.rsrq,
    this.rssnr,
    this.cqi,
    this.asuLevel,
    this.signalLevel,
    this.cellId,
    this.pci,
    this.lac,
    this.tac,
    this.timingAdvance,
    this.isRegistered,
    this.radioAccessTechnology,
    this.technology,
    this.arfcn,
    this.band,
    this.bandwidthKhz,
    this.rscp,
    this.csiRsrp,
    this.csiRsrq,
    this.csiSinr,
    this.neighborCells = const [],
    required this.timestamp,
  });

  factory CellularInfo.fromJson(Map<String, dynamic> json) {
    return CellularInfo(
      rssi: json['rssi'] as int?,
      rsrp: json['rsrp'] as int?,
      rsrq: json['rsrq'] as int?,
      rssnr: json['rssnr'] as int?,
      cqi: json['cqi'] as int?,
      asuLevel: json['asuLevel'] as int?,
      signalLevel: json['signalLevel'] as int?,
      cellId: json['cellId'] as int?,
      pci: json['pci'] as int?,
      lac: json['lac'] as int?,
      tac: json['tac'] as int?,
      timingAdvance: json['timingAdvance'] as int?,
      isRegistered: json['isRegistered'] as bool?,
      radioAccessTechnology: json['radioAccessTechnology'] as String?,
      technology: json['technology'] as String?,
      arfcn: json['arfcn'] as int?,
      band: json['band'] as int?,
      bandwidthKhz: json['bandwidthKhz'] as int?,
      rscp: json['rscp'] as int?,
      csiRsrp: json['csiRsrp'] as int?,
      csiRsrq: json['csiRsrq'] as int?,
      csiSinr: json['csiSinr'] as int?,
      neighborCells: [
        for (final cell in (json['neighborCells'] as List?) ?? const [])
          NeighborCell.fromJson(Map<String, dynamic>.from(cell as Map)),
      ],
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'rssi': rssi,
      'rsrp': rsrp,
      'rsrq': rsrq,
      'rssnr': rssnr,
      'cqi': cqi,
      'asuLevel': asuLevel,
      'signalLevel': signalLevel,
      'cellId': cellId,
      'pci': pci,
      'lac': lac,
      'tac': tac,
      'timingAdvance': timingAdvance,
      'isRegistered': isRegistered,
      'radioAccessTechnology': radioAccessTechnology,
      'technology': technology,
      'arfcn': arfcn,
      'band': band,
      'bandwidthKhz': bandwidthKhz,
      'rscp': rscp,
      'csiRsrp': csiRsrp,
      'csiRsrq': csiRsrq,
      'csiSinr': csiSinr,
      'neighborCells': [for (final cell in neighborCells) cell.toJson()],
      'timestamp': wireTimestamp(timestamp),
    };
  }
}

/// A cell the modem can hear but isn't serving the device. Usually only
/// PCI, channel and signal are known: the network doesn't broadcast a
/// neighbour's full cell ID. Units as on [CellularInfo].
class NeighborCell {
  final String? technology;
  final int? cellId;
  final int? pci;
  final int? arfcn;
  final int? band;
  final int? rssi;
  final int? rsrp;
  final int? rsrq;
  final int? rscp;
  final int? rssnr;
  final int? signalLevel;

  const NeighborCell({
    this.technology,
    this.cellId,
    this.pci,
    this.arfcn,
    this.band,
    this.rssi,
    this.rsrp,
    this.rsrq,
    this.rscp,
    this.rssnr,
    this.signalLevel,
  });

  factory NeighborCell.fromJson(Map<String, dynamic> json) {
    return NeighborCell(
      technology: json['technology'] as String?,
      cellId: json['cellId'] as int?,
      pci: json['pci'] as int?,
      arfcn: json['arfcn'] as int?,
      band: json['band'] as int?,
      rssi: json['rssi'] as int?,
      rsrp: json['rsrp'] as int?,
      rsrq: json['rsrq'] as int?,
      rscp: json['rscp'] as int?,
      rssnr: json['rssnr'] as int?,
      signalLevel: json['signalLevel'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'technology': technology,
      'cellId': cellId,
      'pci': pci,
      'arfcn': arfcn,
      'band': band,
      'rssi': rssi,
      'rsrp': rsrp,
      'rsrq': rsrq,
      'rscp': rscp,
      'rssnr': rssnr,
      'signalLevel': signalLevel,
    };
  }
}

import CoreMotion
import CoreTelephony
import Flutter
import Network
import UIKit

/// iOS side of the network_quality SDK: the two channels the Dart
/// collectors call on iOS. Everything else on iOS comes from Dart-side
/// plugins (connectivity_plus, geolocator, battery_plus, device_info_plus).
public class NetworkQualityPlugin: NSObject, FlutterPlugin {
  /// Held for the duration of an accelerometer sampling window.
  private let motionManager = CMMotionManager()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NetworkQualityPlugin()

    let cellularChannel = FlutterMethodChannel(
      name: "network_quality/cellular_ios",
      binaryMessenger: registrar.messenger()
    )
    cellularChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "getRadioAccessTechnology":
        result(["radioAccessTechnology": currentRadioAccessTechnology()])
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Network path + device state + motion: the iOS counterparts of the
    // Android "connectivity" / "context" channels, for what iOS exposes.
    let contextChannel = FlutterMethodChannel(
      name: "network_quality/context_ios",
      binaryMessenger: registrar.messenger()
    )
    contextChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "getPath":
        currentPath(result)
      case "getDeviceExtras":
        result(deviceExtras())
      case "sampleEnvironment":
        let args = call.arguments as? [String: Any]
        let durationMs = args?["durationMs"] as? Int ?? 6000
        instance.sampleMotion(durationMs: durationMs, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Reads the only cellular signal information iOS exposes publicly: a
  /// coarse radio access technology label. There is no public API for
  /// RSRP/RSSI/RSRQ/SINR/CQI/cell identifiers, so those stay null on iOS.
  ///
  /// Returns nil when not on cellular (e.g. Wi-Fi only), since
  /// serviceCurrentRadioAccessTechnology has no entry for the data service
  /// in that case.
  private static func currentRadioAccessTechnology() -> String? {
    let networkInfo = CTTelephonyNetworkInfo()
    guard let technologies = networkInfo.serviceCurrentRadioAccessTechnology,
          let rawValue = technologies.values.first(where: { !$0.isEmpty })
    else {
      return nil
    }
    return friendlyLabel(for: rawValue)
  }

  /// One reading of the current network path. NWPathMonitor has no
  /// synchronous getter: start it, take the first update, cancel.
  private static func currentPath(_ result: @escaping FlutterResult) {
    let monitor = NWPathMonitor()
    var replied = false
    monitor.pathUpdateHandler = { path in
      guard !replied else { return }
      replied = true
      monitor.cancel()
      var payload: [String: Any] = [
        "isExpensive": path.isExpensive,
        "hasIpv4": path.supportsIPv4,
        "hasIpv6": path.supportsIPv6,
        "isValidated": path.status == .satisfied,
      ]
      // Low Data Mode - the iOS equivalent of Android's data saver.
      if #available(iOS 13.0, *) {
        payload["isLowDataMode"] = path.isConstrained
      }
      DispatchQueue.main.async { result(payload) }
    }
    monitor.start(queue: DispatchQueue.global(qos: .utility))
  }

  /// Low Power Mode and thermal state, mapped onto the Android names so
  /// the backend sees one vocabulary.
  private static func deviceExtras() -> [String: Any] {
    let info = ProcessInfo.processInfo
    let thermal: String
    switch info.thermalState {
    case .nominal: thermal = "none"
    case .fair: thermal = "light"
    case .serious: thermal = "severe"
    case .critical: thermal = "critical"
    @unknown default: thermal = "none"
    }
    return ["isPowerSaveMode": info.isLowPowerModeEnabled, "thermalStatus": thermal]
  }

  /// Spread of user acceleration (gravity removed) over the window, in
  /// m/s^2. Raw device motion needs no permission prompt on iOS.
  private func sampleMotion(durationMs: Int, result: @escaping FlutterResult) {
    guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else {
      result(["sampleSeconds": Double(durationMs) / 1000])
      return
    }
    var count = 0.0
    var sum = 0.0
    var sumSquares = 0.0
    motionManager.deviceMotionUpdateInterval = 1.0 / 50
    motionManager.startDeviceMotionUpdates(to: .main) { motion, _ in
      guard let a = motion?.userAcceleration else { return }
      let magnitude = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot() * 9.80665
      count += 1
      sum += magnitude
      sumSquares += magnitude * magnitude
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(durationMs)) { [weak self] in
      self?.motionManager.stopDeviceMotionUpdates()
      var payload: [String: Any] = ["sampleSeconds": Double(durationMs) / 1000]
      if count >= 2 {
        let mean = sum / count
        payload["accelStdDevMps2"] = max(0, sumSquares / count - mean * mean).squareRoot()
      }
      result(payload)
    }
  }

  /// Maps the `CTRadioAccessTechnology*` constants to short labels.
  private static func friendlyLabel(for rawValue: String) -> String {
    switch rawValue {
    case CTRadioAccessTechnologyGPRS: return "GPRS"
    case CTRadioAccessTechnologyEdge: return "EDGE"
    case CTRadioAccessTechnologyWCDMA: return "WCDMA"
    case CTRadioAccessTechnologyHSDPA: return "HSDPA"
    case CTRadioAccessTechnologyHSUPA: return "HSUPA"
    case CTRadioAccessTechnologyCDMA1x: return "CDMA1x"
    case CTRadioAccessTechnologyCDMAEVDORev0: return "CDMAEVDORev0"
    case CTRadioAccessTechnologyCDMAEVDORevA: return "CDMAEVDORevA"
    case CTRadioAccessTechnologyCDMAEVDORevB: return "CDMAEVDORevB"
    case CTRadioAccessTechnologyeHRPD: return "eHRPD"
    case CTRadioAccessTechnologyLTE: return "LTE"
    default:
      // NR / NRNSA are iOS 14.1+; compare by raw string so this still
      // builds against older SDKs.
      if rawValue == "CTRadioAccessTechnologyNR" { return "5G NR" }
      if rawValue == "CTRadioAccessTechnologyNRNSA" { return "5G NRNSA" }
      return rawValue
    }
  }
}

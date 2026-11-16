/// State of a single OS permission this module needs.
enum PermissionState {
  granted,

  /// Denied, but the OS will still show a prompt if asked again.
  denied,

  /// Denied with "don't ask again" - a prompt will no longer appear, so the
  /// only path forward is sending the user to the app's settings page.
  permanentlyDenied,

  /// The current platform doesn't require this permission at all (iOS,
  /// desktop, web), so there is nothing to request.
  notRequired;

  /// Falls back to [denied] for unrecognised values: the conservative
  /// reading, since assuming a permission is granted would silently produce
  /// empty cellular metrics instead of a clear "ask the user" signal.
  static PermissionState fromName(String? name) {
    return PermissionState.values.firstWhere(
      (e) => e.name == name,
      orElse: () => PermissionState.denied,
    );
  }
}

/// The permissions `CellularCollector` needs before Android will return any
/// cellular radio metrics.
///
/// Android requires *both* `ACCESS_FINE_LOCATION` and `READ_PHONE_STATE`
/// for `getAllCellInfo()`; with either missing the call returns an empty
/// list rather than an error, which is why the module reports permission
/// state explicitly instead of leaving callers to guess why every metric
/// came back null.
class PermissionStatuses {
  final PermissionState fineLocation;
  final PermissionState phoneState;

  const PermissionStatuses({
    required this.fineLocation,
    required this.phoneState,
  });

  /// Every permission reported as [PermissionState.notRequired] - the
  /// result on platforms that don't gate this data behind permissions.
  const PermissionStatuses.notRequired()
      : fineLocation = PermissionState.notRequired,
        phoneState = PermissionState.notRequired;

  /// Whether the OS permissions needed for cellular radio metrics are
  /// satisfied.
  ///
  /// Note this is `true` on iOS, where no permission is required - it says
  /// nothing about whether metrics are actually obtainable there. iOS still
  /// returns null for every signal metric (platform limitation, see
  /// `CellularCollectorIos`).
  bool get hasRequiredPermissions =>
      _isSatisfied(fineLocation) && _isSatisfied(phoneState);

  /// Whether any required permission is permanently denied, meaning
  /// re-requesting is futile and the user must be sent to app settings
  /// (see `PermissionManager.openAppSettings`).
  bool get isPermanentlyDenied =>
      fineLocation == PermissionState.permanentlyDenied ||
      phoneState == PermissionState.permanentlyDenied;

  static bool _isSatisfied(PermissionState state) =>
      state == PermissionState.granted || state == PermissionState.notRequired;

  factory PermissionStatuses.fromJson(Map<String, dynamic> json) {
    return PermissionStatuses(
      fineLocation: PermissionState.fromName(json['fineLocation'] as String?),
      phoneState: PermissionState.fromName(json['phoneState'] as String?),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'fineLocation': fineLocation.name,
      'phoneState': phoneState.name,
    };
  }

  @override
  String toString() =>
      'PermissionStatuses(fineLocation: ${fineLocation.name}, '
      'phoneState: ${phoneState.name})';
}

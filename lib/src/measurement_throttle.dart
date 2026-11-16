/// Persists when the last measurement ran.
///
/// Abstracted so the throttle's decision logic stays free of any plugin
/// dependency (and therefore unit-testable without a Flutter binding), and
/// so a host app can substitute its own storage.
abstract class MeasurementTimestampStore {
  Future<DateTime?> read();
  Future<void> write(DateTime at);
  Future<void> clear();
}

/// In-memory store. Useful in tests; useless in production, since the whole
/// point of the throttle is surviving an app restart.
class InMemoryMeasurementTimestampStore implements MeasurementTimestampStore {
  DateTime? _value;

  InMemoryMeasurementTimestampStore([this._value]);

  @override
  Future<DateTime?> read() async => _value;

  @override
  Future<void> write(DateTime at) async => _value = at;

  @override
  Future<void> clear() async => _value = null;
}

/// Suppresses repeat measurements that happen too close together.
///
/// Measurements run when the host app is opened, so without this a user
/// who opens the app several times an hour would produce near-duplicate
/// readings - burning their mobile data on downloads that tell us nothing
/// new, and skewing aggregates toward whoever opens the app most.
class MeasurementThrottle {
  /// Minimum gap between measurements.
  ///
  /// 12 hours caps a device at two runs a day. At ~14.7 MB per run that
  /// bounds the SDK's data cost at roughly 30 MB/day worst case - the
  /// cooldown is a far stronger lever on total data than the byte caps
  /// are, because it limits how often anything is spent at all.
  static const Duration defaultCooldown = Duration(hours: 12);

  final MeasurementTimestampStore store;

  const MeasurementThrottle(this.store);

  /// Pure decision function, exposed for testing and for callers that
  /// already hold a timestamp.
  ///
  /// Returns false when [lastMeasurementAt] is null (never measured) or
  /// sits in the future. A future timestamp means the device clock moved
  /// backwards - treating that as "within cooldown" would block
  /// measurements until real time caught up, potentially for years, so it
  /// is deliberately read as "measure now" instead.
  static bool isWithinCooldown({
    required DateTime? lastMeasurementAt,
    required DateTime now,
    Duration cooldown = defaultCooldown,
  }) {
    if (lastMeasurementAt == null) return false;
    final elapsed = now.difference(lastMeasurementAt);
    if (elapsed.isNegative) return false;
    return elapsed < cooldown;
  }

  /// When the last measurement ran, or null if there hasn't been one.
  Future<DateTime?> lastMeasurementAt() => store.read();

  /// Whether a measurement should be suppressed right now.
  Future<bool> shouldSkip({
    Duration cooldown = defaultCooldown,
    DateTime? now,
  }) async {
    return isWithinCooldown(
      lastMeasurementAt: await store.read(),
      now: now ?? DateTime.now(),
      cooldown: cooldown,
    );
  }

  /// How long until the next measurement is allowed, or null if one is
  /// allowed now. Handy for a "checked N minutes ago" UI.
  Future<Duration?> timeUntilNextAllowed({
    Duration cooldown = defaultCooldown,
    DateTime? now,
  }) async {
    final last = await store.read();
    if (last == null) return null;
    final at = now ?? DateTime.now();
    final elapsed = at.difference(last);
    if (elapsed.isNegative || elapsed >= cooldown) return null;
    return cooldown - elapsed;
  }

  /// Records that a measurement just ran. Call only when one actually did -
  /// recording a skipped run would push the next one another full cooldown
  /// away and could starve measurement entirely.
  Future<void> recordMeasurement([DateTime? at]) =>
      store.write(at ?? DateTime.now());

  /// Clears the stored timestamp so the next measurement runs immediately.
  Future<void> reset() => store.clear();
}

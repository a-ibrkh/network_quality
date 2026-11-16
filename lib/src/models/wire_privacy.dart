// Coarsening applied to location and time on everything the module
// serializes - what is sent, what is queued on disk, and what is logged.
//
// Exact coordinates plus exact times re-identify people (a point at 3am
// is usually a home), so neither leaves the device at full precision.
// In-memory models keep the exact values; only `toJson()` coarsens.

/// Decimal places kept on latitude/longitude. 3 is ~110 m north-south and
/// ~85 m east-west at Tashkent's latitude - fine for a coverage map, too
/// coarse to pick out a building.
const int wireCoordinateDecimals = 3;

/// Granularity every serialized timestamp is rounded down to.
const Duration wireTimestampPrecision = Duration(minutes: 15);

/// Rounds a coordinate to [wireCoordinateDecimals]. Goes through a string
/// so the result is exactly `41.311`, not `41.311000000000004`.
double? coarsenCoordinate(double? value) => value == null
    ? null
    : double.parse(value.toStringAsFixed(wireCoordinateDecimals));

/// Rounds [time] down to [wireTimestampPrecision] and formats it as UTC
/// ISO 8601. Down rather than nearest, so a timestamp never lands in the
/// future.
String wireTimestamp(DateTime time) {
  final ms = time.toUtc().millisecondsSinceEpoch;
  final step = wireTimestampPrecision.inMilliseconds;
  return DateTime.fromMillisecondsSinceEpoch(ms - ms % step, isUtc: true)
      .toIso8601String();
}

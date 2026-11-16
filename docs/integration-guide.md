# Integration guide

How to add `network_quality` to a Flutter app, set it up on Android and
iOS, and configure it. For how the SDK works inside, see the
[README](../README.md); for every collected field, see
[data-fields.md](data-fields.md).

- [1. Requirements](#1-requirements)
- [2. Add the package](#2-add-the-package)
- [3. Platform setup](#3-platform-setup)
- [4. Initialize the SDK](#4-initialize-the-sdk)
- [5. Run a measurement](#5-run-a-measurement)
- [6. Configuration reference](#6-configuration-reference)
- [7. Per-call overrides](#7-per-call-overrides)
- [8. Configuration recipes](#8-configuration-recipes)
- [9. Custom storage](#9-custom-storage)
- [10. What your backend must provide](#10-what-your-backend-must-provide)
- [11. Troubleshooting](#11-troubleshooting)

---

## 1. Requirements

| | Minimum |
| --- | --- |
| Dart | 3.6 |
| Flutter | 3.27 |
| Android | API 24 (Android 7.0) |
| iOS | 13.0 |

You also need a backend that accepts the telemetry. The SDK has no
default server. See [section 10](#10-what-your-backend-must-provide).

---

## 2. Add the package

The package is not on pub.dev. Add it as a git dependency in your app's
`pubspec.yaml`, pinned to a release tag:

```yaml
dependencies:
  network_quality:
    git:
      url: https://github.com/a-ibrkh/network_quality.git
      ref: v0.1.0        # a tag; use a commit SHA for an exact pin
```

Then run:

```sh
flutter pub get
```

**Private repository.** If the repository is private, `flutter pub get`
uses your git credentials. Either:

- use the SSH URL (`git@github.com:a-ibrkh/network_quality.git`) with an
  SSH key added to your GitHub account, or
- keep the HTTPS URL and have a credential helper or personal access token
  configured.

On CI, give the build a deploy key or token with read access to this
repository.

**Developing the SDK alongside your app.** Point at a local checkout
instead:

```yaml
dependencies:
  network_quality:
    path: ../network_quality
```

**Upgrading.** Change `ref` to the new tag and run
`flutter pub upgrade network_quality`. Read [CHANGELOG.md](../CHANGELOG.md)
first.

---

## 3. Platform setup

### Android

No setup is needed. The SDK's manifest merges these permissions into
your app automatically:

- `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`
- `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`
- `READ_PHONE_STATE`

You don't need to change `MainActivity`. The plugin handles permission
results itself.

Make sure your app's `minSdk` is at least 24 in
`android/app/build.gradle(.kts)`:

```kotlin
android {
    defaultConfig {
        minSdk = 24
    }
}
```

The plugin is built from the Flutter 3.47 template (Android Gradle Plugin
9). Host apps still on AGP 8 have not been tested.

### iOS

1. Add a location usage description to `ios/Runner/Info.plist`. Plugins
   can't add this key for you. Without it iOS never shows the location
   prompt, and App Store review rejects the build:

   ```xml
   <key>NSLocationWhenInUseUsageDescription</key>
   <string>Your location is recorded with each network measurement so signal quality can be mapped to where it was measured.</string>
   ```

2. Set the deployment target to 13.0 or later (`ios/Podfile`:
   `platform :ios, '13.0'`, and in Xcode under *Runner → General →
   Minimum Deployments*).

3. **App Store privacy.** The SDK ships a privacy manifest
   (`PrivacyInfo.xcprivacy`) that declares precise location and
   diagnostic data, not linked to identity and not used for tracking.
   Your App Store privacy answers must cover this too.

**iOS limitation.** iOS has no public API for signal strength or cell
identifiers. On iOS, `CellularInfo` holds only a coarse radio technology
label. RSRP, RSSI, cell ID and the other radio metrics are always `null`.

### Cleartext HTTP

Use HTTPS for `baseUrl` and every endpoint. Then you need no
`network_security_config.xml` on Android and no App Transport Security
exception on iOS. From Flutter 3.44, plain-HTTP endpoints fail with
`Insecure HTTP is not allowed by platform`. If you must use HTTP, add a
host-scoped exception on each platform. Don't allow cleartext globally.

---

## 4. Initialize the SDK

Create **one** `NetworkQualityService` and keep it for the whole app
lifetime. Its `sessionId` links a snapshot to the speed test taken with
it, so creating a new instance per measurement breaks that link.

```dart
import 'package:network_quality/network_quality.dart';

final networkQuality = NetworkQualityService(
  config: NetworkQualityConfig(
    baseUrl: Uri.parse('https://telemetry.example.com'),
    headers: {'X-API-Key': 'your-key'}, // optional
  ),
);
```

Put it wherever your app keeps long-lived services: a top-level
variable, `get_it`, a Riverpod `Provider`, or similar.

Import only `package:network_quality/network_quality.dart`. Anything
under `lib/src/` is internal and can change without notice.

Constructor parameters:

| Parameter | Required | Description |
| --- | --- | --- |
| `config` | yes | A `NetworkQualityConfig`. See [section 6](#6-configuration-reference). |
| `sessionId` | no | Your own session ID. A UUID v4 is generated if omitted. Pass the old ID when you recreate the service (e.g. after a token refresh) to keep reports correlated. |
| `timestampStore` | no | Where the cooldown timestamp is saved. Defaults to `shared_preferences`. See [section 9](#9-custom-storage). |
| `queueStore` | no | Where unsent reports are saved. Defaults to `shared_preferences`. See [section 9](#9-custom-storage). |

---

## 5. Run a measurement

A typical flow, run once when the app opens:

```dart
Future<void> measureNetwork(NetworkQualityService nq) async {
  // 1. Deliver reports left over from earlier failed sends.
  await nq.flushPendingTelemetry();

  // 2. Permissions. checkPermissions() never shows a dialog.
  var permissions = await nq.checkPermissions();
  if (!permissions.hasRequiredPermissions) {
    permissions = await nq.requestPermissions(); // shows the system dialog
  }
  if (permissions.isPermanentlyDenied) {
    // The OS won't show the dialog again. Explain why it's needed,
    // then send the user to settings:
    // await nq.openAppSettings();
    return;
  }

  // 3. Passive data: radio, cell, connectivity, location, device.
  //    No network traffic. Takes about gnssSampleDuration (6 s by default).
  final snapshot = await nq.collectSnapshot();

  // 4. Active speed test. Uses mobile data (at most ~15 MB by default).
  final result = await nq.runActiveTest(
    // Skip the most data-hungry part on metered connections if you like.
    includeDownload: snapshot.connectivityInfo.isMetered != true,
  );

  if (result.skipReason == MeasurementSkipReason.notCellular) {
    // Not on mobile data. Nothing was measured.
  } else if (result.skipReason == MeasurementSkipReason.recentlyMeasured) {
    // Already measured within the cooldown window.
  }

  // 5. Send. These never throw: reports are saved to disk first and
  //    retried later if the send fails.
  await nq.sendSnapshot(snapshot);
  if (result.skipReason == null) {
    await nq.sendTestResult(result);
  }
}
```

Things to know:

- **The SDK never prompts on its own.** `collectSnapshot()` and
  `runActiveTest()` don't trigger permission dialogs. You decide where in
  your UI to ask.
- **Android needs both location and phone-state permission** for cellular
  data. Without them `CellularInfo` comes back all `null`, which looks like
  a phone with no signal. Check `hasRequiredPermissions` before trusting
  it.
- **Sends return a `FlushResult`**, not an exception. Its fields are
  `sent`, `failed`, `discarded` and `remaining`.
- **Nothing runs in the background.** The SDK only measures when your app
  calls it.

Other service methods:

| Method | Returns | Use |
| --- | --- | --- |
| `pendingTelemetryCount()` | `Future<int>` | Number of reports waiting to be delivered. |
| `lastMeasurementAt()` | `Future<DateTime?>` | When the last speed test ran, e.g. for "checked 5 min ago". |
| `timeUntilNextMeasurement({cooldown})` | `Future<Duration?>` | Time left in the cooldown, `null` if a test can run now. Use it to disable a "test again" button. |
| `openAppSettings()` | `Future<bool>` | Opens the app's system settings page. |

---

## 6. Configuration reference

All settings live in `NetworkQualityConfig`. Only `baseUrl` is required.
The config is immutable. Use `copyWith(...)` to derive a changed copy.

Invalid values (for example a warmup longer than the test) fail an
`assert` in debug builds. They are not checked in release builds, so test
your config in debug first.

### Backend

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `baseUrl` | `Uri` | **required** | Your backend. Must be absolute, e.g. `https://api.example.com`. The three endpoints below are derived from it. |
| `headers` | `Map<String, String>` | `{}` | Added to every request to **your backend** (telemetry and ping), e.g. auth. Not sent to the speed-test endpoints. Header values are hidden in `toString()`. |
| `locationEndpoint` | `Uri?` | `<baseUrl>/api/telemetry/location` | Where snapshots are `POST`ed. |
| `speedtestEndpoint` | `Uri?` | `<baseUrl>/api/telemetry/speedtest` | Where speed-test results are `POST`ed. |
| `pingEndpoint` | `Uri?` | `<baseUrl>/speedtest/ping` | `GET` target for latency and jitter. |

`copyWith(baseUrl: ...)` re-derives the three endpoints from the new base
URL, unless you pass them explicitly too.

### Speed-test servers

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `downloadEndpoint` | `Uri?` | `https://speed.cloudflare.com/__down?bytes=10000000` | Download source. Must return at least `downloadMaxBytes` of data per request. A cache-busting query parameter is added to each request. |
| `uploadEndpoint` | `Uri?` | `https://speed.cloudflare.com/__up` | Upload sink. Must read the whole request body **before** responding, or upload speeds come out wrong. |

Cloudflare often has servers inside carrier networks, so its throughput is
close to best case. Point these at your own server if you want speeds to
a specific destination.

### Download test

| Parameter | Type | Default | Constraint | Description |
| --- | --- | --- | --- | --- |
| `downloadTestDuration` | `Duration` | 4 s | > 0 | Maximum length of the download test. |
| `downloadWarmup` | `Duration` | 500 ms | ≥ 0 and < `downloadTestDuration` | Excluded from the result, so TCP slow-start doesn't lower the figure. |
| `downloadParallelConnections` | `int` | 4 | ≥ 1 | Simultaneous connections. More connections measure fast links more accurately. |
| `downloadMaxBytes` | `int` | 10 MiB | > 0 | Hard data cap. The test stops at whichever comes first: this or the duration. |

### Upload test

| Parameter | Type | Default | Constraint | Description |
| --- | --- | --- | --- | --- |
| `uploadTestDuration` | `Duration` | 4 s | > 0 | Maximum length of the upload test. |
| `uploadParallelConnections` | `int` | 3 | ≥ 1 | Simultaneous connections. |
| `uploadChunkBytes` | `int` | 512 KiB | > 0 | Size of each `POST` body. Too large and slow links finish no chunks; too small and per-request overhead dominates. |
| `uploadMaxBytes` | `int` | 4 MiB | ≥ `uploadChunkBytes` | Hard data cap. |

### Latency

| Parameter | Type | Default | Constraint | Description |
| --- | --- | --- | --- | --- |
| `latencySamples` | `int` | 11 | > 1 | Pings sent to `pingEndpoint`. The first is discarded because it includes connection setup. |

### When tests run

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `measurementCooldown` | `Duration` | 12 h | Minimum gap between speed tests. A call inside the window returns `skipReason: recentlyMeasured`. Saved to disk, so it survives app restarts. `Duration.zero` disables it. |
| `cellularOnly` | `bool` | `true` | Run speed tests only on mobile data. On Wi-Fi a call returns `skipReason: notCellular`. |

### Snapshot

| Parameter | Type | Default | Constraint | Description |
| --- | --- | --- | --- | --- |
| `gnssSampleDuration` | `Duration` | 6 s | ≥ 0 | How long `collectSnapshot()` listens to GPS satellites for the indoor/outdoor hint. Every snapshot takes at least this long. `Duration.zero` turns satellite sampling off and makes snapshots near-instant, but `gnssInfo` and `environmentInfo` will be `null`. |

### Data cost

Each speed test uses roughly `min(cap, link speed × duration)` for each
direction. With the defaults, a run costs **at most about 14.7 MB**
(10 MiB down + 4 MiB up). Slower links use less:

| Link speed | Download | Upload | Total |
| --- | --- | --- | --- |
| 2 Mbps | 1.0 MB | 1.0 MB | ~2 MB |
| 10 Mbps | 5.0 MB | 4.2 MB | ~9.2 MB |
| 50 Mbps+ | 10.5 MB | 4.2 MB | ~14.7 MB |

With the 12-hour cooldown, that's at most about 30 MB per device per day.
The cooldown limits how often you spend data; the byte caps limit each
run.

---

## 7. Per-call overrides

Some settings can be overridden for a single call without changing the
config. The order is: built-in default → config → per-call argument.

**`collectSnapshot({bool freshLocation = false})`**

| Argument | Default | Description |
| --- | --- | --- |
| `freshLocation` | `false` | `false` uses the OS's last known position (instant, may be minutes old). `true` waits for a new GPS fix: accurate, but takes seconds (longer indoors) and costs battery. |

**`runActiveTest({...})`**

| Argument | Default | Description |
| --- | --- | --- |
| `includeDownload` | `true` | Run the download test. Set `false` to save data. |
| `includeUpload` | `true` | Run the upload test. |
| `cellularOnly` | `config.cellularOnly` | Override the mobile-data-only rule for this call. |
| `cooldown` | `config.measurementCooldown` | Use a different cooldown window for this call. |
| `ignoreCooldown` | `false` | Run even inside the cooldown, e.g. for a user-tapped "test again" button. |

DNS, TCP, TLS and latency timings always run; they cost almost no data.

**`timeUntilNextMeasurement({Duration? cooldown})`** accepts the same
`cooldown` override, so it agrees with your `runActiveTest` call.

---

## 8. Configuration recipes

### Production and staging from build flags

```dart
// flutter run --dart-define=NQ_BASE_URL=https://staging.example.com \
//             --dart-define=NQ_API_KEY=...
const _baseUrl = String.fromEnvironment(
  'NQ_BASE_URL',
  defaultValue: 'https://telemetry.example.com',
);
const _apiKey = String.fromEnvironment('NQ_API_KEY');

final networkQuality = NetworkQualityService(
  config: NetworkQualityConfig(
    baseUrl: Uri.parse(_baseUrl),
    headers: {if (_apiKey.isNotEmpty) 'X-API-Key': _apiKey},
  ),
);
```

### Data saver

Smaller caps and a longer cooldown:

```dart
NetworkQualityConfig(
  baseUrl: Uri.parse('https://telemetry.example.com'),
  downloadMaxBytes: 2 * 1024 * 1024, // 2 MiB
  uploadMaxBytes: 1 * 1024 * 1024,   // 1 MiB
  measurementCooldown: const Duration(hours: 24),
);
```

Accuracy drops first on fast links; slow links are unaffected.

### Drive test / QA build

Measure on any connection, frequently, with fresh GPS:

```dart
final nq = NetworkQualityService(
  config: NetworkQualityConfig(
    baseUrl: Uri.parse('https://telemetry.example.com'),
    cellularOnly: false,
    measurementCooldown: Duration.zero,
  ),
);

final snapshot = await nq.collectSnapshot(freshLocation: true);
final result = await nq.runActiveTest();
```

### Your own speed-test server

```dart
NetworkQualityConfig(
  baseUrl: Uri.parse('https://telemetry.example.com'),
  downloadEndpoint: Uri.parse('https://speed.example.com/10mb.bin'),
  uploadEndpoint: Uri.parse('https://speed.example.com/upload'),
  downloadTestDuration: const Duration(seconds: 8),
  downloadParallelConnections: 6,
);
```

`headers` are **not** sent to these endpoints.

### Fast snapshots (no satellite sampling)

```dart
NetworkQualityConfig(
  baseUrl: Uri.parse('https://telemetry.example.com'),
  gnssSampleDuration: Duration.zero,
);
```

### Changing the auth token at runtime

Config is immutable, so create a new service with the updated headers.
Pass the old `sessionId` to keep reports linked. Queued reports are sent
with the new headers on the next flush.

```dart
networkQuality = NetworkQualityService(
  config: networkQuality.config.copyWith(
    headers: {'Authorization': 'Bearer $newToken'},
  ),
  sessionId: networkQuality.sessionId,
);
```

---

## 9. Custom storage

By default the SDK saves two things with `shared_preferences`: the time of
the last speed test (for the cooldown) and the queue of unsent reports.
To use your own storage, implement these interfaces and pass them to the
constructor:

```dart
abstract class MeasurementTimestampStore {
  Future<DateTime?> read();
  Future<void> write(DateTime at);
  Future<void> clear();
}

abstract class TelemetryQueueStore {
  Future<List<QueuedReport>> read();
  Future<void> write(List<QueuedReport> reports);
}
```

`QueuedReport` has `toJson()` / `fromJson()` for serialization.

For tests, use the in-memory versions:

```dart
final nq = NetworkQualityService(
  config: NetworkQualityConfig(baseUrl: Uri.parse('https://test.invalid')),
  timestampStore: InMemoryMeasurementTimestampStore(),
  queueStore: InMemoryTelemetryQueueStore(),
);
```

---

## 10. What your backend must provide

| Endpoint | Method | Body | Expected response |
| --- | --- | --- | --- |
| `locationEndpoint` | `POST` | `NetworkQualitySnapshot` as JSON | Any `2xx` |
| `speedtestEndpoint` | `POST` | `ActiveMeasurement` as JSON | Any `2xx` |
| `pingEndpoint` | `GET` | none | Fast, empty response (e.g. `204 No Content`). Any status code is timed, so make sure your app answers it, not a proxy's 404. |

- All bodies are `Content-Type: application/json; charset=utf-8`, and every
  request includes your `headers`.
- A non-`2xx` response, timeout (15 s) or network error counts as a
  failure. The report stays queued and is retried with exponential
  backoff (30 s, doubling, up to 1 h). It is dropped after 8 attempts or
  3 days. The queue holds at most 100 reports; the oldest is dropped
  first.
- Each report carries an `eventId` (UUID) that stays the same across
  retries. Deduplicate on it, otherwise a request that succeeded but
  timed out on the client will be stored twice.
- Many fields are legitimately `null` (for example all signal metrics on
  iOS). Don't reject payloads for null fields, and don't turn null into 0.
- Timestamps are UTC ISO-8601 rounded to 15 minutes, and coordinates are
  rounded to 3 decimals (~100 m).

Full payload shapes are in [backend-api-spec.md](backend-api-spec.md)
and [data-fields.md](data-fields.md).

---

## 11. Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `CellularInfo` is all `null` on Android | Location or phone-state permission is missing. Check `checkPermissions().hasRequiredPermissions`. |
| `CellularInfo` is all `null` on iOS | Expected. iOS has no public API for signal metrics. |
| Every speed test returns `skipReason: notCellular` | The device is on Wi-Fi. Turn Wi-Fi off, or set `cellularOnly: false`. |
| Speed test returns `skipReason: recentlyMeasured` | Inside the cooldown. Use `ignoreCooldown: true` or a shorter `measurementCooldown`. |
| `latencyMs` and `jitterMs` are always `null` | `pingEndpoint` isn't reachable (DNS error, refused connection, timeout). Open it in a browser from the device's network. |
| `Insecure HTTP is not allowed by platform` | An endpoint uses `http://`. Switch to HTTPS (see [Cleartext HTTP](#cleartext-http)). |
| Location prompt never appears on iOS | `NSLocationWhenInUseUsageDescription` is missing from `Info.plist`. |
| `pendingTelemetryCount()` keeps growing | Sends are failing. Check the `FlushResult` from `sendSnapshot` and your backend's logs. Auth headers are a common cause. |
| `collectSnapshot()` takes ~6 seconds | That's `gnssSampleDuration`. Set it to `Duration.zero` if you don't need the indoor/outdoor hint. |
| Location `status` is not `available` | Read `locationInfo.status`: permission denied, location services off, or no fix yet. |
| Assertion error when creating the config | A value is out of range. The message names the parameter; see the constraints in [section 6](#6-configuration-reference). |

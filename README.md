# network_quality

Flutter SDK (Android + iOS) that measures mobile network quality where
the user actually is: cellular radio signal and cell, connectivity,
location, device state, satellite/sensor indoor-outdoor hints, and a
speed test. Results go to a backend you choose, through an on-device
queue that survives bad connections.

The full list of collected fields is in [docs/data-fields.md](docs/data-fields.md);
iOS exposes far less than Android (no signal strength or cell IDs).

> **Adding this SDK to an app?** Follow the
> [integration guide](docs/integration-guide.md): installation, Android/iOS
> setup, the full configuration reference with defaults, recipes, the
> backend contract and troubleshooting.

## Getting started

### 1. Add the dependency

```yaml
dependencies:
  network_quality:
    git:
      url: git@github.com:OWNER/network_quality.git
      ref: v0.1.0
```

### 2. Platform setup

- **Android:** nothing. The SDK's permissions (location, phone state,
  network state, internet) merge into your app's manifest automatically,
  and the plugin handles the permission result itself - no
  `MainActivity` changes.
- **iOS:** add a location usage description to `ios/Runner/Info.plist`
  (plugins can't add Info.plist keys for you):

  ```xml
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Your location is recorded with each network measurement so signal quality can be mapped to where it was measured.</string>
  ```

Minimums: Android API 24, iOS 13, Dart 3.6 / Flutter 3.27. The Android
build file comes from the Flutter 3.47 plugin template (Android Gradle
Plugin 9, which compiles Kotlin itself); host apps still on AGP 8 have not
been tried.

### 3. Use it

```dart
import 'package:network_quality/network_quality.dart';

final service = NetworkQualityService(
  config: NetworkQualityConfig(
    baseUrl: Uri.parse('https://telemetry.example.com'),
    headers: {'Authorization': 'Bearer <token>'}, // optional
  ),
);

// At app start: deliver anything left over from a bad connection.
await service.flushPendingTelemetry();

var permissions = await service.checkPermissions(); // never prompts
if (!permissions.hasRequiredPermissions) {
  permissions = await service.requestPermissions(); // prompts
}

final snapshot = await service.collectSnapshot(); // ~6 s, no traffic
final measurement = await service.runActiveTest(); // up to ~15 MB

await service.sendSnapshot(snapshot); // never throws; queued on failure
await service.sendTestResult(measurement);
```

Keep one `NetworkQualityService` for the app's lifetime: its `sessionId`
is what links a snapshot to the speed test taken with it.

## API

| Member | What it does |
| --- | --- |
| `NetworkQualityService({required config, sessionId, timestampStore, queueStore})` | Creates the SDK. The stores replace the default `shared_preferences` storage |
| `checkPermissions()` | Which permissions are held, without prompting |
| `requestPermissions()` | Prompts for location (+ phone state on Android) |
| `openAppSettings()` | Opens the app's system settings, for permanently denied permissions |
| `collectSnapshot({freshLocation})` | Passive data: radio, cell, connectivity, location, device, GNSS, sensors, radio stats |
| `runActiveTest({includeDownload, includeUpload, cellularOnly, cooldown, ignoreCooldown})` | Speed test. Returns a result with `skipReason` set off cellular or inside the cooldown |
| `sendSnapshot(snapshot)` / `sendTestResult(result)` | Queue on disk, then try to send. Returns a `FlushResult` |
| `flushPendingTelemetry()` | Retry queued reports without adding any |
| `pendingTelemetryCount()` | Reports waiting to be delivered |
| `lastMeasurementAt()` / `timeUntilNextMeasurement()` | Cooldown state, e.g. for a "test again" button |
| `sessionId`, `config` | This instance's session and settings |

Everything else - collectors, queue, sender - is internal (`lib/src/`).

**The SDK doesn't ask the user anything.** If your app wants the user's
own indoors/outdoors answer (as `example/` does), ask it and send it
yourself.

**Timestamps are serialized as UTC**, and coarsened to 15 minutes;
coordinates are rounded to 3 decimals (~100 m). See
`lib/src/models/wire_privacy.dart`.

## Example app

`example/` runs the whole flow on launch (permissions -> snapshot ->
speed test -> indoors/outdoors question -> send) and shows every
collected field, with a Measure button that forces past the cooldown.

## Structure

- `lib/network_quality.dart` - the public API; import only this.
- `lib/src/models/` - plain Dart data classes, one per metric group, each
  with `fromJson`/`toJson`.
- `lib/src/collectors/` - one collector class per data source.
- `lib/src/network_quality_service.dart` - facade orchestrating the
  collectors.
- `lib/src/permission_manager.dart` - requests/inspects the Android
  permissions the cellular collector depends on.
- `lib/src/measurement_throttle.dart` - the 12-hour cooldown between
  measurements, plus its pluggable timestamp storage.
- `lib/src/models/network_quality_config.dart` - backend and tunables, see
  [Configuration](#configuration).
- `android/`, `ios/` - the native side; see [Native code](#native-code).

## What's implemented

- **Connectivity & network type** (`ConnectivityCollector`): connection
  type via `connectivity_plus`; VPN/metered/airplane-mode/roaming/carrier/
  MCC-MNC/generation/data-network-type via a native Android MethodChannel
  (`ConnectivityManager` + `TelephonyManager`). These extras are `null` on
  iOS - no public API.
- **Cellular radio metrics, Android** (`CellularCollector`): RSSI, RSRP,
  RSRQ, RSSNR/SINR, CQI, ASU, signal bars, cell ID, PCI, LAC, TAC, timing
  advance, registration state. Handles LTE, NR (5G), WCDMA and GSM cells,
  preferring the cell the device is registered on. Requires
  `READ_PHONE_STATE` + `ACCESS_FINE_LOCATION`; degrades to an empty result
  if permissions are missing rather than throwing. On API 29+ it calls
  `requestCellInfoUpdate()` for a fresh radio reading, falling back to
  `getAllCellInfo()` (which may return several-second-old cached data).
- **Cellular radio metrics, iOS** (`CellularCollectorIos`): **platform
  limitation, not a TODO** - iOS has no public API exposing signal-strength
  metrics (RSRP/RSSI/RSRQ/SINR/CQI/ASU/cell identifiers/timing advance).
  Only a coarse radio access technology label from
  `CTTelephonyNetworkInfo` is available; every numeric field is
  permanently `null` on this platform.
- **Location** (`LocationCollector`, via `geolocator`): latitude/longitude
  plus accuracy, altitude, speed, heading, mock-location flag and the
  fix's own timestamp. Uses the OS's cached last-known position by default
  so `collectSnapshot()` stays fast; pass `freshLocation: true` for a new
  fix. Never throws - when there's no fix the record carries a `status`
  saying why (permission denied, services off, no fix yet).
- **Device/system context** (`DeviceContextCollector`): battery level +
  charging state (`battery_plus`), device model + OS version
  (`device_info_plus`), app foreground/background state
  (`WidgetsBinding.lifecycleState`).
- **DNS / TCP / TLS timing** (`SpeedTestCollector`): implemented now via
  `InternetAddress.lookup`, `Socket.connect`, `SecureSocket.connect`
  against a public host - these don't need our own server.
- **Download & upload throughput** (`SpeedTestCollector`): both implemented
  against Cloudflare's speed-test origin (`__down` / `__up`), so neither
  needs first-party infrastructure. Measured 87.4 Mbps down / 20.3 Mbps up
  on a test link.
  - *Download* runs concurrent GETs for a fixed duration and excludes a
    warmup window so TCP slow-start doesn't drag the figure down.
    Concurrency matters: 4 connections measured 32.4 Mbps vs 20.1 Mbps on
    1 against the same host. Each request is cache-busted - carrier
    transparent proxies would otherwise serve a cached copy and report a
    fabricated speed.
  - *Upload* POSTs random (incompressible) chunks and counts a chunk only
    once the server has acknowledged it. Counting bytes handed to the
    socket instead would measure the kernel buffer and report absurd
    speeds - which is why the endpoint must not reply before reading the
    body to EOF. No warmup exclusion here: upload progress isn't
    observable at chunk granularity, so the figure includes slow-start and
    is mildly conservative.
- **Jitter math** (`SpeedTestCollector.computeJitterMs`): implemented -
  mean absolute difference between consecutive latency samples. Only
  useful once latency sampling itself works (see below).

## What's not done

Nothing is stubbed. The module has no `UnimplementedError` and no
outstanding `TODO(server)`.

One note on scope:

- **The retry queue needs a server-side counterpart to be fully correct.**
  It sends a client-generated `eventId` as an idempotency key, but the
  backend currently ignores it and assigns its own row id. Until the
  server honours the key, a send that times out *after* the server
  committed will duplicate on retry. The client side is done.

## Telemetry delivery

`TelemetryDispatcher` is the entry point; `TelemetrySender` is raw
transport and `TelemetryQueue` is the durable outbox.

Every report is written to disk **before** any send is attempted, and
removed only once the backend accepts it. That ordering is the whole
point: this SDK measures bad connections, so a failed send is the
expected path. `sendSnapshot` / `sendTestResult` therefore don't throw -
they return a `FlushResult` describing what was delivered, and anything
undelivered stays queued.

Retry policy:

- **Exponential backoff** from 30s, doubling, capped at 1 hour. A report
  in backoff is skipped rather than retried, so a recovering server isn't
  hammered by every client at once.
- **Dropped after 8 attempts or 3 days.** A measurement older than that
  describes a network that no longer exists, and retrying forever just
  burns battery and data.
- **Queue capped at 100 reports**, oldest evicted first, bounding disk use
  on a device that has been offline for a long time.
- **A backwards device clock doesn't stall delivery** - a far-future
  `nextAttemptAt` is treated as due, matching how the measurement throttle
  handles the same case.

Storage is injectable (`TelemetryQueueStore`); the default persists to
`shared_preferences`, and `InMemoryTelemetryQueueStore` exists for tests.
A corrupt stored entry is skipped rather than discarding the whole queue.

## Orchestration

- `collectSnapshot({bool freshLocation = false})` - all passive/instant
  data in one fast call, no network access. Location comes from the OS's
  cached last-known position to preserve that speed; `freshLocation: true`
  waits for a new fix instead, which is accurate but slow (seconds, longer
  indoors) and costs battery, so it suits deliberate drive-test flows
  rather than routine collection.
- `runActiveTest({includeDownload = true, includeUpload = true,
  cellularOnly = true, cooldown = 12 h, ignoreCooldown = false})` - DNS/TCP/TLS
  timing, latency, jitter and packet loss against the backend's ping
  endpoint, and download/upload throughput with TTFB and bytes used. Each
  measurement is isolated, so one failing doesn't stop the rest. Pass `includeDownload: false` on a
  metered connection - the throughput test transfers as much as it can for
  several seconds and is by far the most data-hungry thing here, and on
  cellular the user is paying for those bytes. `ConnectivityInfo.isMetered`
  from `collectSnapshot()` is the signal to decide on.

### Location

Attached to every snapshot as `locationInfo`, so radio metrics can be
mapped geographically. The object is always present - when no fix is
available it explains why via `LocationStatus` rather than being null,
since "user denied location" and "GPS hasn't got a fix yet" need different
handling downstream.

Three fields exist specifically to stop bad points polluting a coverage
map, and consumers should use them:

- `accuracyMeters` - Android 12+ users can grant *approximate* location,
  which lands around 1-3 km and is otherwise indistinguishable from a GPS
  fix.
- `isMocked` - the OS's mock-provider flag. Spoofed GPS puts real signal
  readings at fake coordinates.
- `fixTimestamp` / `fixAge` - the default path returns a cached fix that
  may be minutes old.

`geolocator` is used here rather than a hand-rolled MethodChannel: unlike
full `CellInfo`, location has a well-maintained cross-platform plugin, and
writing `FusedLocationProviderClient` plus `CLLocationManager` by hand
would be a lot of native surface for nothing gained.

Devices without Google Play Services (Huawei and similar) are handled:
`geolocator_android` checks `isGooglePlayServicesAvailable()` and falls
back to the platform `LocationManager` on its own, so no extra
configuration is needed. `AndroidSettings.forceLocationManager` can force
that path if the fused provider ever misbehaves.

**Privacy:** this makes snapshots personal data. Only `whenInUse` location
is requested - no background tracking - but retention, a deletion path,
and store privacy declarations all need settling before shipping. See the
privacy section in `docs/backend-api-spec.md`.

## Configuration

`NetworkQualityConfig` holds everything tunable. Only `baseUrl` is
required: the SDK has no backend of its own. Telemetry goes to
`<baseUrl>/api/telemetry/location` and `/api/telemetry/speedtest`, and
latency is probed at `<baseUrl>/speedtest/ping`; each can be overridden.
`headers` are added to every request to the backend (not to the
third-party throughput endpoints), for auth.

Settings resolve in three layers, each overriding the one before:

1. **Built-in defaults** - everything except `baseUrl`.
2. **Instance config** - passed at construction by the host app.
3. **Per-call arguments** - override the config for one call.

```dart
final service = NetworkQualityService(
  config: NetworkQualityConfig(
    baseUrl: Uri.parse('https://telemetry.example.com'),
    downloadEndpoint: Uri.parse('https://speed.example.com/speedtest.bin'),
    downloadTestDuration: const Duration(seconds: 8),
    downloadParallelConnections: 6,
    measurementCooldown: const Duration(minutes: 15),
  ),
);

// One-off override, e.g. a user-tapped "test again".
await service.runActiveTest(ignoreCooldown: true, cellularOnly: false);
```

Changing hosts therefore needs no module code change - which matters,
because where they live determines what the numbers mean.

**Both default to Cloudflare**, which is a deliberate trade-off worth
re-reading before trusting the data: Cloudflare peers with, and often
caches inside, carrier networks. Throughput to it is near best case and
won't match what users get to an arbitrary destination. Measuring against
a first-party server instead reflects real-world paths, at the cost of
that server's own capacity and location becoming part of the measurement.

### Data cost

This runs on users' cellular data, so the defaults are deliberately
modest. **A run costs at most 14.7 MB** (10 MiB down + 4 MiB up), measured
end to end:

```
down  74.9 Mbps   used 10.51 MB   (byte-capped)
up    15.4 Mbps   used  4.19 MB   (byte-capped)
TOTAL             14.70 MB
```

Slower links cost proportionally less, because they hit the 4-second
duration limit before the byte cap:

| Link speed | Download | Upload | Total per run |
|---|---|---|---|
| 2 Mbps | 1.0 MB | 1.0 MB | **~2 MB** |
| 5 Mbps | 2.5 MB | 2.1 MB | **~4.6 MB** |
| 10 Mbps | 5.0 MB | 4.2 MB (cap) | **~9.2 MB** |
| 20 Mbps | 10.0 MB | 4.2 MB (cap) | **~14.2 MB** |
| 50 Mbps+ | 10.5 MB (cap) | 4.2 MB (cap) | **14.7 MB** |

So the fastest users pay the most - the byte cap, not the clock, is what
bounds them.

**Both caps are hard.** The upload loop budgets bytes when a request
*starts*, not when it completes; checking acknowledged bytes instead let
every worker begin one final chunk after the cap was reached, overshooting
by `parallelConnections × chunkBytes` (25% over budget at the defaults).

**Aggregate cost.** The 12-hour cooldown caps a device at two runs a day,
so the worst case is **~30 MB/day, under 1 GB/month** - and that only for
users fast enough to hit both byte caps every time. A 10 Mbps user costs
about 18 MB/day.

The cooldown is the strongest lever available: it bounds how often
anything is spent at all, whereas the byte caps only bound each
individual run. Lower them too if you need to go further; accuracy on
fast links degrades first, slow links are unaffected.

`SpeedTestCollector.lastDownloadBytes` / `lastUploadBytes` report what the
most recent run actually spent, so this can be monitored rather than
assumed.

`NetworkQualityConfig` is deliberately **not** JSON-serializable. There is
no remote-config endpoint, and values come from the host app's own source
rather than over the network, so the parsing and clamping such a path
would require would be dead weight.

If that ever changes, it isn't a matter of adding `fromJson`: this object
decides what URL a fleet of devices fetches and on how many parallel
connections, so a remotely-supplied version would have to treat its input
as hostile - clamped ranges, a hostname allowlist, HTTPS-only transport.
That's a different design from the plain value object it is today.

Range checks are debug-only `assert`s (warmup shorter than the test,
positive connection count). A wrong value here is a programming error to
catch loudly in development, not a runtime condition to defend against.

### Measurement cadence and the 12-hour cooldown

Measurements are triggered by the host app opening - there is no
background collection, and the module never schedules anything itself.

`runActiveTest()` additionally suppresses a run if one completed within
`cooldown` (12 hours by default), returning
`skipReason == MeasurementSkipReason.recentlyMeasured`. Without it a user
who reopens the app repeatedly would spend their mobile data on
near-duplicate readings and skew aggregates toward the most frequent app
openers. At two runs a day per device, coverage comes from having many
users rather than from sampling any one of them densely.

The timestamp is persisted via `shared_preferences`, so the window
survives an app restart - which is the only case that matters, given
measurements happen at app open.

Details worth knowing:

- **Only a run that actually measured records a timestamp.** Skips don't,
  so being on Wi-Fi never consumes the window.
- **The cellular gate is checked first**, so a Wi-Fi session reports
  `notCellular` rather than the less specific cooldown reason.
- **Exactly one cooldown measures rather than skips**, so a caller polling
  on exactly that interval isn't starved by boundary rounding.
- **A device clock moved backwards measures rather than blocking.**
  Treating a future timestamp as "within cooldown" would otherwise
  suppress measurement until real time caught up.
- `lastMeasurementAt()` and `timeUntilNextMeasurement()` let the host app
  show "checked N minutes ago" or disable a retry button, instead of
  calling and getting a skip back. `ignoreCooldown: true` serves a
  user-initiated "test again".

Storage is injectable (`MeasurementTimestampStore`), so a host app can
substitute its own; `InMemoryMeasurementTimestampStore` exists for tests.

### Cellular-only by default

`runActiveTest()` measures **only on a cellular connection**. The module
exists to characterise the cellular network, so timings taken over Wi-Fi
or ethernet describe a different link and would corrupt the dataset.

Off cellular it returns immediately with every metric `null` and
`skipReason == MeasurementSkipReason.notCellular`, rather than throwing or
returning nothing - the result still records `connectionType`, so a
consumer can tell **"did not measure"** apart from **"measured and
failed"**. Both look like null metrics otherwise, and conflating them
would silently drag quality aggregates down with fake zero-throughput
events.

The gate reads connection type via `ConnectivityCollector`, which is
local and makes no network calls, so it costs nothing when it skips. Pass
`cellularOnly: false` to measure on any connection.

Both results carry a `sessionId` (uuid, generated per `NetworkQualityService`
instance) so they can be correlated with each other once a backend exists.

## Native code

The Dart side talks to native code over these MethodChannels:

| Channel | Native handler |
| --- | --- |
| `network_quality/cellular` | `android/src/main/kotlin/uz/buildx/network_quality/CellularChannelHandler.kt` |
| `network_quality/connectivity` | `.../ConnectivityChannelHandler.kt` |
| `network_quality/gnss` | `.../GnssChannelHandler.kt` |
| `network_quality/context` | `.../ContextChannelHandler.kt` |
| `network_quality/permissions` | `.../PermissionChannelHandler.kt` |
| `network_quality/cellular_ios`, `network_quality/context_ios` | `ios/network_quality/Sources/network_quality/NetworkQualityPlugin.swift` |

On Android, `NetworkQualityPlugin.kt` registers the handlers, starts
`RadioMonitor`, and - as an `ActivityAware` plugin - hands the permission
handler the current Activity and listens for permission results, dropping
the Activity reference on detach so it can't leak.

On iOS the plugin links CoreTelephony, CoreMotion and Network, and ships a
privacy manifest (`PrivacyInfo.xcprivacy`) declaring precise location and
diagnostic data, not linked to identity, not used for tracking. Review it
against your app's own privacy answers.

The Kotlin deliberately uses `PackageManager.checkPermission` instead of
androidx's `ContextCompat`, so it depends on nothing beyond the Android
framework itself.

### Android API-level caveats

The SDK's `minSdk` is 24, and several of the APIs involved are newer, so
the handlers guard them explicitly and report `null` below the threshold:

- LTE `rsrp`/`rsrq`/`rssnr`/`cqi` and timing advance: public API 26+.
- `requestCellInfoUpdate()` and 5G NR cell info: API 29+.
- VPN detection via `NetworkCapabilities`: API 23+ (the Dart side falls
  back to connectivity_plus's VPN signal below that).
- `getDataNetworkType()`: API 24+ (falls back to `getNetworkType()`).

### Cleartext HTTP

The default throughput endpoints (Cloudflare) are HTTPS. Use an HTTPS
`baseUrl` too, and the host app needs no cleartext exemptions: no
`network_security_config.xml` on Android, no ATS exception on iOS.

If you point an endpoint at a plain-HTTP host, it works on Flutter 3.27.4
(`dart:io`'s `HttpClient` bypasses both platform policies) but fails on
Flutter 3.44+ with `Insecure HTTP is not allowed by platform: <host>`.
Add a host-scoped exemption on each platform rather than
`usesCleartextTraffic="true"` / `NSAllowsArbitraryLoads`.

## Permissions

Android permissions are declared in the SDK's own
`android/src/main/AndroidManifest.xml` (INTERNET, ACCESS_NETWORK_STATE,
ACCESS_WIFI_STATE, ACCESS_FINE_LOCATION, ACCESS_COARSE_LOCATION,
READ_PHONE_STATE) and merge into the host app. On iOS the host app adds
NSLocationWhenInUseUsageDescription to its `Info.plist`.

Requesting is implemented in `PermissionManager` (Android, over the
`network_quality/permissions` channel) and `LocationCollector` (iOS, via
geolocator). `NetworkQualityService` picks the right one per platform, so
callers just use `checkPermissions()` / `requestPermissions()`:

```dart
var permissions = await service.checkPermissions();   // never prompts
if (!permissions.hasRequiredPermissions) {
  permissions = await service.requestPermissions();   // prompts
}

if (permissions.isPermanentlyDenied) {
  // No dialog will appear again; settings is the only route.
  await service.openAppSettings();
}
```

Why it's hand-rolled rather than using `permission_handler`: the only
permissions needed are Android's, and a cross-platform permissions plugin
would both add a dependency for consumers of the extracted SDK and compile
in iOS permission APIs this module never calls (which Apple can query at
review time). `PermissionManager` is a no-op returning `notRequired` on
non-Android platforms. On iOS, location is the only permission the module
needs, so `NetworkQualityService.requestPermissions()` routes to
`LocationCollector.requestPermission()` there and reports the outcome in
`PermissionStatuses.fineLocation`.

On Android, `ACCESS_FINE_LOCATION` serves both the cellular metrics and
the location fix, so a single prompt satisfies both.

Two behaviours worth knowing:

- **Android needs *both* `ACCESS_FINE_LOCATION` and `READ_PHONE_STATE`**
  before `getAllCellInfo()` returns anything. With either missing it
  returns an empty list rather than an error, so `CellularInfo` comes back
  all-null and looks like a device with no signal. Check
  `hasRequiredPermissions` before trusting empty cellular data.
- **`checkPermissions()` never reports `permanentlyDenied`.** Android only
  exposes that via `shouldShowRequestPermissionRationale`, which is
  meaningless until at least one request has been made - reporting it
  pre-request would flag a fresh install as permanently denied. Only
  `requestPermissions()` returns that state.

Prompting is never triggered automatically by `collectSnapshot()`; a
permission dialog appearing as a side effect of reading data would be a
poor experience, and only the host app knows where in its flow to ask.

## Tests

`flutter test` in the package root runs `test/network_quality_test.dart`.
It covers the jitter math, the config (derived endpoints, header
redaction), the retry queue and cooldown, JSON round-tripping (including
null preservation for unavailable metrics), and the enum-name contract
between the Kotlin handlers and the Dart enums - if you rename a
`DataNetworkType`/`CellularGeneration` value, that test is what catches
the drift. `flutter test` in `example/` runs a widget smoke test of the
demo screen.

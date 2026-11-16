# Network Quality SDK — Data Collection Reference

Authoritative inventory of everything the SDK reads from the device and
transmits. Field names match the wire format exactly; source APIs and
defaults were verified against the implementation.

**Module:** `lib/network_quality/`
**Platforms:** Android, iOS
**Status:** hackathon prototype — see [Not production-ready](#not-production-ready)

---

## 1. Collection model

| Property | Value |
|---|---|
| Trigger | Host app calls the SDK; the demo app does so on launch |
| Background collection | **None.** No background modes, no background location, no scheduler |
| Minimum interval | **12 hours** between active measurements (persisted across restarts) |
| Maximum frequency | 2 active measurements per device per day |
| Network condition | Active measurements run **only on cellular** by default |

Two payloads are produced per run, correlated by `sessionId`:

| Payload | Endpoint | Contents | Network use |
|---|---|---|---|
| Snapshot | `POST /api/telemetry/location` | Sections 4.1–4.4 | None (local reads only) |
| Measurement | `POST /api/telemetry/speedtest` | Section 4.5 | Yes — see [Data volume](#6-data-volume) |

The snapshot is not throttled: it reads only local state, costs no data,
and is cheap to produce. Only the active measurement is rate-limited.

---

## 2. Permissions

### Android

| Permission | Purpose | Consequence if denied |
|---|---|---|
| `INTERNET` | Transmit reports, run throughput tests | SDK non-functional |
| `ACCESS_NETWORK_STATE` | Connection type, metered status, VPN detection | Connectivity fields null |
| `ACCESS_WIFI_STATE` | Connection type resolution | Connectivity fields degraded |
| `ACCESS_FINE_LOCATION` | **Required by Android for `getAllCellInfo()`**, and for the geographic fix | All cellular radio metrics empty |
| `ACCESS_COARSE_LOCATION` | Declared so an "approximate only" grant still yields a usable fix | — |
| `READ_PHONE_STATE` | Carrier, MCC/MNC, network type, cell info | Carrier and radio fields null |

> Android requires **both** `ACCESS_FINE_LOCATION` and `READ_PHONE_STATE`
> before `getAllCellInfo()` returns anything. With either missing it
> returns an *empty list rather than an error*, so cellular metrics come
> back all-null and resemble a device with no signal. `PermissionStatuses`
> is exposed so callers can distinguish the two.

### iOS

| Key | Purpose |
|---|---|
| `NSLocationWhenInUseUsageDescription` | Geographic fix. The only permission the SDK requests on iOS |

No `NSLocationAlwaysAndWhenInUseUsageDescription`, no `UIBackgroundModes`.
Location is requested as *when-in-use* only.

---

## 3. Identifiers

| Identifier | Nature | Stability |
|---|---|---|
| `sessionId` | UUID v4, generated from the platform CSPRNG (`Random.secure()`) | **Regenerated per SDK instance** — in practice, per app launch. Not persisted |
| `eventId` | UUID v4, one per report | Unique per report; stable across retries of that report |

`sessionId` correlates a snapshot with the measurement taken alongside it.
It is **not** a device or user identifier, is not derived from any hardware
value, and cannot be used to link two app sessions.

**Consequence:** there is currently no identifier by which a given user's
data could be located or deleted on request. Adding a stable pseudonymous
device ID is a deliberate decision that has not been made — see
[Open questions](#8-open-questions).

---

## 4. Data inventory

Legend: **A** = Android, **i** = iOS. All fields are nullable unless
marked required.

### 4.1 Connectivity — `connectivityInfo`

| Field | Type | Source | A | i |
|---|---|---|:-:|:-:|
| `connectionType` | enum, required | `connectivity_plus` | ✅ | ✅ |
| `isVpnActive` | bool | `NetworkCapabilities.hasTransport(TRANSPORT_VPN)` (API 23+); falls back to `connectivity_plus` | ✅ | ⚠️ |
| `isMetered` | bool | `ConnectivityManager.isActiveNetworkMetered` | ✅ | ❌ |
| `isAirplaneModeOn` | bool | `Settings.Global.AIRPLANE_MODE_ON` | ✅ | ❌ |
| `isDataRoaming` | bool | `TelephonyManager.isNetworkRoaming` | ✅ | ❌ |
| `carrierName` | string | `TelephonyManager.getNetworkOperatorName()` | ✅ | ❌ |
| `mcc` | string | `TelephonyManager.getNetworkOperator()`, first 3 digits | ✅ | ❌ |
| `mnc` | string | same, remaining digits | ✅ | ❌ |
| `cellularGeneration` | enum | derived from `getDataNetworkType()` | ✅ | ❌ |
| `dataNetworkType` | enum | `getDataNetworkType()` (API 24+), else `getNetworkType()` | ✅ | ❌ |
| `timestamp` | ISO-8601 UTC, required | — | ✅ | ✅ |

`mcc`/`mnc` are transmitted as **strings**, not integers — leading zeros
are significant.

### 4.2 Cellular radio — `cellularInfo`

Android only. Read from `TelephonyManager.requestCellInfoUpdate()` on
API 29+ (a fresh radio reading), falling back to `getAllCellInfo()`.
Covers LTE, NR (5G), WCDMA and GSM, preferring the registered cell.

| Field | Unit | Source | Typical range |
|---|---|---|---|
| `rssi` | dBm | `CellSignalStrength.getDbm()` | −113 … −51 |
| `rsrp` | dBm | `getRsrp()` (LTE, API 26+) / `getSsRsrp()` (NR, API 29+) | −140 … −44 |
| `rsrq` | dB | `getRsrq()` / `getSsRsrq()` | −20 … −3 |
| `rssnr` | dB | `getRssnr()` / `getSsSinr()` | −20 … 30 |
| `cqi` | index | `getCqi()` (LTE, API 26+) | 0 … 15 |
| `asuLevel` | index | `getAsuLevel()` | 0 … 97 |
| `signalLevel` | bars | `getLevel()` | 0 … 4 |
| `cellId` | — | `CellIdentityLte.getCi()` / `CellIdentityNr.getNci()` / `getCid()` | see note |
| `pci` | — | `getPci()`; WCDMA reports PSC in this field | 0 … 1007 |
| `lac` | — | `CellIdentityGsm/Wcdma.getLac()` | 0 … 65535 |
| `tac` | — | `CellIdentityLte/Nr.getTac()` | 0 … 16777215 |
| `timingAdvance` | — | `getTimingAdvance()` (API 26+) | 0 … 1282 |
| `isRegistered` | bool | `CellInfo.isRegistered()` | — |
| `radioAccessTechnology` | string | `CTTelephonyNetworkInfo` — **iOS only** | e.g. `LTE` |
| `timestamp` | ISO-8601 UTC, required | — | — |

> **`cellId` requires a 64-bit integer.** On 5G NR it carries the NCI,
> which is 36 bits (up to ~68.7 billion). A 32-bit column overflows. LTE
> CI is 28 bits and fits; NR does not.

`lac` and `tac` are mutually exclusive in practice — `lac` on 2G/3G, `tac`
on LTE/NR — so one of the two is null on every record.

> **iOS platform limitation.** Apple exposes no public API for cellular
> signal strength. Every numeric field above is permanently `null` on iOS;
> only `radioAccessTechnology` is available. This is a platform
> constraint, not an implementation gap. Full radio data is Android-only.

Below API 26, LTE `rsrp`/`rsrq`/`rssnr`/`cqi` and timing advance were not
public API and are reported as null on those devices.

### 4.3 Location — `locationInfo`

Source: `geolocator`. Uses the OS **last-known position** by default so
collection stays fast; a fresh fix is opt-in.

| Field | Unit | Notes |
|---|---|---|
| `status` | enum, required | `available`, `permissionDenied`, `permissionPermanentlyDenied`, `servicesDisabled`, `unavailable`, `notCollected` |
| `latitude` | degrees | WGS-84 |
| `longitude` | degrees | WGS-84 |
| `accuracyMeters` | m | Horizontal accuracy radius — **see below** |
| `altitudeMeters` | m | |
| `speedMps` | m/s | Ground speed |
| `headingDegrees` | degrees | Clockwise from true north |
| `isMocked` | bool | OS mock-provider flag — **see below** |
| `fixTimestamp` | ISO-8601 UTC | When the fix was taken; **may predate `timestamp`** |
| `timestamp` | ISO-8601 UTC, required | When the record was assembled |

Coordinate fields are null unless `status == available`. The object itself
is always present, so the reason for a missing fix is always recorded.

Three fields exist specifically for data quality filtering:

- **`accuracyMeters`** — Android 12+ permits an *approximate only* grant,
  typically 1–3 km. Such points are indistinguishable from a GPS fix
  except by this field, and are unusable for per-cell attribution.
- **`isMocked`** — spoofed GPS places genuine radio readings at fabricated
  coordinates, which corrupts a coverage map more than a gap would.
- **`fixTimestamp`** — the default path returns a cached fix that may be
  minutes old. Compare against `timestamp` to obtain its age.

### 4.4 Device context — `deviceContext`

| Field | Type | Source |
|---|---|---|
| `deviceModel` | string | `device_info_plus` (`Build.MODEL` / `utsname.machine`) |
| `osVersion` | string | `device_info_plus` |
| `batteryLevel` | int, 0–100 | `battery_plus` |
| `isCharging` | bool | `battery_plus` |
| `isAppInForeground` | bool, required | `WidgetsBinding.lifecycleState` |
| `timestamp` | ISO-8601 UTC, required | — |

### 4.5 Active measurement — `ActiveMeasurement`

| Field | Unit | Measured against |
|---|---|---|
| `downloadMbps` | Mbit/s | Cloudflare (`speed.cloudflare.com/__down`) |
| `uploadMbps` | Mbit/s | Cloudflare (`speed.cloudflare.com/__up`) |
| `latencyMs` | ms | First-party `GET /speedtest/ping`; mean of 10 samples |
| `jitterMs` | ms | Mean absolute difference between consecutive RTT samples |
| `dnsResolutionMs` | ms | `InternetAddress.lookup` against a public host |
| `tcpConnectionMs` | ms | `Socket.connect` |
| `tlsHandshakeMs` | ms | `SecureSocket.connect` |
| `connectionType` | enum, required | Connection type at time of test |
| `skipReason` | enum | Why no measurement was taken |
| `sessionId` | string, required | Correlates with the snapshot |
| `timestamp` | ISO-8601 UTC, required | |

Latency samples 11 round trips and **discards the first**, which includes
DNS and TCP setup; retaining it would distort jitter disproportionately.

**`skipReason`** distinguishes "not measured" from "measured and failed" —
both otherwise present as null metrics, and conflating them would bias
aggregates downward with phantom zero-throughput events.

| Value | Meaning |
|---|---|
| `notCellular` | Device was on Wi-Fi/Ethernet; measuring would describe a different link |
| `recentlyMeasured` | A measurement ran within the 12-hour window |

---

## 5. Data flows

| Recipient | Data sent | Transport |
|---|---|---|
| `dev.uzproger.ru` (first party) | Both payloads in full, including location | HTTPS |
| `speed.cloudflare.com` (third party) | No payload. Throughput test traffic only — random bytes up, discard bytes down | HTTPS |
| `example.com` (third party) | No payload. DNS/TCP/TLS timing probes only | — |

Cloudflare and the DNS probe host do not receive any collected field.
They do observe the **device IP address** as an unavoidable property of
being contacted, which is worth recording in a privacy assessment.

---

## 6. Data volume

Per active measurement, hard-capped:

| Direction | Cap | Measured |
|---|---|---|
| Download | 10 MiB | 10.51 MB |
| Upload | 4 MiB | 4.19 MB |
| **Total** | | **14.70 MB** |

Slower links consume less, bounded by a 4-second duration limit rather
than the byte cap:

| Link speed | Total per measurement |
|---|---|
| 2 Mbit/s | ~2 MB |
| 5 Mbit/s | ~4.6 MB |
| 10 Mbit/s | ~9.2 MB |
| 20 Mbit/s | ~14.2 MB |
| 50 Mbit/s+ | 14.7 MB (capped) |

At two measurements per day, worst case is **~30 MB/day, under 1 GB/month**
— and only for users fast enough to reach both caps every time.

Snapshots add no measurable traffic (a few KB of JSON).

---

## 7. On-device storage

| Key | Store | Contents | Lifetime |
|---|---|---|---|
| `network_quality.last_measurement_at_ms` | `SharedPreferences` / `NSUserDefaults` | Epoch ms of last measurement | Until app uninstall |
| `network_quality.telemetry_queue` | same | Undelivered reports, JSON | Until delivered, 3 days old, or 8 failed attempts |

Reports are persisted **before** any send is attempted and removed only on
acceptance, so a failed transmission does not lose data. Retries use
exponential backoff (30s → 1h). Queue capped at 100 reports, oldest
evicted first.

The queue holds full report payloads, so **location data is at rest on the
device** while undelivered.

---

## 8. Not collected

- No background collection of any kind
- No IMEI, IMSI, MSISDN, advertising ID, or any hardware identifier
- No account, contact, or personally identifying user data
- No traffic contents, browsing history, DNS queries, or app inventory
- No Wi-Fi SSID/BSSID or scan results
- No persistent identifier linking sessions

---

## Not production-ready

Known gaps, accepted for the prototype:

1. **The ingest endpoints are unauthenticated.** Any party can POST
   arbitrary records to the dataset.
2. **Idempotency is not honoured server-side.** The client sends `eventId`
   unchanged across retries, but the server assigns its own row ID, so a
   send that times out after commit will duplicate.
3. **No deletion path.** No stable identifier exists to locate a given
   user's records.
4. **Retention is undefined.** No TTL is enforced on raw coordinates.

## Open questions

- Should a stable pseudonymous device ID be introduced? It enables
  per-device analysis and deletion requests, at the cost of making the
  dataset linkable across sessions.
- Should coordinates be truncated (~4 decimal places ≈ 11 m) or reduced to
  a geohash tile before transmission? Coverage analysis rarely needs full
  GPS precision.
- What retention period applies to raw coordinates, versus derived
  per-cell aggregates?

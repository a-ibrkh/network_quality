# Collected Data Fields and Units

Every field the app sends to the backend, with its unit or format.

The app sends two kinds of report:

1. **Location report** → `POST /api/telemetry/location`, sent each time the app collects a reading.
2. **Speed-test report** → `POST /api/telemetry/speedtest`, sent after each active test.

**Rounding before sending.** Coordinates are rounded to 3 decimal places (about 100 m), and every timestamp is rounded down to 15 minutes in UTC. Both settings are in `lib/network_quality/models/wire_privacy.dart`.

**Platforms.** The cellular values come from the Android code. On iOS only `radioAccessTechnology` is filled in.

## 1. Location report

### Top level

| Field | Unit / format |
|---|---|
| `sessionId` | Random ID (UUID v4), new each app launch |
| `eventId` | Random ID (UUID v4), one per report, unchanged across retries |
| `timestamp` | UTC ISO 8601 time, rounded down to 15 min |

### `locationInfo`

| Field | Unit / format |
|---|---|
| `status` | One of `available`, `permissionDenied`, `permissionPermanentlyDenied`, `servicesDisabled`, `unavailable`, `notCollected` |
| `latitude`, `longitude` | Decimal degrees (WGS84), rounded to 3 decimal places (~100 m) |
| `accuracyMeters` | Metres: the phone's own error estimate, before rounding |
| `altitudeMeters` | Metres. Android measures from the WGS84 ellipsoid; iOS from mean sea level, so the two differ by tens of metres |
| `speedMps` | Metres per second |
| `headingDegrees` | Degrees clockwise from true north (0–360). On Android this is the direction of travel, not compass heading |
| `isMocked` | true/false: the OS reported a fake GPS location |
| `fixTimestamp` | UTC ISO 8601 time when the position was taken, rounded down to 15 min |
| `timestamp` | UTC ISO 8601 time, rounded down to 15 min |

### `connectivityInfo`

| Field | Unit / format |
|---|---|
| `connectionType` | One of `wifi`, `cellular`, `ethernet`, `none` |
| `isVpnActive`, `isMetered`, `isAirplaneModeOn`, `isDataRoaming` | true/false |
| `carrierName` | Text, e.g. "Beeline UZ" |
| `mcc` | Country code (text), e.g. `434` for Uzbekistan |
| `mnc` | Operator code (text), e.g. `04` |
| `cellularGeneration` | One of `g2`, `g3`, `g4`, `g5`, `unknown` |
| `dataNetworkType` | One of `gprs`, `edge`, `umts`, `hsdpa`, `hsupa`, `hspa`, `hspap`, `cdma`, `evdo0`, `evdoA`, `evdoB`, `ehrpd`, `lte`, `lteCa`, `nr`, `gsm`, `tdScdma`, `iwlan`, `unknown` |
| `timestamp` | UTC ISO 8601 time, rounded down to 15 min |

### `cellularInfo`

Describes the serving cell. Empty when the phone is not on mobile data.

| Field | Unit | Typical range |
|---|---|---|
| `rssi` | dBm | About −113 to −51. On LTE and 3G this holds a different measure; see [Things to know](#things-to-know-when-reading-the-data) |
| `rsrp` | dBm | −140 to −44 (LTE/5G) |
| `rsrq` | dB | −20 to −3 (LTE); about −43 to 20 (5G) |
| `rssnr` | dB (on 5G this is SINR) | −20 to 30 (LTE); −23 to 40 (5G) |
| `cqi` | No unit (index) | 0–15, LTE only |
| `asuLevel` | No unit (index) | LTE 0–97, GSM/3G 0–31 |
| `signalLevel` | Signal bars | 0–4 |
| `cellId` | Integer ID | GSM/3G CID, LTE ECI (28-bit), 5G NCI (36-bit) |
| `pci` | Integer ID | LTE 0–503, 5G 0–1007. 3G puts its scrambling code here (0–511) |
| `lac` | Integer ID | GSM/3G location area code |
| `tac` | Integer ID | LTE/5G tracking area code |
| `timingAdvance` | Steps of distance to the cell tower | LTE 0–1282, each ≈ 78 m; GSM 0–219, each ≈ 550 m |
| `isRegistered` | true/false | |
| `radioAccessTechnology` | Text label, e.g. "LTE" | iOS only |
| `timestamp` | UTC ISO 8601 time, rounded down to 15 min | |

### `deviceContext`

| Field | Unit / format |
|---|---|
| `batteryLevel` | Percent, 0–100 |
| `isCharging` | true/false |
| `deviceModel` | Text, e.g. "Pixel 7", "iPhone14,5" |
| `osVersion` | Text, e.g. "Android 14" |
| `isAppInForeground` | true/false |
| `timestamp` | UTC ISO 8601 time, rounded down to 15 min |

### `gnssInfo`

Satellite visibility, as raw hints for whether the reading was taken indoors or outdoors. The app turns GPS on for 6 seconds per snapshot to collect it. Android only; on iOS `status` is always `unsupported`. Null in reports queued before this field was added.

| Field | Unit / format |
|---|---|
| `status` | One of `ok`, `noData` (GPS ran but saw nothing), `permissionDenied` (no precise location), `gpsDisabled`, `unsupported` |
| `satellitesUsed` | Count: most satellites used in a position fix during the window. Can stay 0 for several seconds even outdoors while GPS starts |
| `satellitesVisible` | Count: most satellites received with a measurable signal |
| `topCn0DbHz` | dB-Hz: average signal strength (carrier-to-noise density) of the 4 strongest satellites, best value in the window |
| `sampleSeconds` | Seconds GPS was listened to |
| `timestamp` | UTC ISO 8601 time, rounded down to 15 min |

The app shows this rule on screen; the server can apply it or its own:

| Hint | Rule |
|---|---|
| Likely indoors | `status` is `noData`, or ≤ 3 satellites visible, or `topCn0DbHz` < 25 |
| Likely outdoors | ≥ 6 satellites visible and `topCn0DbHz` ≥ 33 |
| In between | Anything else with `status` `ok` (near a window, between tall buildings) |
| Unknown | `permissionDenied`, `gpsDisabled`, `unsupported` |

## 2. Speed-test report

| Field | Unit / format |
|---|---|
| `sessionId`, `eventId` | Random IDs (UUID v4) |
| `timestamp` | UTC ISO 8601 time, rounded down to 15 min |
| `connectionType` | One of `wifi`, `cellular`, `ethernet`, `none` |
| `skipReason` | `notCellular`, `recentlyMeasured`, or null if the test ran |
| `downloadMbps` | Megabits per second (1 Mb = 1,000,000 bits), measured against Cloudflare |
| `uploadMbps` | Megabits per second, measured against Cloudflare |
| `latencyMs` | Milliseconds: average round-trip time to `/speedtest/ping` |
| `jitterMs` | Milliseconds: average difference between consecutive round-trip times |
| `dnsResolutionMs` | Milliseconds |
| `tcpConnectionMs` | Milliseconds |
| `tlsHandshakeMs` | Milliseconds |
| `packetLossPercent` | Percent (0–100): share of the latency probes that failed |
| `ttfbMs` | Milliseconds: mean time to first byte over the download requests |
| `downloadBytes`, `uploadBytes` | Bytes the test actually transferred |

Fields added since this page was written (neighbour cells, service state, sensors, radio stats and more) are listed in [backend-new-fields.md](backend-new-fields.md).

## Things to know when reading the data

- **`rssi` holds a different measure on LTE and 3G.** The Android code fills it from a value that is RSRP on LTE and RSCP on 3G. Only on GSM is it real RSSI. LTE rows therefore have the RSRP value in both `rssi` and `rsrp`.
- **Older Android phones.** On Android 7 and older (API ≤ 25), the LTE fields `rsrp`, `rsrq`, `rssnr`, `cqi` and `timingAdvance` are always null, and so is GSM `timingAdvance`.
- **Missing speed or heading.** When the phone has no speed or heading, the location plugin reports 0 on Android and −1 on iOS instead of null. A 0 can mean "unknown" rather than "standing still".
- **Accuracy vs. rounding.** `accuracyMeters` is the phone's estimate before rounding. After rounding, the real error of a sent point is at least about 100 m.

Some data never leaves the phone: permission states, the retry queue's bookkeeping (attempts, next retry time), and the byte counts shown on the debug screen.

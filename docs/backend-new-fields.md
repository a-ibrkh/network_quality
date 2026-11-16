# New Telemetry Fields: Backend Changes

The mobile app now sends more fields on both telemetry endpoints. The current API schema doesn't declare them, so **FastAPI silently drops them today**. Requests still succeed (no 422), but the data is lost until the request models and the database are extended.

This document lists every new key, its type, unit and allowed values, plus ready-to-paste Pydantic models.

## Summary

| Endpoint | Where | What's new |
|---|---|---|
| **Both endpoints** | top level | `userReportedEnvironment` is **no longer sent** from SDK 0.1.0. See [section 0](#0-userreportedenvironment-removed) |
| `POST /api/telemetry/location` | `cellularInfo` | 9 new keys, including a `neighborCells` array. **`rssi` changed meaning** (see below) |
| | `connectivityInfo` | 19 new keys |
| | `deviceContext` | 2 new keys |
| | `gnssInfo` | **New object** (6 keys) |
| | `environmentInfo` | **New object** (6 keys) |
| | `radioStats` | **New object** (8 keys) |
| `POST /api/telemetry/speedtest` | top level | `packetLossPercent` and `ttfbMs` (fields **already exist** in the API, now filled), plus 2 new keys |

## General rules

- **Every new key is optional and nullable.** Many values exist only on some platforms or OS versions. Older app builds and reports queued before the update omit the keys entirely. Never make a new field required.
- **Platform.** Most fields are Android-only. The few iOS sends are marked **iOS** below.
- **Timestamps.** Every new object has a `timestamp` field: UTC ISO 8601, rounded down to 15 minutes like all other timestamps.
- **Categorical values** are sent as plain strings, not integers. Store them as text or as an enum that tolerates unknown values, because new values may appear in later app versions.
- **Units:** dBm and dB are integers; kHz and kbps are integers; seconds, milliseconds, lux and m/s² are floats.

## ⚠️ Changed meaning: `cellularInfo.rssi`

Earlier app versions put a different measure in `rssi` on LTE and 3G. From this version:

| Technology | Old `rssi` value | New `rssi` value |
|---|---|---|
| GSM (2G) | RSSI | RSSI (unchanged) |
| WCDMA (3G) | RSCP | `null`. RSCP is now in the new `rscp` key |
| LTE (4G) | RSRP (duplicated in `rsrp`) | Real RSSI on Android 10+, `null` on older Android |
| NR (5G) | `null` | `null` (unchanged) |

Rows stored before this release can't be told apart by any field. If historical LTE/3G `rssi` values matter, separate them by received time (before this release's rollout), or treat LTE `rssi` equal to `rsrp` as the old meaning.

---

## 0. `userReportedEnvironment` (removed)

Builds of the demo app before the SDK was extracted asked the user "indoors or outdoors?" after each run and sent the answer as a top-level `userReportedEnvironment` string (`indoors`, `outdoors` or `null`) on both reports.

From SDK 0.1.0 the SDK no longer asks or sends it: asking is the host app's job. Reports from SDK builds omit the key. Keep the column nullable (or drop it) and expect it only in rows from those earlier demo builds. It no longer appears in the models below.

---

## 1. `POST /api/telemetry/location`

### 1.1 `cellularInfo`: new keys

| Key | Type | Unit | Values / notes |
|---|---|---|---|
| `technology` | string | | `gsm`, `wcdma`, `lte`, `nr`, `other` (serving cell) |
| `arfcn` | int | channel number | EARFCN (LTE), NR-ARFCN (5G), UARFCN (3G), ARFCN (2G). Android 7+ |
| `band` | int | 3GPP band number | e.g. `3` = LTE B3 (1800 MHz), `78` = n78. LTE/5G only, Android 11+ |
| `bandwidthKhz` | int | kHz | Serving channel bandwidth, e.g. `20000`. LTE only, Android 9+ |
| `rscp` | int | dBm | Received Signal Code Power. 3G only. Range about −120 to −25 |
| `csiRsrp` | int | dBm | 5G only. Range −140 to −44 |
| `csiRsrq` | int | dB | 5G only. Range −20 to −3 |
| `csiSinr` | int | dB | 5G only. Range −23 to 23 |
| `neighborCells` | array of objects | | Other cells the phone hears, max 16. `[]` when none. See 1.2 |

### 1.2 `cellularInfo.neighborCells[]`

Each item has the same keys and units as the serving cell, but usually only a few are filled. The network doesn't broadcast a neighbour's full cell ID, so `cellId` is normally `null`; neighbours are identified by `pci` + `arfcn`. Every key is present in each item, `null` when unknown.

| Key | Type | Unit |
|---|---|---|
| `technology` | string | `gsm`, `wcdma`, `lte`, `nr`, `other` |
| `cellId` | int (up to 36-bit) | |
| `pci` | int | LTE 0–503, 5G 0–1007, 3G scrambling code 0–511 |
| `arfcn` | int | channel number |
| `band` | int | 3GPP band |
| `rssi` | int | dBm |
| `rsrp` | int | dBm |
| `rsrq` | int | dB |
| `rscp` | int | dBm |
| `rssnr` | int | dB |
| `signalLevel` | int | 0–4 bars |

**Storage:** a child table (`location_report_id`, plus the columns above) is easiest to query. A JSONB column also works.

### 1.3 `connectivityInfo`: new keys

| Key | Type | Unit | Values / notes |
|---|---|---|---|
| `serviceState` | string | | `inService`, `outOfService`, `emergencyOnly`, `powerOff`. **The key field for no-coverage areas.** Reports taken without service are queued on the phone and arrive later |
| `overrideNetworkType` | string | | `none`, `lteCa`, `lteAdvancedPro`, `nrNsa`, `nrNsaMmwave`, `nrAdvanced`. Android 11+. 5G NSA reports `dataNetworkType: "lte"`, so this is the only way to see it. Can be null on the first reading after permission is granted |
| `aggregatedChannelCount` | int | count | Carrier aggregation: channels in use, primary included. Android 9+ |
| `aggregatedBandwidthKhz` | int | kHz | Sum of those channels' bandwidths |
| `isValidated` | bool | | OS confirmed internet access. **iOS too** (network path satisfied) |
| `isCaptivePortal` | bool | | Behind a login page |
| `isCongested` | bool | | Network reports itself congested. Android 9+ |
| `estimatedDownstreamKbps` | int | kbps | The OS's own bandwidth estimate, no test traffic |
| `estimatedUpstreamKbps` | int | kbps | Same, upload |
| `mtu` | int | bytes | Android 10+ |
| `hasIpv4` | bool | | Link has an IPv4 address. **iOS too** |
| `hasIpv6` | bool | | Link has a routable IPv6 address. **iOS too** |
| `isPrivateDnsActive` | bool | | DNS-over-TLS in use. Android 9+ |
| `isLowDataMode` | bool | | Android data saver (7+) / iOS Low Data Mode (13+). **iOS too** |
| `activeSimCount` | int | count | |
| `dataSimSlot` | int | 0-based slot | SIM carrying mobile data. Android 7+ |
| `otherSimCarrierName` | string | | Dual-SIM phones: operator of the SIM not carrying data |
| `otherSimMcc` | string | | e.g. `"434"` |
| `otherSimMnc` | string | | e.g. `"05"`. Keep as string: leading zeros matter |

On iOS, the existing `isMetered` key is now also filled (from "expensive network").

### 1.4 `deviceContext`: new keys

| Key | Type | Values / notes |
|---|---|---|
| `isPowerSaveMode` | bool | Battery saver (Android) / Low Power Mode (iOS). Throttles the modem. **iOS too** |
| `thermalStatus` | string | `none`, `light`, `moderate`, `severe`, `critical`, `emergency`, `shutdown`. Android 10+. **iOS too**, mapped as nominal → `none`, fair → `light`, serious → `severe`, critical → `critical` |

### 1.5 `gnssInfo`: new object (indoor/outdoor hint)

The app runs GPS for about 6 seconds per reading and records satellite visibility. Android only; iOS sends `status: "unsupported"`.

| Key | Type | Unit | Values / notes |
|---|---|---|---|
| `status` | string | | `ok`, `noData`, `permissionDenied`, `gpsDisabled`, `unsupported` |
| `satellitesUsed` | int | count | Most satellites used in a fix during the window. Can be 0 outdoors while GPS starts |
| `satellitesVisible` | int | count | Most satellites with a measurable signal |
| `topCn0DbHz` | float | dB-Hz | Mean signal of the 4 strongest satellites (best in window). Open sky ~35–45, indoors < 25 |
| `sampleSeconds` | float | s | |
| `timestamp` | string | ISO 8601 | |

The app shows this rule on screen. It sends no label, so the server can apply the same rule or tune it:

| Label | Rule |
|---|---|
| indoors | `status = noData`, or `satellitesVisible ≤ 3`, or `topCn0DbHz < 25` |
| outdoors | `satellitesVisible ≥ 6` and `topCn0DbHz ≥ 33` |
| in between | any other `status = ok` |
| unknown | `permissionDenied`, `gpsDisabled`, `unsupported` |

### 1.6 `environmentInfo`: new object (sensors)

Sampled over the same ~6 s window as `gnssInfo`. iOS sends only `accelStdDevMps2` and `sampleSeconds`.

| Key | Type | Unit | Notes |
|---|---|---|---|
| `ambientLux` | float | lux | Brightest light in the window. Daylight outdoors > 1,000; indoors 100–500. Android only |
| `accelStdDevMps2` | float | m/s² | Spread of acceleration. Still ≲ 0.3; walking > 1. **iOS too** |
| `wifiNetworksVisible` | int | count | Wi-Fi networks in the phone's last scan (≤ 2 min old). Counts only; no names or IDs are collected. Android only |
| `wifiStrongestRssiDbm` | int | dBm | Strongest of those |
| `sampleSeconds` | float | s | |
| `timestamp` | string | ISO 8601 | |

Suggested motion label: `inVehicle` if `locationInfo.speedMps ≥ 7`; otherwise `still` if `accelStdDevMps2 ≤ 0.3`, else `moving`.

### 1.7 `radioStats`: new object (between readings)

What the radio did since the previous reading. The app counts this only while it is running, so the window starts at the previous reading or at app start. Android only.

| Key | Type | Unit | Notes |
|---|---|---|---|
| `windowSeconds` | float | s | Length of the window |
| `handoverCount` | int | count | Serving-cell changes. Null without precise location permission |
| `secondsOn2g` | float | s | |
| `secondsOn3g` | float | s | |
| `secondsOn4g` | float | s | |
| `secondsOn5g` | float | s | 5G NSA counts here, not as 4G |
| `secondsOutOfService` | float | s | Out of service or emergency-only |
| `timestamp` | string | ISO 8601 | |

The `secondsOn*` buckets can sum to less than `windowSeconds`: time on Wi-Fi without mobile data, or before the first radio event, falls in no bucket.

---

## 2. `POST /api/telemetry/speedtest`

| Key | Type | Unit | Notes |
|---|---|---|---|
| `packetLossPercent` | float | % (0–100) | **Already in the API, now filled.** Share of the latency probes (HTTP `GET /speedtest/ping`, 11 by default) that failed or timed out. HTTP-level, not ICMP |
| `ttfbMs` | float | ms | **Already in the API, now filled.** Mean time to first byte over the download requests, including connection setup on each connection's first request. Null if the download test didn't run |
| `downloadBytes` | int | bytes | **New.** Bytes the download test transferred, including warmup |
| `uploadBytes` | int | bytes | **New.** Bytes uploaded and acknowledged |

**Note:** `GET /speedtest/ping` still returns 404 from nginx on `dev.uzproger.ru`. A 404 still arrives as a response, so it doesn't count as packet loss, but the latency figure then measures nginx rather than the app. The nginx config needs to forward `/speedtest/` to the app.

---

## 3. Example payload (location, abbreviated)

```json
{
  "sessionId": "8f1c…",
  "eventId": "2b7e…",
  "timestamp": "2026-10-14T09:15:00.000Z",
  "cellularInfo": {
    "technology": "lte", "rssi": -71, "rsrp": -98, "rsrq": -11, "rssnr": 8,
    "cellId": 25601793, "pci": 214, "tac": 1201,
    "arfcn": 1300, "band": 3, "bandwidthKhz": 20000,
    "rscp": null, "csiRsrp": null, "csiRsrq": null, "csiSinr": null,
    "neighborCells": [
      { "technology": "lte", "cellId": null, "pci": 101, "arfcn": 1300, "band": 3,
        "rssi": null, "rsrp": -106, "rsrq": -14, "rscp": null, "rssnr": null, "signalLevel": 2 },
      { "technology": "lte", "cellId": null, "pci": 388, "arfcn": 6300, "band": 20,
        "rssi": null, "rsrp": -112, "rsrq": null, "rscp": null, "rssnr": null, "signalLevel": 1 }
    ],
    "timestamp": "2026-10-14T09:15:00.000Z"
  },
  "connectivityInfo": {
    "connectionType": "cellular", "dataNetworkType": "lte",
    "serviceState": "inService", "overrideNetworkType": "nrNsa",
    "aggregatedChannelCount": 2, "aggregatedBandwidthKhz": 35000,
    "isValidated": true, "isCaptivePortal": false, "isCongested": false,
    "estimatedDownstreamKbps": 48000, "estimatedUpstreamKbps": 9000,
    "mtu": 1500, "hasIpv4": true, "hasIpv6": true,
    "isPrivateDnsActive": false, "isLowDataMode": false,
    "activeSimCount": 2, "dataSimSlot": 0,
    "otherSimCarrierName": "Ucell", "otherSimMcc": "434", "otherSimMnc": "05",
    "timestamp": "2026-10-14T09:15:00.000Z"
  },
  "deviceContext": {
    "isPowerSaveMode": false, "thermalStatus": "none",
    "timestamp": "2026-10-14T09:15:00.000Z"
  },
  "gnssInfo": {
    "status": "ok", "satellitesUsed": 7, "satellitesVisible": 11,
    "topCn0DbHz": 38.5, "sampleSeconds": 6.0,
    "timestamp": "2026-10-14T09:15:00.000Z"
  },
  "environmentInfo": {
    "ambientLux": 14200.0, "accelStdDevMps2": 1.42,
    "wifiNetworksVisible": 3, "wifiStrongestRssiDbm": -79,
    "sampleSeconds": 6.0, "timestamp": "2026-10-14T09:15:00.000Z"
  },
  "radioStats": {
    "windowSeconds": 412.0, "handoverCount": 3,
    "secondsOn2g": 0.0, "secondsOn3g": 0.0, "secondsOn4g": 305.2, "secondsOn5g": 96.8,
    "secondsOutOfService": 10.0, "timestamp": "2026-10-14T09:15:00.000Z"
  }
}
```

Existing keys (`locationInfo`, the other `cellularInfo` / `connectivityInfo` / `deviceContext` fields) are unchanged and left out above for brevity. They are documented in `docs/data-fields.md`.

---

## 4. Pydantic models

These follow the naming of the current API schema (`LocationReportIn`, `CellularInfoIn`, …). Existing fields are shown as `...`; add the new ones. All new fields are `Optional` with default `None`.

```python
from datetime import datetime
from typing import Optional
from pydantic import BaseModel


class NeighborCellIn(BaseModel):
    technology: Optional[str] = None
    cellId: Optional[int] = None
    pci: Optional[int] = None
    arfcn: Optional[int] = None
    band: Optional[int] = None
    rssi: Optional[int] = None
    rsrp: Optional[int] = None
    rsrq: Optional[int] = None
    rscp: Optional[int] = None
    rssnr: Optional[int] = None
    signalLevel: Optional[int] = None


class CellularInfoIn(BaseModel):
    ...  # existing fields
    technology: Optional[str] = None
    arfcn: Optional[int] = None
    band: Optional[int] = None
    bandwidthKhz: Optional[int] = None
    rscp: Optional[int] = None
    csiRsrp: Optional[int] = None
    csiRsrq: Optional[int] = None
    csiSinr: Optional[int] = None
    neighborCells: list[NeighborCellIn] = []


class ConnectivityInfoIn(BaseModel):
    ...  # existing fields
    serviceState: Optional[str] = None
    overrideNetworkType: Optional[str] = None
    aggregatedChannelCount: Optional[int] = None
    aggregatedBandwidthKhz: Optional[int] = None
    isValidated: Optional[bool] = None
    isCaptivePortal: Optional[bool] = None
    isCongested: Optional[bool] = None
    estimatedDownstreamKbps: Optional[int] = None
    estimatedUpstreamKbps: Optional[int] = None
    mtu: Optional[int] = None
    hasIpv4: Optional[bool] = None
    hasIpv6: Optional[bool] = None
    isPrivateDnsActive: Optional[bool] = None
    isLowDataMode: Optional[bool] = None
    activeSimCount: Optional[int] = None
    dataSimSlot: Optional[int] = None
    otherSimCarrierName: Optional[str] = None
    otherSimMcc: Optional[str] = None
    otherSimMnc: Optional[str] = None


class DeviceContextIn(BaseModel):
    ...  # existing fields
    isPowerSaveMode: Optional[bool] = None
    thermalStatus: Optional[str] = None


class GnssInfoIn(BaseModel):
    status: Optional[str] = None
    satellitesUsed: Optional[int] = None
    satellitesVisible: Optional[int] = None
    topCn0DbHz: Optional[float] = None
    sampleSeconds: Optional[float] = None
    timestamp: Optional[datetime] = None


class EnvironmentInfoIn(BaseModel):
    ambientLux: Optional[float] = None
    accelStdDevMps2: Optional[float] = None
    wifiNetworksVisible: Optional[int] = None
    wifiStrongestRssiDbm: Optional[int] = None
    sampleSeconds: Optional[float] = None
    timestamp: Optional[datetime] = None


class RadioStatsIn(BaseModel):
    windowSeconds: Optional[float] = None
    handoverCount: Optional[int] = None
    secondsOn2g: Optional[float] = None
    secondsOn3g: Optional[float] = None
    secondsOn4g: Optional[float] = None
    secondsOn5g: Optional[float] = None
    secondsOutOfService: Optional[float] = None
    timestamp: Optional[datetime] = None


class LocationReportIn(BaseModel):
    ...  # existing fields
    gnssInfo: Optional[GnssInfoIn] = None
    environmentInfo: Optional[EnvironmentInfoIn] = None
    radioStats: Optional[RadioStatsIn] = None


class SpeedtestReportIn(BaseModel):
    ...  # existing fields (packetLossPercent and ttfbMs already exist)
    downloadBytes: Optional[int] = None
    uploadBytes: Optional[int] = None
```

`cellId` can exceed 32 bits on 5G (NCI is 36-bit), so use `BIGINT` for it in the serving cell and in neighbours.

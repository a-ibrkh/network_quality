# Network Quality SDK — Backend API Spec

What the mobile SDK needs from the backend. Payload shapes below are
generated from the client's actual serialization code, so they match the
wire format exactly.

Base URL `https://dev.uzproger.ru`. All JSON is `Content-Type: application/json; charset=utf-8`.

> ⚠️ **This document predates the backend and has been overtaken by it.**
> The live API at `https://dev.uzproger.ru` uses different paths than
> the ones proposed below, and the client has been built against the live
> ones. Treat the payload tables as accurate (they match the wire format)
> and the *paths* in §1/§2/§5 as historical.
>
> | Proposed here | Actually live | Client uses |
> |---|---|---|
> | `POST /v1/snapshots` | `POST /api/telemetry/location` | ✅ |
> | `POST /v1/test-results` | `POST /api/telemetry/speedtest` | ✅ |
> | `GET /v1/speedtest/ping` | `GET /speedtest/ping` (204) | ✅ |
> | `GET /v1/speedtest/download` \| `upload` | not built - Cloudflare used instead | n/a |
> | `GET /v1/config` | dropped | n/a |
>
> **Status:** everything the client needs from the backend exists, but
> nginx on `dev.uzproger.ru` does not route `/speedtest/ping` (404, while
> `/api/*` and `/health` work). See the gaps below.

**Known gaps against the live server**

- **No auth.** `POST` succeeds with no credentials, so the coverage
  dataset is publicly writable. Accepted for the hackathon; not for
  production.
- **`/speedtest/ping` is not proxied.** The app's OpenAPI schema lists
  `GET /speedtest/ping`, but nginx answers it with its own 404, so the
  client's latency measurement fails. nginx needs a `location` for
  `/speedtest/` (or `/`) pointing at the app.
- **No idempotency key honoured.** The client now has a retry queue and
  sends a `eventId` (uuid v4) in every payload, unchanged across retries.
  The server ignores it and assigns its own row id, so a send that times
  out *after* the server committed will duplicate. Honouring `eventId` is
  a server-side change only - no client release needed.
- **`packetLossPercent` and `ttfbMs` are still modelled server-side** but
  the client no longer sends either - both columns will always be null.
  Harmless; drop them whenever convenient.
- **The server is intermittent.** It has been unreachable twice during
  development, including on port 80 earlier. Worth a look before demoing.

---

## Conventions

- **Timestamps** — ISO-8601 UTC with milliseconds, e.g.
  `2026-07-31T09:42:50.123Z`. Produced by Dart's `toIso8601String()`.
- **Nullability** — every field marked *nullable* is genuinely absent in
  normal operation, not an error. A metric is null when the platform can't
  supply it (iOS exposes no signal strength at all; Android LTE devices
  below API 26 have no RSRP/RSRQ/CQI). **Do not reject a payload for null
  metrics and do not coerce them to 0** — null and 0 dBm mean very
  different things.
- **Enums** — sent as strings, exact values listed per field. Treat an
  unrecognised value as unknown rather than failing the request; new radio
  types get added over time.
- **`sessionId`** — UUID v4 generated per SDK instance. Correlates a
  snapshot with the active measurements taken alongside it. Not a user ID
  and not unique per request.
- **Auth** — assume a static API key header (`X-API-Key`) unless you'd
  rather do something else; the client has no auth wired up yet, so this is
  your call.

---

## Privacy — affects schema, not just policy

`locationInfo` makes these payloads **personal data**. Combined with
`carrierName`, `deviceModel` and a stable `sessionId`, a location trail is
straightforwardly re-identifiable. Worth settling before the schema is
written rather than after:

- **Retention.** Decide a TTL for raw coordinates now and enforce it in
  the database. Coverage analysis usually only needs aggregates
  (per-cell, per-tile averages) after a short window, so raw points can
  expire while the aggregates live on.
- **Deletion path.** There must be a way to delete a user's data on
  request. That needs an identifier to delete *by* — `sessionId` is
  per-SDK-instance and won't survive an app restart, so if deletion by
  user is required, we need to agree on a stable pseudonymous device id.
  Flagging it now because retrofitting one is painful.
- **Precision.** For coverage mapping, full GPS precision is rarely
  needed. Truncating to ~4 decimal places (≈11 m) or snapping to a geohash
  tile server-side on ingest sharply reduces exposure at almost no
  analytical cost. Say the word and the client can round before sending
  instead.
- **Store declarations.** Both stores need this declared — Play Data
  Safety and Apple's privacy nutrition labels — and the app needs a
  privacy policy covering location. That's app-side, but the backend's
  retention answer feeds directly into what we declare.
- **Transport.** These payloads must go over HTTPS. That's independent of
  the speedtest endpoints, where cleartext is merely inconvenient; here
  it's a hard requirement.

Note the client only collects `whenInUse` location — no background
tracking. Measurements happen while the user has the app open.

---

## 1. `POST /v1/snapshots`

Passive device/network state. Small, frequent.

### Body

| Key | Type | Null? | Notes |
|---|---|---|---|
| `sessionId` | string (uuid) | no | |
| `timestamp` | string (iso8601) | no | |
| `connectivityInfo` | object | no | see 1a |
| `cellularInfo` | object | **yes** | null on Wi-Fi, or where unavailable |
| `deviceContext` | object | no | see 1c |
| `locationInfo` | object | no | see 1d — object always present, coordinates may be null |

### 1a. `connectivityInfo`

| Key | Type | Null? | Values / notes |
|---|---|---|---|
| `connectionType` | string | no | `wifi` \| `cellular` \| `ethernet` \| `none` |
| `isVpnActive` | bool | yes | |
| `isMetered` | bool | yes | |
| `isAirplaneModeOn` | bool | yes | |
| `isDataRoaming` | bool | yes | |
| `carrierName` | string | yes | free text from the OS, not normalised |
| `mcc` | string | yes | 3 digits, **string not int** — leading zeros are significant |
| `mnc` | string | yes | 2–3 digits, same reason |
| `cellularGeneration` | string | yes | `g2` \| `g3` \| `g4` \| `g5` \| `unknown` |
| `dataNetworkType` | string | yes | `gprs` `edge` `umts` `hsdpa` `hsupa` `hspa` `hspap` `cdma` `evdo0` `evdoA` `evdoB` `ehrpd` `lte` `lteCa` `nr` `gsm` `tdScdma` `iwlan` `unknown` |
| `timestamp` | string (iso8601) | no | |

All fields except `connectionType`/`timestamp` are **null on iOS** — no
public API.

### 1b. `cellularInfo`

Android only (except `radioAccessTechnology`). Every numeric field is null
on iOS — platform limitation, not a client bug.

| Key | Type | Null? | Unit | Typical range |
|---|---|---|---|---|
| `rssi` | int | yes | dBm | −113 … −51 |
| `rsrp` | int | yes | dBm | −140 … −44 |
| `rsrq` | int | yes | dB | −20 … −3 |
| `rssnr` | int | yes | dB | −20 … 30 (SINR) |
| `cqi` | int | yes | index | 0 … 15 |
| `asuLevel` | int | yes | index | 0 … 97 |
| `signalLevel` | int | yes | bars | 0 … 4 |
| `cellId` | **int64** | yes | — | see warning below |
| `pci` | int | yes | — | 0 … 1007 |
| `lac` | int | yes | — | 0 … 65535 (2G/3G only) |
| `tac` | int | yes | — | 0 … 16777215 (LTE/NR only) |
| `timingAdvance` | int | yes | — | 0 … 1282 |
| `isRegistered` | bool | yes | — | |
| `radioAccessTechnology` | string | yes | — | **iOS only**, free text e.g. `LTE`, `5G NR` |
| `timestamp` | string (iso8601) | no | | |

> ⚠️ **`cellId` must be a 64-bit integer column.** On 5G NR this carries the
> NCI, which is 36 bits (up to ~68.7 billion). An `INT`/`int32` column will
> overflow. LTE CI is 28 bits and fits, but NR does not.

Note `lac` and `tac` are mutually exclusive in practice — `lac` for 2G/3G,
`tac` for LTE/NR — so expect one of the two to be null on every row.

### 1c. `deviceContext`

| Key | Type | Null? | Notes |
|---|---|---|---|
| `batteryLevel` | int | yes | 0–100 (percent) |
| `isCharging` | bool | yes | |
| `deviceModel` | string | yes | e.g. `Pixel 7`, `iPhone14,5` (iOS sends the machine id) |
| `osVersion` | string | yes | e.g. `Android 14`, `iOS 17.4` |
| `isAppInForeground` | bool | **no** | |
| `timestamp` | string (iso8601) | no | |

### 1d. `locationInfo`

Where the device was, so radio metrics can be mapped geographically. The
object is **always present**; when there's no fix it carries `status`
explaining why and null coordinates.

| Key | Type | Null? | Unit | Notes |
|---|---|---|---|---|
| `status` | string | no | | `available` \| `permissionDenied` \| `permissionPermanentlyDenied` \| `servicesDisabled` \| `unavailable` \| `notCollected` |
| `latitude` | double | yes | degrees | WGS-84, −90 … 90 |
| `longitude` | double | yes | degrees | WGS-84, −180 … 180 |
| `accuracyMeters` | double | yes | m | horizontal accuracy radius — **see below** |
| `altitudeMeters` | double | yes | m | |
| `speedMps` | double | yes | m/s | ground speed |
| `headingDegrees` | double | yes | deg | clockwise from true north, 0 … 360 |
| `isMocked` | bool | yes | | **see below** |
| `fixTimestamp` | string (iso8601) | yes | | when the fix was taken |
| `timestamp` | string (iso8601) | no | | when the record was assembled |

Every coordinate field is null unless `status == "available"`.

Three things that matter for analysis:

- **`accuracyMeters` is not decoration — filter on it.** Android 12+ lets
  users grant *approximate* location only, which typically yields a
  1–3 km radius. Those points are real but useless for per-cell mapping,
  and indistinguishable from a GPS fix except by this field. Suggest
  treating anything above ~100 m as coarse.
- **`isMocked` should exclude the row from coverage maps.** Android
  reports whether the fix came from a mock provider. Spoofed GPS would
  place real signal readings at fake coordinates, which is worse than
  having no reading there at all.
- **`fixTimestamp` is usually older than `timestamp`.** By default the
  client uses the OS's cached last-known position to keep collection fast,
  so a fix can be minutes old. Compute the delta and discard points that
  are too stale for your purposes — a fix from 10 minutes ago on a moving
  device is a different place entirely.

### Example (real client output)

```json
{
  "sessionId": "6f1c2e94-1b7a-4d2e-9c33-0a5e8b7d4f21",
  "timestamp": "2026-07-31T09:42:50.123Z",
  "locationInfo": {
    "status": "available",
    "latitude": 41.311081,
    "longitude": 69.240562,
    "accuracyMeters": 12.5,
    "altitudeMeters": 455.0,
    "speedMps": 1.4,
    "headingDegrees": 275.0,
    "isMocked": false,
    "fixTimestamp": "2026-07-31T09:42:20.000Z",
    "timestamp": "2026-07-31T09:42:50.123Z"
  },
  "connectivityInfo": {
    "connectionType": "cellular",
    "isVpnActive": false,
    "isMetered": true,
    "isAirplaneModeOn": false,
    "isDataRoaming": false,
    "carrierName": "Ucell",
    "mcc": "434",
    "mnc": "05",
    "cellularGeneration": "g4",
    "dataNetworkType": "lte",
    "timestamp": "2026-07-31T09:42:50.123Z"
  },
  "cellularInfo": {
    "rssi": -71,
    "rsrp": -95,
    "rsrq": -11,
    "rssnr": 12,
    "cqi": 9,
    "asuLevel": 45,
    "signalLevel": 3,
    "cellId": 12345678,
    "pci": 273,
    "lac": null,
    "tac": 4201,
    "timingAdvance": 5,
    "isRegistered": true,
    "radioAccessTechnology": null,
    "timestamp": "2026-07-31T09:42:50.123Z"
  },
  "deviceContext": {
    "batteryLevel": 77,
    "isCharging": false,
    "deviceModel": "Pixel 7",
    "osVersion": "Android 14",
    "isAppInForeground": true,
    "timestamp": "2026-07-31T09:42:50.123Z"
  }
}
```

### Response

`202 Accepted` (or `200`) with an empty body is fine. The client only needs
to know it was durably stored — see *Idempotency* below.

---

## 2. `POST /v1/test-results`

Results of an active measurement run.

| Key | Type | Null? | Unit | Notes |
|---|---|---|---|---|
| `sessionId` | string (uuid) | no | | matches a snapshot |
| `timestamp` | string (iso8601) | no | | |
| `connectionType` | string | no | | `wifi` \| `cellular` \| `ethernet` \| `none` — what the device was on |
| `skipReason` | string | yes | | `notCellular` \| `recentlyMeasured`, or null when the test actually ran |
| `downloadMbps` | double | yes | Mbps | **implemented** (Cloudflare) |
| `uploadMbps` | double | yes | Mbps | **implemented** (Cloudflare) |
| `latencyMs` | double | yes | ms | null until §5 exists |
| `jitterMs` | double | yes | ms | derived from latency samples |
| `dnsResolutionMs` | double | yes | ms | **implemented** |
| `tcpConnectionMs` | double | yes | ms | **implemented** |
| `tlsHandshakeMs` | double | yes | ms | **implemented** |

All numeric fields are floating point — don't type them as integers.

Most fields are null today and will stay null until the corresponding
endpoint below is built, so **the schema must tolerate a mostly-null row.**

### Cellular-only measurement — read this before analysing

**The client only measures on cellular.** This SDK characterises the
cellular network, so a throughput or latency figure taken over Wi-Fi
describes a different link and would corrupt the dataset.

When the device is not on cellular the client still posts a record, with
every metric null and `skipReason: "notCellular"`. That distinction
matters on your side:

- `skipReason != null` → **we never measured.** Exclude from all quality
  aggregates. These rows are not zero-throughput events and must not drag
  averages down.
- `skipReason == null` with null metrics → we *did* measure and that metric
  genuinely failed or isn't implemented yet.

`connectionType` is recorded on every row either way, so you can see what
the device was on. A useful sanity check: any row with
`skipReason == null` should have `connectionType == "cellular"`.

### Example — measured (real client output)

```json
{
  "sessionId": "6f1c2e94-1b7a-4d2e-9c33-0a5e8b7d4f21",
  "timestamp": "2026-07-31T09:42:50.123Z",
  "connectionType": "cellular",
  "skipReason": null,
  "downloadMbps": 32.43,
  "uploadMbps": null,
  "latencyMs": null,
  "jitterMs": null,
  "dnsResolutionMs": 23.5,
  "tcpConnectionMs": 41.25,
  "tlsHandshakeMs": 88.0,
}
```

### Example — skipped because not on cellular (real client output)

```json
{
  "sessionId": "6f1c2e94-1b7a-4d2e-9c33-0a5e8b7d4f21",
  "timestamp": "2026-07-31T09:42:50.123Z",
  "connectionType": "wifi",
  "skipReason": "notCellular",
  "downloadMbps": null,
  "uploadMbps": null,
  "latencyMs": null,
  "jitterMs": null,
  "dnsResolutionMs": null,
  "tcpConnectionMs": null,
  "tlsHandshakeMs": null,
}
```

### Measurement cadence

Measurements run **once when the user opens the host app** — there is no
background collection. On top of that the client enforces a **12-hour
cooldown**, persisted across app restarts: reopening the app inside that
window yields `skipReason: "recentlyMeasured"` instead of a new
measurement.

Two consequences for you:

- **Expect at most 2 measurements per device per day**, and fewer in
  practice — a device only measures if the app is opened after the window
  expires. Volume estimates should be based on that, not on app opens.
  Snapshots (§1) are not throttled and will arrive more often.
- **`recentlyMeasured` rows carry no network information at all.** They're
  a client-side throttle artifact. The client will most likely not send
  them; if any do arrive, drop them rather than storing them. Unlike
  `notCellular` — which is genuinely informative, since it tells you how
  much of your user base is on Wi-Fi — these say nothing.

`skipReason` is an open enum — more reasons (metered connection, low
battery) are plausible later, so treat an unrecognised value as
"skipped for some reason" rather than rejecting the row.

---

## Idempotency and batching (applies to §1 and §2)

This SDK measures **bad connections**, so a send timing out after the
server already committed it is the normal case, not an edge case. The
client will retry from a local queue.

Two requirements:

1. **Accept a client-generated idempotency key** — either an
   `Idempotency-Key` header or an `eventId` field per record (say which you
   prefer and the client will send it). `sessionId` is *not* unique per
   record and can't serve this purpose. Without it you will get duplicate
   rows.
2. **Provide batch variants** — `POST /v1/snapshots/batch` and
   `POST /v1/test-results/batch`, each taking `{"items": [ ... ]}` with the
   same object shape. A device that was offline flushes a backlog in one
   request instead of N.

For batches, please return per-item results so a single bad record doesn't
force the client to re-send the whole batch:

```json
{ "results": [ { "eventId": "...", "status": "stored" },
               { "eventId": "...", "status": "duplicate" },
               { "eventId": "...", "status": "rejected", "reason": "..." } ] }
```

Suggested limits: 100 items or 1 MB per batch — tell us the real numbers
and the client will chunk to fit.

---

## 3 & 4. Download / upload endpoints — *no longer required*

**The client now measures both directions against Cloudflare's public
speed-test origin** (`speed.cloudflare.com/__down` and `__up`), so no
first-party throughput endpoints are needed. Nothing to build here.

Kept for reference in case first-party measurement is wanted later —
Cloudflare peers with and often caches inside carrier networks, so
throughput to it reads near best-case rather than representative:

- `GET /v1/speedtest/download?bytes=N` — exactly N **incompressible**
  bytes, `Content-Length` set, no `Content-Encoding: gzip` (compression
  inflates apparent throughput), `Cache-Control: no-store`, `Range`
  supported.
- `POST /v1/speedtest/upload` — accepts an arbitrary body and discards it,
  but **must read to EOF before responding**. Replying early measures the
  client's local socket buffer instead of the network and reports wildly
  inflated speeds. This is the single easiest thing to get wrong.

---

## 5. `GET /v1/speedtest/ping`

Latency/RTT — and therefore jitter, which is derived from a series of these.

- `204 No Content`, or a handful of bytes.
- No auth, no DB, no logging on the hot path — anything that adds server
  time is indistinguishable from network latency.
- `Cache-Control: no-store`.
- Optionally echo back a client-supplied `?t=<millis>` so we can estimate
  one-way delay.

The client will call this ~10–20 times per run.

---

## Infrastructure note

If first-party speedtest endpoints are ever built (§3–§5), put them on an **origin you control in a
known region, not behind a general-purpose CDN**. A CDN edge measures the
edge, not the carrier link, which defeats the purpose of the SDK.

## 0.1.0

First release as a standalone package, extracted from the `network_checker`
demo app.

* Android and iOS native code moved into the plugin (`NetworkQualityPlugin`).
  Host apps no longer touch `MainActivity` or `AppDelegate`; Android
  permissions merge in from the plugin manifest.
* `NetworkQualityConfig.baseUrl` is now required - the SDK has no default
  backend. New `headers` option is sent with every request to the backend.
* `NetworkQualityService` takes only `config`, `sessionId` and optional
  storage overrides. Collector injection moved to the test-only
  `NetworkQualityService.withDependencies`.
* New `NetworkQualityService.openAppSettings()`.
* Removed `userReportedEnvironment` and `UserEnvironment`: asking the user
  indoors/outdoors is the host app's job. The example app still asks.
* Public API narrowed to `package:network_quality/network_quality.dart`;
  collectors, queue and sender are internal (`lib/src/`).
* iOS: privacy manifest added; minimum iOS 13.

import 'package:flutter/foundation.dart';

/// Console logging for the module's HTTP traffic.
///
/// Debug builds only: telemetry bodies carry location, which is personal
/// data, and must not end up in a release build's device log.
///
/// `debugPrint` rather than `dart:developer`'s `log`, so lines show up in
/// the `flutter run` console and in logcat, not just in DevTools.
void logHttp(String message) {
  if (kDebugMode) debugPrint('[network_quality] $message');
}

/// Shortens [body] for logging so one response can't flood the console.
String truncateForLog(String body, [int max = 1000]) =>
    body.length > max ? '${body.substring(0, max)}... (${body.length} chars)' : body;

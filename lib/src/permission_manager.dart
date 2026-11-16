import 'dart:io';

import 'package:flutter/services.dart';

import 'models/permission_state.dart';

/// Requests and inspects the OS permissions the module needs.
///
/// Implemented against a native MethodChannel rather than a permissions
/// plugin: the only permissions involved are Android's, so a cross-platform
/// plugin would pull iOS permission APIs this module never uses (which Apple
/// may ask about at review time) and add a dependency that consumers of the
/// extracted SDK would inherit.
///
/// On every platform other than Android this is a no-op returning
/// [PermissionStatuses.notRequired] - notably it does *not* prompt for
/// location on iOS, since nothing this module collects there needs it.
class PermissionManager {
  static const MethodChannel _channel = MethodChannel('network_quality/permissions');

  const PermissionManager();

  /// Reports current permission state without prompting the user.
  ///
  /// Cannot distinguish [PermissionState.denied] from
  /// [PermissionState.permanentlyDenied]: Android only exposes that
  /// difference via `shouldShowRequestPermissionRationale`, which is
  /// meaningless until at least one request has been made. A
  /// not-yet-granted permission is therefore reported as `denied` here;
  /// [request] returns the accurate distinction.
  Future<PermissionStatuses> check() => _invoke('checkPermissions');

  /// Prompts for any missing permission and reports the outcome.
  ///
  /// Returns immediately without prompting if everything is already
  /// granted. Throws a [PlatformException] with code `already_requesting`
  /// if a request is already in flight, or `no_activity` if the Android
  /// activity isn't available to host the dialog - both indicate a caller
  /// bug rather than a user decision, so they surface instead of being
  /// folded into a "denied" result.
  Future<PermissionStatuses> request() => _invoke('requestPermissions');

  /// Opens the app's system settings page, the only remaining route once a
  /// permission is [PermissionState.permanentlyDenied]. Returns whether the
  /// settings screen was successfully launched.
  Future<bool> openAppSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openAppSettings') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<PermissionStatuses> _invoke(String method) async {
    if (!Platform.isAndroid) return const PermissionStatuses.notRequired();
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(method);
      if (result == null) return const PermissionStatuses.notRequired();
      return PermissionStatuses.fromJson(result);
    } on MissingPluginException {
      // Native handler not registered (e.g. the module was copied into a
      // host app that hasn't wired up MainActivity yet).
      return const PermissionStatuses.notRequired();
    }
  }
}

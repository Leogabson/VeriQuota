import 'dart:async';
import 'package:flutter/services.dart';
import 'models/alert_threshold_config.dart';
import 'models/app_usage_entry.dart';

/// Clean Dart-side platform channel client for Android VpnService data monitoring.
/// Encapsulates all MethodChannel and EventChannel communication.
class VpnNativeService {
  static const MethodChannel _methodChannel =
      MethodChannel('com.veriquota.app/vpn_control');

  static const EventChannel _eventChannel =
      EventChannel('com.veriquota.app/vpn_events');

  // Singleton instance
  static final VpnNativeService instance = VpnNativeService._internal();

  VpnNativeService._internal();

  factory VpnNativeService() => instance;

  Stream<List<AppUsageEntry>>? _usageStream;

  /// Starts VPN network monitoring.
  /// Launches system VPN consent dialog if required.
  /// Returns `true` if monitoring was started or consent granted, `false` otherwise.
  Future<bool> startVpnMonitoring() async {
    try {
      final bool? success =
          await _methodChannel.invokeMethod<bool>('startVpnMonitoring');
      return success ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  /// Stops VPN monitoring and shuts down the local tunnel.
  Future<bool> stopVpnMonitoring() async {
    try {
      final bool? success =
          await _methodChannel.invokeMethod<bool>('stopVpnMonitoring');
      return success ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  /// Checks whether the VPN service is actively running.
  Future<bool> isVpnRunning() async {
    try {
      final bool? active =
          await _methodChannel.invokeMethod<bool>('isVpnRunning');
      return active ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  /// Retrieves a point-in-time snapshot of cumulative data usage for all tracked apps.
  Future<List<AppUsageEntry>> getCurrentUsage() async {
    try {
      final List<dynamic>? rawList =
          await _methodChannel.invokeMethod<List<dynamic>>('getCurrentUsage');
      if (rawList == null) return [];

      return rawList
          .whereType<Map<dynamic, dynamic>>()
          .map((item) => AppUsageEntry.fromMap(item))
          .toList();
    } on PlatformException catch (_) {
      return [];
    }
  }

  /// Retrieves data usage within a specific time window for a single app or all apps.
  Future<List<AppUsageEntry>> getTimeRangeUsage({
    String? packageName,
    required DateTime start,
    required DateTime end,
  }) async {
    try {
      final result = await _methodChannel.invokeMethod('getTimeRangeUsage', {
        'packageName': packageName,
        'startMillis': start.millisecondsSinceEpoch,
        'endMillis': end.millisecondsSinceEpoch,
      });

      if (result is List) {
        return result
            .whereType<Map<dynamic, dynamic>>()
            .map((item) => AppUsageEntry.fromMap(item))
            .toList();
      } else if (result is Map) {
        return [AppUsageEntry.fromMap(result)];
      }
      return [];
    } on PlatformException catch (_) {
      return [];
    }
  }

  /// Broadcast stream emitting live data usage updates every 2 seconds while active.
  Stream<List<AppUsageEntry>> get usageStream {
    _usageStream ??= _eventChannel
        .receiveBroadcastStream()
        .map<List<AppUsageEntry>>((dynamic event) {
      if (event is List) {
        return event
            .whereType<Map<dynamic, dynamic>>()
            .map((item) => AppUsageEntry.fromMap(item))
            .toList();
      }
      return [];
    });
    return _usageStream!;
  }

  /// Updates native threshold alert configuration.
  Future<bool> setAlertThreshold({
    required bool enabled,
    required int thresholdBytes,
    required int windowMinutes,
  }) async {
    try {
      final bool? success =
          await _methodChannel.invokeMethod<bool>('setAlertThreshold', {
        'enabled': enabled,
        'thresholdBytes': thresholdBytes,
        'windowMinutes': windowMinutes,
      });
      return success ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  /// Retrieves current native threshold alert configuration.
  Future<AlertThresholdConfig> getAlertThreshold() async {
    try {
      final dynamic raw =
          await _methodChannel.invokeMethod<dynamic>('getAlertThreshold');
      if (raw is Map) {
        return AlertThresholdConfig.fromMap(raw);
      }
      return const AlertThresholdConfig(
        enabled: false,
        thresholdBytes: 50 * 1024 * 1024,
        windowMinutes: 15,
      );
    } on PlatformException catch (_) {
      return const AlertThresholdConfig(
        enabled: false,
        thresholdBytes: 50 * 1024 * 1024,
        windowMinutes: 15,
      );
    }
  }

  /// Requests POST_NOTIFICATIONS runtime permission on Android 13+ (API 33+).
  /// Returns `true` if granted, `false` if denied.
  Future<bool> requestNotificationPermission() async {
    try {
      final bool? granted = await _methodChannel
          .invokeMethod<bool>('requestNotificationPermission');
      return granted ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  /// Checks if notifications are currently enabled for VeriQuota.
  Future<bool> areNotificationsEnabled() async {
    try {
      final bool? enabled =
          await _methodChannel.invokeMethod<bool>('areNotificationsEnabled');
      return enabled ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }
}

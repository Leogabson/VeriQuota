/// Data model representing native threshold alert configuration.
class AlertThresholdConfig {
  final bool enabled;
  final int thresholdBytes;
  final int windowMinutes;

  const AlertThresholdConfig({
    required this.enabled,
    required this.thresholdBytes,
    required this.windowMinutes,
  });

  /// Returns threshold converted to whole Megabytes for UI display and editing.
  int get thresholdMb => (thresholdBytes / (1024 * 1024)).round();

  factory AlertThresholdConfig.fromMb({
    required bool enabled,
    required int thresholdMb,
    required int windowMinutes,
  }) {
    return AlertThresholdConfig(
      enabled: enabled,
      thresholdBytes: thresholdMb * 1024 * 1024,
      windowMinutes: windowMinutes,
    );
  }

  factory AlertThresholdConfig.fromMap(Map<dynamic, dynamic> map) {
    return AlertThresholdConfig(
      enabled: map['enabled'] as bool? ?? false,
      thresholdBytes:
          (map['thresholdBytes'] as num?)?.toInt() ?? (50 * 1024 * 1024),
      windowMinutes: (map['windowMinutes'] as num?)?.toInt() ?? 15,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'enabled': enabled,
      'thresholdBytes': thresholdBytes,
      'windowMinutes': windowMinutes,
    };
  }

  AlertThresholdConfig copyWith({
    bool? enabled,
    int? thresholdBytes,
    int? windowMinutes,
  }) {
    return AlertThresholdConfig(
      enabled: enabled ?? this.enabled,
      thresholdBytes: thresholdBytes ?? this.thresholdBytes,
      windowMinutes: windowMinutes ?? this.windowMinutes,
    );
  }

  @override
  String toString() =>
      'AlertThresholdConfig(enabled: $enabled, thresholdBytes: $thresholdBytes (${thresholdMb}MB), windowMinutes: $windowMinutes)';
}

import 'package:flutter_test/flutter_test.dart';
import 'package:veriquota/features/vpn_native/models/alert_threshold_config.dart';

void main() {
  group('AlertThresholdConfig Unit Tests', () {
    test('thresholdMb correctly computes MB from bytes', () {
      const config = AlertThresholdConfig(
        enabled: true,
        thresholdBytes: 52428800, // 50 MB
        windowMinutes: 15,
      );

      expect(config.thresholdMb, 50);
      expect(config.enabled, isTrue);
      expect(config.windowMinutes, 15);
    });

    test('fromMb factory constructs bytes accurately', () {
      final config = AlertThresholdConfig.fromMb(
        enabled: true,
        thresholdMb: 100,
        windowMinutes: 30,
      );

      expect(config.thresholdBytes, 104857600);
      expect(config.thresholdMb, 100);
      expect(config.windowMinutes, 30);
    });

    test('toMap and fromMap serialize and deserialize cleanly', () {
      final initial = AlertThresholdConfig.fromMb(
        enabled: true,
        thresholdMb: 25,
        windowMinutes: 10,
      );

      final map = initial.toMap();
      final restored = AlertThresholdConfig.fromMap(map);

      expect(restored.enabled, initial.enabled);
      expect(restored.thresholdBytes, initial.thresholdBytes);
      expect(restored.windowMinutes, initial.windowMinutes);
      expect(restored.thresholdMb, 25);
    });

    test('fromMap handles nulls and defaults gracefully', () {
      final empty = AlertThresholdConfig.fromMap({});

      expect(empty.enabled, isFalse);
      expect(empty.thresholdMb, 50);
      expect(empty.windowMinutes, 15);
    });
  });
}

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veriquota/app.dart';
import 'package:veriquota/data/repository/usage_repository.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.veriquota.app/vpn_control'),
      (MethodCall call) async {
        if (call.method == 'isVpnRunning') return false;
        if (call.method == 'getCurrentUsage') return [];
        return null;
      },
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.veriquota.app/vpn_events'),
      (MethodCall call) async {
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.veriquota.app/vpn_control'),
      null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.veriquota.app/vpn_events'),
      null,
    );
  });

  testWidgets('VeriQuota app launches into onboarding smoke test', (WidgetTester tester) async {
    final repository = UsageRepository(autoStart: false);

    await tester.pumpWidget(VeriQuotaApp(usageRepository: repository));
    await tester.pump();

    expect(find.text('VeriQuota'), findsOneWidget);
    expect(find.text('Grant Permission & Start Monitoring'), findsOneWidget);

    repository.dispose();
  });
}

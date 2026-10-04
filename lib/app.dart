import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'core/constants/app_constants.dart';
import 'core/theme/app_theme.dart';
import 'data/repository/usage_repository.dart';
import 'features/alerts/presentation/alerts_screen.dart';
import 'features/dashboard/presentation/dashboard_screen.dart';
import 'features/debug/presentation/debug_screen.dart';
import 'features/onboarding/presentation/onboarding_screen.dart';

class VeriQuotaApp extends StatelessWidget {
  final UsageRepository? usageRepository;
  final bool initialOnboardingCompleted;

  const VeriQuotaApp({
    super.key,
    this.usageRepository,
    this.initialOnboardingCompleted = false,
  });

  @override
  Widget build(BuildContext context) {
    final materialApp = MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: initialOnboardingCompleted ? const DashboardScreen() : const OnboardingScreen(),
      routes: {
        '/onboarding': (context) => const OnboardingScreen(),
        '/dashboard': (context) => const DashboardScreen(),
        '/alerts': (context) => const AlertsScreen(),
        '/debug': (context) => const DebugScreen(),
      },
    );

    if (usageRepository != null) {
      return ChangeNotifierProvider<UsageRepository>.value(
        value: usageRepository!,
        child: materialApp,
      );
    }

    return ChangeNotifierProvider<UsageRepository>(
      create: (_) => UsageRepository(),
      child: materialApp,
    );
  }
}

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../vpn_native/vpn_native_service.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final VpnNativeService _vpnService = VpnNativeService.instance;
  bool _isLoading = false;
  String? _errorMessage;

  void _openDebug() {
    Navigator.of(context).pushNamed('/debug');
  }

  Future<void> _handleGrantPermission() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final success = await _vpnService.startVpnMonitoring();
      if (!mounted) return;

      if (success) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('onboarding_completed', true);

        if (mounted) {
          Navigator.of(context).pushReplacementNamed('/dashboard');
        }
      } else {
        setState(() {
          _errorMessage =
              'VPN permission was not granted. Android requires this permission '
              'to allow VeriQuota to measure your data usage locally on your device. '
              'Please grant the permission to begin monitoring.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'An unexpected error occurred: $e. Please try again.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundOffWhite,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),
              // Wordmark with hidden long-press to access developer diagnostics
              GestureDetector(
                onLongPress: _openDebug,
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppConstants.appName,
                      style: AppTextStyles.displayLarge,
                    ),
                    SizedBox(height: 6),
                    Text(
                      AppConstants.appTagline,
                      style: AppTextStyles.bodyMedium,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Independent, verifiable accounting for every byte that leaves or enters your device.',
                        style: AppTextStyles.bodyLarge,
                      ),
                      const SizedBox(height: 24),
                      _buildFeatureItem(
                        icon: Icons.check_circle_outline,
                        iconColor: Colors.green[700]!,
                        title: '100% On-Device Measurement',
                        description:
                            'VeriQuota audits packet sizes locally using Android\'s VpnService interface. No proxies, no external relays.',
                      ),
                      const SizedBox(height: 16),
                      _buildFeatureItem(
                        icon: Icons.lock_outline,
                        iconColor: AppColors.primaryNavy,
                        title: 'Zero Data Collection',
                        description:
                            'Your browsing activity, DNS queries, and packet payloads never leave your hardware. No tracking or telemetry.',
                      ),
                      const SizedBox(height: 16),
                      _buildFeatureItem(
                        icon: Icons.speed_outlined,
                        iconColor: AppColors.primaryNavy,
                        title: 'Live Real-Time Metering',
                        description:
                            'See exactly which background apps and system services consume your mobile and Wi-Fi quotas as it happens.',
                      ),
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 20),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.alertAccent.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.alertAccent.withValues(alpha: 0.4)),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.warning_amber_rounded,
                                color: AppColors.alertAccent,
                                size: 22,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _errorMessage!,
                                  style: const TextStyle(
                                    color: AppColors.primaryNavy,
                                    fontSize: 13,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _isLoading ? null : _handleGrantPermission,
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Grant Permission & Start Monitoring'),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'Android will display a standard system confirmation prompt.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.secondaryGray.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureItem({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String description,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black12, width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: iconColor, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: AppColors.primaryNavy,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: AppTextStyles.bodyMedium.copyWith(fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

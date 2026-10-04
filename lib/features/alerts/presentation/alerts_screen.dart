import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/theme/app_colors.dart';
import '../../vpn_native/vpn_native_service.dart';

/// Alerts & Settings screen for configuring native threshold alert policies.
/// Thresholds are evaluated natively by Android VpnService so alerts fire
/// even when the Flutter UI is closed or suspended.
class AlertsScreen extends StatefulWidget {
  final VpnNativeService? vpnService;

  const AlertsScreen({super.key, this.vpnService});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  late final VpnNativeService _vpnService;

  bool _isLoading = true;
  bool _isSaving = false;
  bool _alertsEnabled = false;
  bool _notificationsAllowed = true;

  final TextEditingController _thresholdMbController = TextEditingController();
  final TextEditingController _windowMinutesController =
      TextEditingController();

  final List<int> _thresholdPresets = [10, 25, 50, 100, 250, 500];
  final List<int> _windowPresets = [5, 10, 15, 30, 60];

  @override
  void initState() {
    super.initState();
    _vpnService = widget.vpnService ?? VpnNativeService.instance;
    _loadCurrentConfig();
  }

  @override
  void dispose() {
    _thresholdMbController.dispose();
    _windowMinutesController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentConfig() async {
    setState(() => _isLoading = true);
    try {
      final config = await _vpnService.getAlertThreshold();
      final hasPermission = await _vpnService.areNotificationsEnabled();

      setState(() {
        _alertsEnabled = config.enabled;
        _thresholdMbController.text = config.thresholdMb.toString();
        _windowMinutesController.text = config.windowMinutes.toString();
        _notificationsAllowed = hasPermission;
        _isLoading = false;
      });
    } catch (_) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _onToggleChanged(bool value) async {
    if (value) {
      // User is enabling alerts: verify notification permission
      final hasPermission = await _vpnService.areNotificationsEnabled();
      if (!hasPermission) {
        final granted = await _vpnService.requestNotificationPermission();
        setState(() {
          _notificationsAllowed = granted;
        });

        if (!granted && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Notification permission is required for threshold alerts to appear.',
              ),
              backgroundColor: AppColors.alertAccent,
            ),
          );
        }
      }
    }

    setState(() {
      _alertsEnabled = value;
    });
  }

  Future<void> _saveConfig() async {
    final int? mb = int.tryParse(_thresholdMbController.text.trim());
    final int? minutes = int.tryParse(_windowMinutesController.text.trim());

    if (mb == null || mb <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid threshold in MB (> 0).'),
          backgroundColor: AppColors.alertAccent,
        ),
      );
      return;
    }

    if (minutes == null || minutes <= 0 || minutes > 120) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Please enter a valid window between 1 and 120 minutes.'),
          backgroundColor: AppColors.alertAccent,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    final success = await _vpnService.setAlertThreshold(
      enabled: _alertsEnabled,
      thresholdBytes: mb * 1024 * 1024,
      windowMinutes: minutes,
    );

    if (!mounted) return;
    setState(() => _isSaving = false);

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _alertsEnabled
                ? 'Alerts active: $mb MB in $minutes min (native background evaluation).'
                : 'Threshold alerts disabled.',
          ),
          backgroundColor: AppColors.primaryNavy,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to update alert configuration.'),
          backgroundColor: AppColors.alertAccent,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundOffWhite,
      appBar: AppBar(
        backgroundColor: AppColors.primaryNavy,
        foregroundColor: AppColors.surfaceWhite,
        title: const Text(
          'Alerts & Settings',
          style: TextStyle(
            fontFamily: 'Manrope',
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primaryNavy))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildArchitectureBadge(),
                  const SizedBox(height: 16),
                  if (!_notificationsAllowed) _buildPermissionNotice(),
                  _buildToggleCard(),
                  const SizedBox(height: 20),
                  _buildThresholdCard(),
                  const SizedBox(height: 20),
                  _buildWindowCard(),
                  const SizedBox(height: 24),
                  _buildSaveButton(),
                  const SizedBox(height: 28),
                  _buildTestingGuideCard(),
                ],
              ),
            ),
    );
  }

  Widget _buildArchitectureBadge() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.primaryNavy.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.shield_outlined,
              color: AppColors.primaryNavy,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Native VpnService Trigger',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: AppColors.primaryNavy,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Threshold checks run directly inside the native Android VPN daemon. Alerts fire even when VeriQuota is swiped away from Recents.',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontSize: 12,
                    color: AppColors.secondaryGray,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionNotice() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF2EC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.alertAccent.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.notifications_off_outlined,
              color: AppColors.alertAccent, size: 22),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Notification permission is disabled. Android won\'t display alert banners.',
              style: TextStyle(
                fontFamily: 'Manrope',
                fontSize: 12,
                color: Color(0xFF8F2D00),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: () async {
              final granted = await _vpnService.requestNotificationPermission();
              setState(() => _notificationsAllowed = granted);
            },
            child: const Text(
              'Allow',
              style: TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w700,
                color: AppColors.alertAccent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToggleCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Threshold Alerts',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: AppColors.primaryNavy,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Notify when ANY app crosses the quota',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontSize: 12,
                    color: AppColors.secondaryGray,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: _alertsEnabled,
            onChanged: _onToggleChanged,
            activeThumbColor: AppColors.alertAccent,
            activeTrackColor:
                AppColors.alertAccent.withValues(alpha: 0.3),
          ),
        ],
      ),
    );
  }

  Widget _buildThresholdCard() {
    final int currentVal = int.tryParse(_thresholdMbController.text) ?? 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.speed, color: AppColors.primaryNavy, size: 20),
              SizedBox(width: 8),
              Text(
                'Data Usage Threshold (MB)',
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.primaryNavy,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _thresholdMbController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              suffixText: 'MB',
              suffixStyle: const TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w700,
                color: AppColors.primaryNavy,
              ),
              hintText: 'e.g. 50',
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    const BorderSide(color: AppColors.primaryNavy, width: 1.5),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _thresholdPresets.map((preset) {
              final isSelected = currentVal == preset;
              return ChoiceChip(
                label: Text('${preset}MB'),
                selected: isSelected,
                onSelected: (selected) {
                  if (selected) {
                    setState(() {
                      _thresholdMbController.text = preset.toString();
                    });
                  }
                },
                selectedColor: AppColors.primaryNavy,
                labelStyle: TextStyle(
                  fontFamily: 'Manrope',
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color:
                      isSelected ? AppColors.surfaceWhite : AppColors.primaryNavy,
                ),
                backgroundColor: const Color(0xFFF0F0EE),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildWindowCard() {
    final int currentVal = int.tryParse(_windowMinutesController.text) ?? 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.timer_outlined, color: AppColors.primaryNavy, size: 20),
              SizedBox(width: 8),
              Text(
                'Rolling Time Window (Minutes)',
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.primaryNavy,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _windowMinutesController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              suffixText: 'Minutes',
              suffixStyle: const TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w700,
                color: AppColors.primaryNavy,
              ),
              hintText: 'e.g. 15',
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    const BorderSide(color: AppColors.primaryNavy, width: 1.5),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _windowPresets.map((preset) {
              final isSelected = currentVal == preset;
              return ChoiceChip(
                label: Text('${preset}m'),
                selected: isSelected,
                onSelected: (selected) {
                  if (selected) {
                    setState(() {
                      _windowMinutesController.text = preset.toString();
                    });
                  }
                },
                selectedColor: AppColors.primaryNavy,
                labelStyle: TextStyle(
                  fontFamily: 'Manrope',
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color:
                      isSelected ? AppColors.surfaceWhite : AppColors.primaryNavy,
                ),
                backgroundColor: const Color(0xFFF0F0EE),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildSaveButton() {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton(
        onPressed: _isSaving ? null : _saveConfig,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primaryNavy,
          foregroundColor: AppColors.surfaceWhite,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          elevation: 0,
        ),
        child: _isSaving
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.surfaceWhite,
                ),
              )
            : const Text(
                'Save Alert Configuration',
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
      ),
    );
  }

  Widget _buildTestingGuideCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, color: AppColors.secondaryGray, size: 18),
              SizedBox(width: 8),
              Text(
                'Cooldown & Anti-Spam Policy',
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: AppColors.primaryNavy,
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Text(
            '• A 15-minute cooldown is enforced per application so repeated packets do not flood your notification tray.\n• Saving new alert thresholds resets active cooldowns immediately.',
            style: TextStyle(
              fontFamily: 'Manrope',
              fontSize: 12,
              color: AppColors.secondaryGray,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

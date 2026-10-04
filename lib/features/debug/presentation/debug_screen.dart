import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../data/repository/usage_repository.dart';
import '../../vpn_native/models/app_usage_entry.dart';
import '../../vpn_native/vpn_native_service.dart';

/// Hidden developer diagnostic screen for verifying VPN tunneling and live platform events.
class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  final VpnNativeService _vpnService = VpnNativeService.instance;
  bool _isVpnRunning = false;
  List<AppUsageEntry> _usageList = [];
  StreamSubscription<List<AppUsageEntry>>? _usageSub;

  @override
  void initState() {
    super.initState();
    _checkVpnStatus();
    _usageSub = _vpnService.usageStream.listen((entries) {
      if (mounted) {
        setState(() {
          _usageList = entries;
        });
      }
    });
  }

  @override
  void dispose() {
    _usageSub?.cancel();
    super.dispose();
  }

  Future<void> _checkVpnStatus() async {
    final active = await _vpnService.isVpnRunning();
    if (mounted) {
      setState(() {
        _isVpnRunning = active;
      });
    }
  }

  Future<void> _toggleVpn() async {
    if (_isVpnRunning) {
      await _vpnService.stopVpnMonitoring();
    } else {
      await _vpnService.startVpnMonitoring();
    }
    await _checkVpnStatus();
  }

  Future<void> _fetchSnapshot() async {
    final snapshot = await _vpnService.getCurrentUsage();
    if (mounted) {
      setState(() {
        _usageList = snapshot;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Fetched snapshot: ${snapshot.length} apps measured'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _triggerManualDbPersist() async {
    final repository = context.read<UsageRepository>();
    await repository.persistSnapshot();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Manually triggered SQLite snapshot flush'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundOffWhite,
      appBar: AppBar(
        title: const Text('Developer Diagnostics'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(16.0),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12.0),
                  border: Border.all(color: Colors.black12),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black12,
                      blurRadius: 4,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.bug_report_outlined,
                          color: _isVpnRunning ? Colors.green : AppColors.secondaryGray,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'VPN Relay Control',
                          style: AppTextStyles.labelLarge.copyWith(
                            color: AppColors.primaryNavy,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: _isVpnRunning
                                ? Colors.green.withValues(alpha: 0.15)
                                : Colors.grey.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _isVpnRunning ? 'VPN ACTIVE' : 'VPN INACTIVE',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: _isVpnRunning ? Colors.green[800] : Colors.grey[700],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _toggleVpn,
                            child: Text(_isVpnRunning ? 'Stop VPN' : 'Start VPN Test'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _fetchSnapshot,
                            child: const Text('Get Snapshot'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton.icon(
                        icon: const Icon(Icons.save_outlined, size: 18),
                        onPressed: _triggerManualDbPersist,
                        label: const Text('Flush Snapshot to SQLite'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Live Measured Apps (${_usageList.length}):',
                style: AppTextStyles.bodyMedium.copyWith(
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryNavy,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _usageList.isEmpty
                    ? Center(
                        child: Text(
                          _isVpnRunning
                              ? 'Listening for network packets...\nOpen a browser or app to test traffic.'
                              : 'Start the VPN test above to begin measuring.',
                          textAlign: TextAlign.center,
                          style: AppTextStyles.bodyMedium,
                        ),
                      )
                    : ListView.builder(
                        itemCount: _usageList.length,
                        itemBuilder: (context, index) {
                          final item = _usageList[index];
                          return Card(
                            elevation: 0,
                            color: Colors.white,
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: ListTile(
                              dense: true,
                              title: Text(
                                item.packageName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                              subtitle: Text(
                                'Rx: ${item.humanReadableRx}  •  Tx: ${item.humanReadableTx}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: Text(
                                item.humanReadableTotal,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primaryNavy,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

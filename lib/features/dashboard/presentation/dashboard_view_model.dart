import 'dart:async';
import 'package:flutter/material.dart';
import '../../../data/repository/usage_repository.dart';
import '../../vpn_native/models/app_usage_entry.dart';
import '../../vpn_native/vpn_native_service.dart';

enum DashboardTimeRange {
  today,
  thisWeek,
  allTime,
}

/// ViewModel for DashboardScreen managing live session telemetry and historical usage queries.
class DashboardViewModel extends ChangeNotifier {
  final VpnNativeService _vpnService;
  final UsageRepository usageRepository;

  DashboardTimeRange _selectedTimeRange = DashboardTimeRange.today;
  bool _isVpnActive = false;
  bool _isLoadingHistory = false;

  // Real-time live session telemetry from VpnNativeService.usageStream
  List<AppUsageEntry> _liveSessionApps = [];
  int _liveSessionRxBytes = 0;
  int _liveSessionTxBytes = 0;

  // Aggregated historical list based on _selectedTimeRange
  List<AppUsageEntry> _historicalApps = [];

  StreamSubscription<List<AppUsageEntry>>? _liveStreamSub;

  DashboardViewModel({
    VpnNativeService? vpnService,
    required this.usageRepository,
  }) : _vpnService = vpnService ?? VpnNativeService.instance {
    _init();
  }

  DashboardTimeRange get selectedTimeRange => _selectedTimeRange;
  bool get isVpnActive => _isVpnActive;
  bool get isLoadingHistory => _isLoadingHistory;

  int get liveSessionRxBytes => _liveSessionRxBytes;
  int get liveSessionTxBytes => _liveSessionTxBytes;
  int get liveSessionTotalBytes => _liveSessionRxBytes + _liveSessionTxBytes;
  List<AppUsageEntry> get liveSessionApps => _liveSessionApps;

  List<AppUsageEntry> get displayedApps => _historicalApps;

  int get maxHistoricalUsageBytes {
    if (_historicalApps.isEmpty) return 1;
    return _historicalApps.first.totalBytes > 0
        ? _historicalApps.first.totalBytes
        : 1;
  }

  void _init() {
    checkVpnStatus();
    _startLiveStreamListening();
    loadHistoricalData();

    // Listen to UsageRepository notifications (when new periodic snapshots are saved)
    usageRepository.addListener(_onRepositoryUpdated);
  }

  void _onRepositoryUpdated() {
    loadHistoricalData(silent: true);
  }

  void _startLiveStreamListening() {
    _liveStreamSub?.cancel();
    _liveStreamSub = _vpnService.usageStream.listen((entries) {
      _liveSessionApps = entries;
      int rx = 0;
      int tx = 0;
      for (final app in entries) {
        rx += app.rxBytes;
        tx += app.txBytes;
      }
      _liveSessionRxBytes = rx;
      _liveSessionTxBytes = tx;
      notifyListeners();
    });
  }

  Future<void> checkVpnStatus() async {
    _isVpnActive = await _vpnService.isVpnRunning();
    notifyListeners();
  }

  Future<void> toggleVpnMonitoring() async {
    if (_isVpnActive) {
      await _vpnService.stopVpnMonitoring();
      _isVpnActive = false;
    } else {
      final success = await _vpnService.startVpnMonitoring();
      _isVpnActive = success;
    }
    notifyListeners();
  }

  void setTimeRange(DashboardTimeRange range) {
    if (_selectedTimeRange == range) return;
    _selectedTimeRange = range;
    notifyListeners();
    loadHistoricalData();
  }

  Future<void> loadHistoricalData({bool silent = false}) async {
    if (!silent) {
      _isLoadingHistory = true;
      notifyListeners();
    }

    try {
      final List<AppUsageEntry> results;
      switch (_selectedTimeRange) {
        case DashboardTimeRange.today:
          results = await usageRepository.getUsageToday();
          break;
        case DashboardTimeRange.thisWeek:
          results = await usageRepository.getUsageThisWeek();
          break;
        case DashboardTimeRange.allTime:
          results = await usageRepository.getTopAppsByUsage(
            range: DateTimeRange(
              start: DateTime.fromMillisecondsSinceEpoch(0),
              end: DateTime.now(),
            ),
            limit: 100,
          );
          break;
      }
      _historicalApps = results;
    } catch (_) {
      _historicalApps = [];
    } finally {
      _isLoadingHistory = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    usageRepository.removeListener(_onRepositoryUpdated);
    _liveStreamSub?.cancel();
    super.dispose();
  }
}

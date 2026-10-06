import 'dart:async';
import 'package:flutter/material.dart';
import '../../../data/models/history_entry.dart';
import '../../../data/repository/usage_repository.dart';
import '../../vpn_native/models/app_usage_entry.dart';
import '../../vpn_native/vpn_native_service.dart';

enum DashboardTimeRange {
  today,
  thisWeek,
  allTime,
  history, // New tab for past days scrollable list
}

/// ViewModel for DashboardScreen managing live session telemetry, historical usage queries,
/// and permanent daily history.
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

  // Permanent daily history entries
  List<DailyHistoryEntry> _dailyHistory = [];

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
  List<DailyHistoryEntry> get dailyHistory => _dailyHistory;

  int get selectedRangeTotalBytes {
    int sum = 0;
    for (final app in _historicalApps) {
      sum += app.totalBytes;
    }
    return sum;
  }

  /// Formatted date label for today's view (e.g. "Total usage — 5 October 2026")
  String get todayDateLabel {
    final now = DateTime.now();
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return 'Total usage — ${now.day} ${months[now.month - 1]} ${now.year}';
  }

  /// Formatted date range label for this week (e.g. "Week of 29 Sep – 5 Oct 2026")
  String get thisWeekDateLabel {
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    final monday = startOfToday.subtract(Duration(days: now.weekday - 1));
    final sunday = monday.add(const Duration(days: 6));

    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final startDay = monday.day;
    final startMonth = months[monday.month - 1];
    final endDay = sunday.day;
    final endMonth = months[sunday.month - 1];
    final year = sunday.year;

    if (startMonth == endMonth) {
      return 'Week of $startDay – $endDay $startMonth $year';
    } else {
      return 'Week of $startDay $startMonth – $endDay $endMonth $year';
    }
  }

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
          results = await usageRepository.getUsageAllTime();
          break;
        case DashboardTimeRange.history:
          results = [];
          break;
      }
      _historicalApps = results;
      _dailyHistory = await usageRepository.getDailyHistory(days: 30);
    } catch (_) {
      _historicalApps = [];
      _dailyHistory = [];
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

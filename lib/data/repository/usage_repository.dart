import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import '../../features/vpn_native/models/app_usage_entry.dart';
import '../../features/vpn_native/vpn_native_service.dart';
import '../local/app_database.dart';
import '../models/usage_record.dart';

/// Repository responsible for persisting periodic network usage snapshots to SQLite
/// and querying historical usage analytics (today, this week, top apps, per-app).
class UsageRepository extends ChangeNotifier {
  final VpnNativeService _vpnService;
  final AppDatabase _appDatabase;
  final Duration snapshotInterval;
  final Duration maxRetention;

  StreamSubscription<List<AppUsageEntry>>? _streamSubscription;
  Timer? _snapshotTimer;

  // Most recent snapshot emitted by VpnNativeService
  final Map<String, AppUsageEntry> _latestStreamEntries = {};

  // Last persisted cumulative values (to compute deltas per interval)
  final Map<String, ({int rx, int tx})> _lastPersistedTotals = {};

  bool _isInitialized = false;

  UsageRepository({
    VpnNativeService? vpnService,
    AppDatabase? appDatabase,
    this.snapshotInterval = const Duration(minutes: 1),
    this.maxRetention = const Duration(days: 30),
    bool autoStart = true,
  })  : _vpnService = vpnService ?? VpnNativeService.instance,
        _appDatabase = appDatabase ?? AppDatabase.instance {
    if (autoStart) {
      init();
    }
  }

  bool get isInitialized => _isInitialized;

  /// Initializes the database, starts the stream listener, and sets up periodic persistence.
  Future<void> init() async {
    if (_isInitialized) return;
    await _appDatabase.database;
    _isInitialized = true;

    startListening();
    // Prune stale data on startup
    await pruneOldData();
  }

  /// Starts listening to VpnNativeService.usageStream and schedules the periodic flush.
  void startListening() {
    _streamSubscription?.cancel();
    _streamSubscription = _vpnService.usageStream.listen(
      (entries) {
        for (final entry in entries) {
          _latestStreamEntries[entry.packageName] = entry;
        }
      },
      onError: (error) {
        // Platform channel event channel error handling
      },
    );

    _snapshotTimer?.cancel();
    _snapshotTimer = Timer.periodic(snapshotInterval, (_) {
      persistSnapshot();
    });
  }

  /// Stops stream listening and cancels the periodic snapshot timer.
  void stopListening() {
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
    _streamSubscription?.cancel();
    _streamSubscription = null;
  }

  /// Persists a rolled-up incremental snapshot of usage deltas since the last flush.
  Future<void> persistSnapshot() async {
    if (_latestStreamEntries.isEmpty) return;

    final now = DateTime.now();
    final List<UsageRecord> recordsToInsert = [];

    for (final entry in _latestStreamEntries.values) {
      final last = _lastPersistedTotals[entry.packageName];
      int deltaRx;
      int deltaTx;

      if (last == null) {
        deltaRx = entry.rxBytes;
        deltaTx = entry.txBytes;
      } else if (entry.rxBytes < last.rx || entry.txBytes < last.tx) {
        // VPN or device restarted; counter reset
        deltaRx = entry.rxBytes;
        deltaTx = entry.txBytes;
      } else {
        deltaRx = entry.rxBytes - last.rx;
        deltaTx = entry.txBytes - last.tx;
      }

      if (deltaRx > 0 || deltaTx > 0) {
        recordsToInsert.add(UsageRecord(
          packageName: entry.packageName,
          rxBytes: deltaRx,
          txBytes: deltaTx,
          timestamp: now,
        ));
      }

      _lastPersistedTotals[entry.packageName] = (rx: entry.rxBytes, tx: entry.txBytes);
    }

    if (recordsToInsert.isNotEmpty) {
      await insertRecords(recordsToInsert);
      notifyListeners();
    }
  }

  /// Inserts a batch of usage records into SQLite.
  Future<void> insertRecords(List<UsageRecord> records) async {
    if (records.isEmpty) return;
    final db = await _appDatabase.database;
    final batch = db.batch();
    for (final record in records) {
      batch.insert(
        AppDatabase.tableUsageSnapshots,
        record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Inserts a single usage record into SQLite.
  Future<void> insertRecord(UsageRecord record) async {
    final db = await _appDatabase.database;
    await db.insert(
      AppDatabase.tableUsageSnapshots,
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    notifyListeners();
  }

  /// Queries aggregated usage for all apps recorded today (since 00:00:00 local time).
  Future<List<AppUsageEntry>> getUsageToday({DateTime? now}) async {
    final current = now ?? DateTime.now();
    final startOfToday = DateTime(current.year, current.month, current.day);
    return _queryAggregatedUsage(
      startMillis: startOfToday.millisecondsSinceEpoch,
      endMillis: current.millisecondsSinceEpoch,
    );
  }

  /// Queries aggregated usage for all apps recorded this week (since Monday 00:00:00 local time).
  Future<List<AppUsageEntry>> getUsageThisWeek({DateTime? now}) async {
    final current = now ?? DateTime.now();
    final startOfToday = DateTime(current.year, current.month, current.day);
    final startOfWeek = startOfToday.subtract(Duration(days: current.weekday - 1));
    return _queryAggregatedUsage(
      startMillis: startOfWeek.millisecondsSinceEpoch,
      endMillis: current.millisecondsSinceEpoch,
    );
  }

  /// Queries usage for a specific app within an optional time window.
  Future<AppUsageEntry?> getUsageForApp(
    String packageName, {
    DateTime? start,
    DateTime? end,
  }) async {
    final db = await _appDatabase.database;
    final startMillis = start?.millisecondsSinceEpoch ?? 0;
    final endMillis = end?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch;

    final List<Map<String, dynamic>> results = await db.rawQuery(
      '''
      SELECT 
        ${AppDatabase.colPackageName} AS packageName,
        SUM(${AppDatabase.colRxBytes}) AS rxBytes,
        SUM(${AppDatabase.colTxBytes}) AS txBytes,
        SUM(${AppDatabase.colRxBytes} + ${AppDatabase.colTxBytes}) AS totalBytes,
        MAX(${AppDatabase.colTimestamp}) AS lastUpdated
      FROM ${AppDatabase.tableUsageSnapshots}
      WHERE ${AppDatabase.colPackageName} = ? 
        AND ${AppDatabase.colTimestamp} >= ? 
        AND ${AppDatabase.colTimestamp} <= ?
      GROUP BY ${AppDatabase.colPackageName}
      ''',
      [packageName, startMillis, endMillis],
    );

    if (results.isEmpty) return null;

    final row = results.first;
    final total = (row['totalBytes'] as num?)?.toInt() ?? 0;
    if (total == 0) return null;

    return AppUsageEntry(
      packageName: row['packageName'] as String,
      rxBytes: (row['rxBytes'] as num?)?.toInt() ?? 0,
      txBytes: (row['txBytes'] as num?)?.toInt() ?? 0,
      totalBytes: total,
      lastUpdated: DateTime.fromMillisecondsSinceEpoch(
        (row['lastUpdated'] as num?)?.toInt() ?? endMillis,
      ),
    );
  }

  /// Queries the top apps by total usage within the specified [DateTimeRange].
  Future<List<AppUsageEntry>> getTopAppsByUsage({
    required DateTimeRange range,
    int limit = 5,
  }) async {
    return _queryAggregatedUsage(
      startMillis: range.start.millisecondsSinceEpoch,
      endMillis: range.end.millisecondsSinceEpoch,
      limit: limit,
    );
  }

  /// Internal helper to query and aggregate usage grouped by packageName.
  Future<List<AppUsageEntry>> _queryAggregatedUsage({
    required int startMillis,
    required int endMillis,
    int? limit,
  }) async {
    final db = await _appDatabase.database;

    final String limitClause = limit != null && limit > 0 ? 'LIMIT $limit' : '';

    final List<Map<String, dynamic>> rows = await db.rawQuery(
      '''
      SELECT 
        ${AppDatabase.colPackageName} AS packageName,
        SUM(${AppDatabase.colRxBytes}) AS rxBytes,
        SUM(${AppDatabase.colTxBytes}) AS txBytes,
        SUM(${AppDatabase.colRxBytes} + ${AppDatabase.colTxBytes}) AS totalBytes,
        MAX(${AppDatabase.colTimestamp}) AS lastUpdated
      FROM ${AppDatabase.tableUsageSnapshots}
      WHERE ${AppDatabase.colTimestamp} >= ? AND ${AppDatabase.colTimestamp} <= ?
      GROUP BY ${AppDatabase.colPackageName}
      HAVING totalBytes > 0
      ORDER BY totalBytes DESC
      $limitClause
      ''',
      [startMillis, endMillis],
    );

    return rows.map((row) {
      final lastUpdatedMillis = (row['lastUpdated'] as num?)?.toInt() ?? endMillis;
      return AppUsageEntry(
        packageName: row['packageName'] as String,
        rxBytes: (row['rxBytes'] as num?)?.toInt() ?? 0,
        txBytes: (row['txBytes'] as num?)?.toInt() ?? 0,
        totalBytes: (row['totalBytes'] as num?)?.toInt() ?? 0,
        lastUpdated: DateTime.fromMillisecondsSinceEpoch(lastUpdatedMillis),
      );
    }).toList();
  }

  /// Deletes snapshots older than the retention threshold (default 30 days).
  Future<int> pruneOldData({DateTime? before}) async {
    final db = await _appDatabase.database;
    final threshold = before ?? DateTime.now().subtract(maxRetention);
    final count = await db.delete(
      AppDatabase.tableUsageSnapshots,
      where: '${AppDatabase.colTimestamp} < ?',
      whereArgs: [threshold.millisecondsSinceEpoch],
    );
    return count;
  }

  @override
  void dispose() {
    stopListening();
    super.dispose();
  }
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import '../../features/vpn_native/models/app_usage_entry.dart';
import '../../features/vpn_native/vpn_native_service.dart';
import '../local/app_database.dart';
import '../models/daily_aggregate_record.dart';
import '../models/history_entry.dart';
import '../models/usage_record.dart';

/// Repository responsible for persisting periodic network usage snapshots to SQLite,
/// maintaining permanent daily aggregates, and querying historical analytics.
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
    this.maxRetention = const Duration(days: 14), // Raw snapshot retention reduced to 14 days
    bool autoStart = true,
  })  : _vpnService = vpnService ?? VpnNativeService.instance,
        _appDatabase = appDatabase ?? AppDatabase.instance {
    if (autoStart) {
      init();
    }
  }

  bool get isInitialized => _isInitialized;

  /// Formats a [DateTime] into a standard local ISO date string: YYYY-MM-DD.
  static String formatDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Initializes the database, starts the stream listener, rolls up completed days,
  /// and sets up periodic persistence and raw snapshot pruning.
  Future<void> init() async {
    if (_isInitialized) return;
    await _appDatabase.database;
    _isInitialized = true;

    startListening();

    // 1. Roll up any completed days into permanent storage
    await rollupCompletedDays();

    // 2. Safely prune raw minute snapshots older than retention (14 days)
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

  /// Inserts or replaces permanent daily aggregate records.
  Future<void> insertDailyAggregates(List<DailyAggregateRecord> records) async {
    if (records.isEmpty) return;
    final db = await _appDatabase.database;
    final batch = db.batch();
    for (final record in records) {
      batch.insert(
        AppDatabase.tableDailyAggregates,
        record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    notifyListeners();
  }

  /// Rolls up raw minute snapshots for all ended calendar days (strictly before today's local midnight)
  /// into the permanent `daily_usage_aggregates` table.
  /// Idempotent: safe to run repeatedly.
  Future<void> rollupCompletedDays({DateTime? now}) async {
    final current = now ?? DateTime.now();
    final startOfToday = DateTime(current.year, current.month, current.day);
    final db = await _appDatabase.database;

    // Check if there are raw snapshots prior to today
    final List<Map<String, dynamic>> rangeResult = await db.rawQuery(
      '''
      SELECT MIN(${AppDatabase.colTimestamp}) AS minTs, MAX(${AppDatabase.colTimestamp}) AS maxTs
      FROM ${AppDatabase.tableUsageSnapshots}
      WHERE ${AppDatabase.colTimestamp} < ?
      ''',
      [startOfToday.millisecondsSinceEpoch],
    );

    if (rangeResult.isEmpty || rangeResult.first['minTs'] == null) {
      return;
    }

    final minTs = (rangeResult.first['minTs'] as num).toInt();
    final maxTs = (rangeResult.first['maxTs'] as num).toInt();

    final minDate = DateTime.fromMillisecondsSinceEpoch(minTs);
    final maxDate = DateTime.fromMillisecondsSinceEpoch(maxTs);

    var curDay = DateTime(minDate.year, minDate.month, minDate.day);
    final lastDay = DateTime(maxDate.year, maxDate.month, maxDate.day);

    while (!curDay.isAfter(lastDay) && curDay.isBefore(startOfToday)) {
      final startOfDay = DateTime(curDay.year, curDay.month, curDay.day, 0, 0, 0);
      final endOfDay = DateTime(curDay.year, curDay.month, curDay.day, 23, 59, 59, 999);
      final dateStr = formatDate(curDay);

      final List<Map<String, dynamic>> dayTotals = await db.rawQuery(
        '''
        SELECT 
          ${AppDatabase.colPackageName} AS packageName,
          SUM(${AppDatabase.colRxBytes}) AS rxBytes,
          SUM(${AppDatabase.colTxBytes}) AS txBytes,
          SUM(${AppDatabase.colRxBytes} + ${AppDatabase.colTxBytes}) AS totalBytes
        FROM ${AppDatabase.tableUsageSnapshots}
        WHERE ${AppDatabase.colTimestamp} >= ? AND ${AppDatabase.colTimestamp} <= ?
        GROUP BY ${AppDatabase.colPackageName}
        HAVING totalBytes > 0
        ''',
        [startOfDay.millisecondsSinceEpoch, endOfDay.millisecondsSinceEpoch],
      );

      if (dayTotals.isNotEmpty) {
        final batch = db.batch();
        for (final row in dayTotals) {
          batch.insert(
            AppDatabase.tableDailyAggregates,
            {
              AppDatabase.colDailyDate: dateStr,
              AppDatabase.colPackageName: row['packageName'],
              AppDatabase.colRxBytes: (row['rxBytes'] as num).toInt(),
              AppDatabase.colTxBytes: (row['txBytes'] as num).toInt(),
              AppDatabase.colDailyTotalBytes: (row['totalBytes'] as num).toInt(),
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      }

      curDay = curDay.add(const Duration(days: 1));
    }
  }

  /// Queries aggregated usage for all apps recorded today (since 00:00:00 local time).
  Future<List<AppUsageEntry>> getUsageToday({DateTime? now}) async {
    final current = now ?? DateTime.now();
    final startOfToday = DateTime(current.year, current.month, current.day);
    return _queryAggregatedRawUsage(
      startMillis: startOfToday.millisecondsSinceEpoch,
      endMillis: current.millisecondsSinceEpoch,
    );
  }

  /// Queries aggregated usage for all apps recorded this week (Monday 00:00:00 local to now).
  /// Sums permanent daily aggregates for past completed days in the week + today's live raw data.
  /// Accumulates across days and does not drop to zero when a new day begins.
  Future<List<AppUsageEntry>> getUsageThisWeek({DateTime? now}) async {
    final current = now ?? DateTime.now();
    final startOfToday = DateTime(current.year, current.month, current.day);
    final monday = startOfToday.subtract(Duration(days: current.weekday - 1));
    final mondayStart = DateTime(monday.year, monday.month, monday.day, 0, 0, 0);

    // Roll up completed days up to today
    await rollupCompletedDays(now: current);

    final db = await _appDatabase.database;
    final mondayStr = formatDate(mondayStart);
    final todayStr = formatDate(startOfToday);

    // 1. Query daily aggregates for completed days of this week: monday <= date < today
    final List<Map<String, dynamic>> dailyRows = await db.rawQuery(
      '''
      SELECT 
        ${AppDatabase.colPackageName} AS packageName,
        SUM(${AppDatabase.colRxBytes}) AS rxBytes,
        SUM(${AppDatabase.colTxBytes}) AS txBytes,
        SUM(${AppDatabase.colDailyTotalBytes}) AS totalBytes
      FROM ${AppDatabase.tableDailyAggregates}
      WHERE ${AppDatabase.colDailyDate} >= ? AND ${AppDatabase.colDailyDate} < ?
      GROUP BY ${AppDatabase.colPackageName}
      ''',
      [mondayStr, todayStr],
    );

    // 2. Query today's raw usage
    final todayUsage = await getUsageToday(now: current);

    // 3. Merge completed days + today
    return _mergeAggregatesWithToday(
      dailyRows: dailyRows,
      todayUsage: todayUsage,
      fallbackTimestamp: startOfToday,
    );
  }

  /// Queries aggregated usage for all apps across all time.
  /// Sums all permanent daily aggregates PLUS today's live raw data.
  /// Truly permanent and unaffected by raw minute snapshot pruning.
  Future<List<AppUsageEntry>> getUsageAllTime({DateTime? now}) async {
    final current = now ?? DateTime.now();
    final startOfToday = DateTime(current.year, current.month, current.day);
    final todayStr = formatDate(startOfToday);

    await rollupCompletedDays(now: current);

    final db = await _appDatabase.database;

    // 1. Query all permanent daily aggregates up to yesterday
    final List<Map<String, dynamic>> dailyRows = await db.rawQuery(
      '''
      SELECT 
        ${AppDatabase.colPackageName} AS packageName,
        SUM(${AppDatabase.colRxBytes}) AS rxBytes,
        SUM(${AppDatabase.colTxBytes}) AS txBytes,
        SUM(${AppDatabase.colDailyTotalBytes}) AS totalBytes
      FROM ${AppDatabase.tableDailyAggregates}
      WHERE ${AppDatabase.colDailyDate} < ?
      GROUP BY ${AppDatabase.colPackageName}
      ''',
      [todayStr],
    );

    // 2. Query today's raw usage
    final todayUsage = await getUsageToday(now: current);

    // 3. Merge all historical days + today
    return _mergeAggregatesWithToday(
      dailyRows: dailyRows,
      todayUsage: todayUsage,
      fallbackTimestamp: startOfToday,
    );
  }

  /// Helper to merge daily aggregate query rows with today's live app usage.
  List<AppUsageEntry> _mergeAggregatesWithToday({
    required List<Map<String, dynamic>> dailyRows,
    required List<AppUsageEntry> todayUsage,
    required DateTime fallbackTimestamp,
  }) {
    final Map<String, ({int rx, int tx, DateTime lastUpdated})> map = {};

    for (final row in dailyRows) {
      final pkg = row['packageName'] as String;
      final rx = (row['rxBytes'] as num?)?.toInt() ?? 0;
      final tx = (row['txBytes'] as num?)?.toInt() ?? 0;
      map[pkg] = (rx: rx, tx: tx, lastUpdated: fallbackTimestamp);
    }

    for (final app in todayUsage) {
      final existing = map[app.packageName];
      if (existing != null) {
        map[app.packageName] = (
          rx: existing.rx + app.rxBytes,
          tx: existing.tx + app.txBytes,
          lastUpdated: app.lastUpdated,
        );
      } else {
        map[app.packageName] = (
          rx: app.rxBytes,
          tx: app.txBytes,
          lastUpdated: app.lastUpdated,
        );
      }
    }

    final results = map.entries.map((e) {
      final total = e.value.rx + e.value.tx;
      return AppUsageEntry(
        packageName: e.key,
        rxBytes: e.value.rx,
        txBytes: e.value.tx,
        totalBytes: total,
        lastUpdated: e.value.lastUpdated,
      );
    }).where((app) => app.totalBytes > 0).toList();

    results.sort((a, b) => b.totalBytes.compareTo(a.totalBytes));
    return results;
  }

  /// Returns a list of [DailyHistoryEntry] for the last [days] calendar days, newest first.
  /// Combines today's partial-day live usage with permanent past daily aggregates.
  Future<List<DailyHistoryEntry>> getDailyHistory({
    int days = 30,
    DateTime? now,
  }) async {
    final current = now ?? DateTime.now();
    final startOfToday = DateTime(current.year, current.month, current.day);
    final todayStr = formatDate(startOfToday);

    await rollupCompletedDays(now: current);

    final db = await _appDatabase.database;

    // 1. Query past daily aggregates grouped by date
    final List<Map<String, dynamic>> rows = await db.rawQuery(
      '''
      SELECT 
        ${AppDatabase.colDailyDate} AS date,
        SUM(${AppDatabase.colRxBytes}) AS rxBytes,
        SUM(${AppDatabase.colTxBytes}) AS txBytes,
        SUM(${AppDatabase.colDailyTotalBytes}) AS totalBytes
      FROM ${AppDatabase.tableDailyAggregates}
      WHERE ${AppDatabase.colDailyDate} < ?
      GROUP BY ${AppDatabase.colDailyDate}
      ORDER BY ${AppDatabase.colDailyDate} DESC
      LIMIT ?
      ''',
      [todayStr, days],
    );

    final List<DailyHistoryEntry> entries = [];

    // 2. Compute today's partial usage
    final todayApps = await getUsageToday(now: current);
    int todayRx = 0;
    int todayTx = 0;
    for (final app in todayApps) {
      todayRx += app.rxBytes;
      todayTx += app.txBytes;
    }
    final todayTotal = todayRx + todayTx;

    entries.add(DailyHistoryEntry(
      date: todayStr,
      dateTime: startOfToday,
      totalBytes: todayTotal,
      rxBytes: todayRx,
      txBytes: todayTx,
    ));

    // 3. Add past days
    for (final row in rows) {
      final dateString = row['date'] as String;
      final parts = dateString.split('-').map(int.parse).toList();
      final dt = DateTime(parts[0], parts[1], parts[2]);

      entries.add(DailyHistoryEntry(
        date: dateString,
        dateTime: dt,
        totalBytes: (row['totalBytes'] as num?)?.toInt() ?? 0,
        rxBytes: (row['rxBytes'] as num?)?.toInt() ?? 0,
        txBytes: (row['txBytes'] as num?)?.toInt() ?? 0,
      ));
    }

    if (entries.length > days) {
      return entries.sublist(0, days);
    }
    return entries;
  }

  /// Returns a list of [WeeklyHistoryEntry] for the last [weeks] calendar weeks, newest first.
  Future<List<WeeklyHistoryEntry>> getWeeklyHistory({
    int weeks = 8,
    DateTime? now,
  }) async {
    final current = now ?? DateTime.now();
    final startOfToday = DateTime(current.year, current.month, current.day);
    final monday = startOfToday.subtract(Duration(days: current.weekday - 1));

    await rollupCompletedDays(now: current);

    final List<WeeklyHistoryEntry> entries = [];

    for (int w = 0; w < weeks; w++) {
      final weekMonday = DateTime(monday.year, monday.month, monday.day - (w * 7), 0, 0, 0);
      final weekSunday = DateTime(weekMonday.year, weekMonday.month, weekMonday.day + 6, 23, 59, 59, 999);

      if (w == 0) {
        // Current week: includes today's live data
        final weekUsage = await getUsageThisWeek(now: current);
        int total = 0;
        int rx = 0;
        int tx = 0;
        for (final app in weekUsage) {
          total += app.totalBytes;
          rx += app.rxBytes;
          tx += app.txBytes;
        }
        entries.add(WeeklyHistoryEntry(
          weekStartDate: weekMonday,
          weekEndDate: weekSunday.isAfter(current) ? current : weekSunday,
          totalBytes: total,
          rxBytes: rx,
          txBytes: tx,
        ));
      } else {
        // Past week: query daily aggregates between weekMonday and weekSunday
        final mondayStr = formatDate(weekMonday);
        final sundayStr = formatDate(weekSunday);

        final db = await _appDatabase.database;
        final List<Map<String, dynamic>> rows = await db.rawQuery(
          '''
          SELECT 
            SUM(${AppDatabase.colRxBytes}) AS rxBytes,
            SUM(${AppDatabase.colTxBytes}) AS txBytes,
            SUM(${AppDatabase.colDailyTotalBytes}) AS totalBytes
          FROM ${AppDatabase.tableDailyAggregates}
          WHERE ${AppDatabase.colDailyDate} >= ? AND ${AppDatabase.colDailyDate} <= ?
          ''',
          [mondayStr, sundayStr],
        );

        final total = (rows.first['totalBytes'] as num?)?.toInt() ?? 0;
        final rx = (rows.first['rxBytes'] as num?)?.toInt() ?? 0;
        final tx = (rows.first['txBytes'] as num?)?.toInt() ?? 0;

        if (total > 0 || entries.length < 2) {
          entries.add(WeeklyHistoryEntry(
            weekStartDate: weekMonday,
            weekEndDate: weekSunday,
            totalBytes: total,
            rxBytes: rx,
            txBytes: tx,
          ));
        }
      }
    }

    return entries;
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

  /// Queries top apps from raw minute snapshots within a specific [DateTimeRange].
  Future<List<AppUsageEntry>> getTopAppsByUsage({
    required DateTimeRange range,
    int limit = 5,
  }) async {
    return _queryAggregatedRawUsage(
      startMillis: range.start.millisecondsSinceEpoch,
      endMillis: range.end.millisecondsSinceEpoch,
      limit: limit,
    );
  }

  /// Internal helper to query and aggregate usage from raw minute snapshots.
  Future<List<AppUsageEntry>> _queryAggregatedRawUsage({
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

  /// Deletes raw minute snapshots older than [maxRetention] (14 days).
  /// Only runs AFTER completed days are safely rolled up into [tableDailyAggregates].
  /// The permanent [tableDailyAggregates] table is NEVER deleted.
  Future<int> pruneOldData({DateTime? before}) async {
    // Ensure all completed days are rolled up before pruning raw snapshots
    await rollupCompletedDays();

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

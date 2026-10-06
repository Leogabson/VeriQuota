import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veriquota/data/local/app_database.dart';
import 'package:veriquota/data/models/usage_record.dart';
import 'package:veriquota/data/repository/usage_repository.dart';

void main() {
  // Initialize FFI for desktop/VM test environment
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late AppDatabase appDatabase;
  late UsageRepository repository;

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: AppDatabase.databaseVersion,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE ${AppDatabase.tableUsageSnapshots} (
              ${AppDatabase.colId} INTEGER PRIMARY KEY AUTOINCREMENT,
              ${AppDatabase.colPackageName} TEXT NOT NULL,
              ${AppDatabase.colRxBytes} INTEGER NOT NULL,
              ${AppDatabase.colTxBytes} INTEGER NOT NULL,
              ${AppDatabase.colTimestamp} INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE ${AppDatabase.tableDailyAggregates} (
              ${AppDatabase.colDailyDate} TEXT NOT NULL,
              ${AppDatabase.colPackageName} TEXT NOT NULL,
              ${AppDatabase.colRxBytes} INTEGER NOT NULL,
              ${AppDatabase.colTxBytes} INTEGER NOT NULL,
              ${AppDatabase.colDailyTotalBytes} INTEGER NOT NULL,
              PRIMARY KEY (${AppDatabase.colDailyDate}, ${AppDatabase.colPackageName})
            )
          ''');
        },
      ),
    );

    appDatabase = AppDatabase(database: db);
    repository = UsageRepository(
      appDatabase: appDatabase,
      autoStart: false,
    );
  });

  tearDown(() async {
    repository.dispose();
    await db.close();
  });

  test('insertRecords and getUsageToday aggregates usage correctly', () async {
    final now = DateTime.now();

    await repository.insertRecords([
      UsageRecord(
        packageName: 'com.android.chrome',
        rxBytes: 1000,
        txBytes: 200,
        timestamp: now,
      ),
      UsageRecord(
        packageName: 'com.android.chrome',
        rxBytes: 500,
        txBytes: 100,
        timestamp: now.subtract(const Duration(minutes: 5)),
      ),
      UsageRecord(
        packageName: 'com.google.android.youtube',
        rxBytes: 5000,
        txBytes: 500,
        timestamp: now,
      ),
    ]);

    final todayUsage = await repository.getUsageToday();

    expect(todayUsage.length, 2);
    // YouTube should rank first (5500 total > 1800 total)
    expect(todayUsage[0].packageName, 'com.google.android.youtube');
    expect(todayUsage[0].totalBytes, 5500);

    expect(todayUsage[1].packageName, 'com.android.chrome');
    expect(todayUsage[1].rxBytes, 1500);
    expect(todayUsage[1].txBytes, 300);
    expect(todayUsage[1].totalBytes, 1800);
  });

  test('getUsageThisWeek aggregates only current week records', () async {
    final now = DateTime.now();
    final twoWeeksAgo = now.subtract(const Duration(days: 14));

    await repository.insertRecords([
      UsageRecord(
        packageName: 'com.whatsapp',
        rxBytes: 2000,
        txBytes: 1000,
        timestamp: now,
      ),
      UsageRecord(
        packageName: 'com.whatsapp',
        rxBytes: 8000,
        txBytes: 4000,
        timestamp: twoWeeksAgo,
      ),
    ]);

    final thisWeekUsage = await repository.getUsageThisWeek();

    expect(thisWeekUsage.length, 1);
    expect(thisWeekUsage.first.packageName, 'com.whatsapp');
    expect(thisWeekUsage.first.totalBytes, 3000);
  });

  test('getUsageForApp queries usage for single package within date range', () async {
    final now = DateTime.now();

    await repository.insertRecords([
      UsageRecord(
        packageName: 'com.spotify.music',
        rxBytes: 4000,
        txBytes: 200,
        timestamp: now.subtract(const Duration(hours: 1)),
      ),
      UsageRecord(
        packageName: 'com.spotify.music',
        rxBytes: 6000,
        txBytes: 300,
        timestamp: now.subtract(const Duration(hours: 2)),
      ),
      UsageRecord(
        packageName: 'com.other.app',
        rxBytes: 9999,
        txBytes: 9999,
        timestamp: now,
      ),
    ]);

    final spotifyUsage = await repository.getUsageForApp(
      'com.spotify.music',
      start: now.subtract(const Duration(hours: 3)),
      end: now,
    );

    expect(spotifyUsage, isNotNull);
    expect(spotifyUsage!.packageName, 'com.spotify.music');
    expect(spotifyUsage.rxBytes, 10000);
    expect(spotifyUsage.txBytes, 500);
    expect(spotifyUsage.totalBytes, 10500);

    final nonExistent = await repository.getUsageForApp('com.nonexistent.app');
    expect(nonExistent, isNull);
  });

  test('getTopAppsByUsage respects limit and date range', () async {
    final now = DateTime.now();
    final range = DateTimeRange(
      start: now.subtract(const Duration(hours: 1)),
      end: now.add(const Duration(hours: 1)),
    );

    await repository.insertRecords([
      UsageRecord(packageName: 'app.one', rxBytes: 100, txBytes: 0, timestamp: now),
      UsageRecord(packageName: 'app.two', rxBytes: 300, txBytes: 0, timestamp: now),
      UsageRecord(packageName: 'app.three', rxBytes: 500, txBytes: 0, timestamp: now),
      UsageRecord(packageName: 'app.four', rxBytes: 200, txBytes: 0, timestamp: now),
    ]);

    final top2 = await repository.getTopAppsByUsage(range: range, limit: 2);

    expect(top2.length, 2);
    expect(top2[0].packageName, 'app.three'); // 500 bytes
    expect(top2[1].packageName, 'app.two'); // 300 bytes
  });

  test('pruneOldData removes records older than 30 days', () async {
    final now = DateTime.now();
    final fortyDaysAgo = now.subtract(const Duration(days: 40));
    final tenDaysAgo = now.subtract(const Duration(days: 10));

    await repository.insertRecords([
      UsageRecord(packageName: 'stale.app', rxBytes: 100, txBytes: 0, timestamp: fortyDaysAgo),
      UsageRecord(packageName: 'fresh.app', rxBytes: 100, txBytes: 0, timestamp: tenDaysAgo),
    ]);

    final prunedCount = await repository.pruneOldData();
    expect(prunedCount, 1);

    final stale = await repository.getUsageForApp('stale.app');
    expect(stale, isNull);

    final fresh = await repository.getUsageForApp('fresh.app');
    expect(fresh, isNotNull);
  });

  test(
      'record timestamped at 23:59 yesterday does NOT appear in getUsageToday() but DOES appear in getUsageThisWeek() and getUsageForApp()',
      () async {
    // Anchor reference time: if run on a Monday, yesterday was Sunday (previous week).
    // Use an explicit anchor (Wednesday) to guarantee deterministic week containment in CI,
    // while also validating against real DateTime.now() on any non-Monday day.
    final bool isMonday = DateTime.now().weekday == DateTime.monday;
    final now = isMonday
        ? DateTime(2026, 10, 7, 14, 30, 0) // Wednesday 14:30:00 local time
        : DateTime.now();

    final yesterday = now.subtract(const Duration(days: 1));
    final yesterday2359 = DateTime(
      yesterday.year,
      yesterday.month,
      yesterday.day,
      23,
      59,
      0,
    );

    // Insert a record for an app at 23:59 yesterday
    await repository.insertRecord(
      UsageRecord(
        packageName: 'com.yesterday.app',
        rxBytes: 50000,
        txBytes: 25000,
        timestamp: yesterday2359,
      ),
    );

    // Also insert a record for a different app today (before or at now)
    final todayRecordTime = now;
    await repository.insertRecord(
      UsageRecord(
        packageName: 'com.today.app',
        rxBytes: 12000,
        txBytes: 3000,
        timestamp: todayRecordTime,
      ),
    );

    // 1. Verify getUsageToday():
    // The record from 23:59 yesterday must NOT appear in today's usage.
    final todayUsage = await repository.getUsageToday(now: now);
    final yesterdayInToday =
        todayUsage.where((e) => e.packageName == 'com.yesterday.app');
    expect(yesterdayInToday, isEmpty);

    final todayInToday =
        todayUsage.where((e) => e.packageName == 'com.today.app');
    expect(todayInToday, isNotEmpty);
    expect(todayInToday.first.totalBytes, 15000);

    // 2. Verify getUsageThisWeek():
    // The record from 23:59 yesterday MUST appear in this week's usage.
    final thisWeekUsage = await repository.getUsageThisWeek(now: now);
    final yesterdayInThisWeek =
        thisWeekUsage.where((e) => e.packageName == 'com.yesterday.app');
    expect(yesterdayInThisWeek, isNotEmpty);
    expect(yesterdayInThisWeek.first.totalBytes, 75000);

    // 3. Verify getUsageForApp() with an explicit date range covering yesterday:
    final startOfYesterday =
        DateTime(yesterday.year, yesterday.month, yesterday.day, 0, 0, 0);
    final endOfYesterday =
        DateTime(yesterday.year, yesterday.month, yesterday.day, 23, 59, 59);

    final yesterdayAppUsage = await repository.getUsageForApp(
      'com.yesterday.app',
      start: startOfYesterday,
      end: endOfYesterday,
    );
    expect(yesterdayAppUsage, isNotNull);
    expect(yesterdayAppUsage!.packageName, 'com.yesterday.app');
    expect(yesterdayAppUsage.totalBytes, 75000);
    expect(yesterdayAppUsage.rxBytes, 50000);
    expect(yesterdayAppUsage.txBytes, 25000);

    // Also verify default parameter call if not Monday
    if (!isMonday) {
      final realToday = await repository.getUsageToday();
      expect(realToday.any((e) => e.packageName == 'com.yesterday.app'), isFalse);

      final realWeek = await repository.getUsageThisWeek();
      expect(realWeek.any((e) => e.packageName == 'com.yesterday.app'), isTrue);
    }
  });

  test(
      'usage recorded on Tuesday and Wednesday accumulates in getUsageThisWeek() when queried on Thursday',
      () async {
    // Choose a deterministic week: Monday Oct 5 to Sunday Oct 11, 2026
    final tuesday = DateTime(2026, 10, 6, 14, 0, 0);
    final wednesday = DateTime(2026, 10, 7, 16, 0, 0);
    final thursday = DateTime(2026, 10, 8, 11, 0, 0);

    // Insert Tuesday snapshots
    await repository.insertRecords([
      UsageRecord(packageName: 'app.alpha', rxBytes: 8000, txBytes: 2000, timestamp: tuesday),
      UsageRecord(packageName: 'app.beta', rxBytes: 5000, txBytes: 1000, timestamp: tuesday),
    ]);

    // Insert Wednesday snapshots
    await repository.insertRecords([
      UsageRecord(packageName: 'app.alpha', rxBytes: 4000, txBytes: 1000, timestamp: wednesday),
      UsageRecord(packageName: 'app.gamma', rxBytes: 15000, txBytes: 5000, timestamp: wednesday),
    ]);

    // Insert Thursday snapshot (live today data)
    await repository.insertRecords([
      UsageRecord(packageName: 'app.beta', rxBytes: 3000, txBytes: 1000, timestamp: thursday),
    ]);

    // Query on Thursday
    final thisWeekUsage = await repository.getUsageThisWeek(now: thursday);

    // Verify all 3 apps are included and their usage accumulated:
    // app.gamma: 20,000 bytes (from Wednesday)
    // app.alpha: 10,000 (Tue) + 5,000 (Wed) = 15,000 bytes
    // app.beta: 6,000 (Tue) + 4,000 (Thu) = 10,000 bytes
    expect(thisWeekUsage.length, 3);

    final gamma = thisWeekUsage.firstWhere((a) => a.packageName == 'app.gamma');
    expect(gamma.totalBytes, 20000);

    final alpha = thisWeekUsage.firstWhere((a) => a.packageName == 'app.alpha');
    expect(alpha.totalBytes, 15000);

    final beta = thisWeekUsage.firstWhere((a) => a.packageName == 'app.beta');
    expect(beta.totalBytes, 10000);
  });

  test('getUsageAllTime() total is unaffected by raw snapshot pruning', () async {
    final now = DateTime(2026, 10, 8, 12, 0, 0);
    final twentyDaysAgo = now.subtract(const Duration(days: 20));

    // Insert raw snapshot older than retention (14 days)
    await repository.insertRecord(
      UsageRecord(
        packageName: 'legacy.app',
        rxBytes: 500000,
        txBytes: 100000,
        timestamp: twentyDaysAgo,
      ),
    );

    // Insert raw snapshot today
    await repository.insertRecord(
      UsageRecord(
        packageName: 'active.app',
        rxBytes: 20000,
        txBytes: 5000,
        timestamp: now,
      ),
    );

    // 1. Roll up completed days into permanent daily aggregates
    await repository.rollupCompletedDays(now: now);

    // 2. Prune raw snapshots older than 14 days
    final pruned = await repository.pruneOldData(before: now.subtract(const Duration(days: 14)));
    expect(pruned, greaterThanOrEqualTo(1));

    // 3. Confirm raw table no longer has the 20-day-old record
    final rawLegacy = await repository.getUsageForApp(
      'legacy.app',
      start: twentyDaysAgo.subtract(const Duration(hours: 1)),
      end: twentyDaysAgo.add(const Duration(hours: 1)),
    );
    expect(rawLegacy, isNull);

    // 4. Confirm getUsageAllTime() STILL includes legacy.app with full usage!
    final allTime = await repository.getUsageAllTime(now: now);
    final legacyInAllTime = allTime.firstWhere((a) => a.packageName == 'legacy.app');
    expect(legacyInAllTime, isNotNull);
    expect(legacyInAllTime.totalBytes, 600000);

    final activeInAllTime = allTime.firstWhere((a) => a.packageName == 'active.app');
    expect(activeInAllTime, isNotNull);
    expect(activeInAllTime.totalBytes, 25000);
  });

  test('getDailyHistory and getWeeklyHistory return structured history with real dates', () async {
    final now = DateTime(2026, 10, 8, 12, 0, 0);
    final yesterday = now.subtract(const Duration(days: 1));

    await repository.insertRecord(
      UsageRecord(packageName: 'app.history', rxBytes: 1000, txBytes: 500, timestamp: yesterday),
    );
    await repository.insertRecord(
      UsageRecord(packageName: 'app.history', rxBytes: 2000, txBytes: 500, timestamp: now),
    );

    final dailyHistory = await repository.getDailyHistory(days: 7, now: now);
    expect(dailyHistory.length, greaterThanOrEqualTo(2));
    expect(dailyHistory.first.date, UsageRepository.formatDate(now));
    expect(dailyHistory.first.totalBytes, 2500);

    final weeklyHistory = await repository.getWeeklyHistory(weeks: 4, now: now);
    expect(weeklyHistory, isNotEmpty);
    expect(weeklyHistory.first.totalBytes, greaterThanOrEqualTo(4000));
  });
}

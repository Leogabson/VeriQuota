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
}

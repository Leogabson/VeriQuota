import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Database manager for VeriQuota local storage.
class AppDatabase {
  static const String databaseName = 'veriquota.db';
  static const int databaseVersion = 2;

  // Raw per-minute snapshots table
  static const String tableUsageSnapshots = 'usage_snapshots';
  static const String colId = 'id';
  static const String colPackageName = 'packageName';
  static const String colRxBytes = 'rxBytes';
  static const String colTxBytes = 'txBytes';
  static const String colTimestamp = 'timestamp';

  // Permanent daily aggregates table
  static const String tableDailyAggregates = 'daily_usage_aggregates';
  static const String colDailyDate = 'date';
  static const String colDailyTotalBytes = 'totalBytes';

  // Singleton instance
  static final AppDatabase instance = AppDatabase._internal();

  AppDatabase._internal() : customPath = null;

  Database? _db;
  final String? customPath;

  /// Creates an AppDatabase instance, optionally with an in-memory or custom database for testing.
  AppDatabase({Database? database, this.customPath}) : _db = database;

  Future<Database> get database async {
    if (_db != null && _db!.isOpen) {
      return _db!;
    }
    _db = await _initDatabase();
    return _db!;
  }

  Future<Database> _initDatabase() async {
    final String path;
    if (customPath != null) {
      path = customPath!;
    } else {
      final dbFolder = await getDatabasesPath();
      path = p.join(dbFolder, databaseName);
    }

    return await openDatabase(
      path,
      version: databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $tableUsageSnapshots (
        $colId INTEGER PRIMARY KEY AUTOINCREMENT,
        $colPackageName TEXT NOT NULL,
        $colRxBytes INTEGER NOT NULL,
        $colTxBytes INTEGER NOT NULL,
        $colTimestamp INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_usage_timestamp ON $tableUsageSnapshots($colTimestamp)
    ''');

    await db.execute('''
      CREATE INDEX idx_usage_package_timestamp ON $tableUsageSnapshots($colPackageName, $colTimestamp)
    ''');

    await _createDailyAggregatesTable(db);
  }

  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createDailyAggregatesTable(db);
    }
  }

  static Future<void> _createDailyAggregatesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableDailyAggregates (
        $colDailyDate TEXT NOT NULL,
        $colPackageName TEXT NOT NULL,
        $colRxBytes INTEGER NOT NULL,
        $colTxBytes INTEGER NOT NULL,
        $colDailyTotalBytes INTEGER NOT NULL,
        PRIMARY KEY ($colDailyDate, $colPackageName)
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_daily_date ON $tableDailyAggregates($colDailyDate)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_daily_package ON $tableDailyAggregates($colPackageName)
    ''');
  }

  Future<void> close() async {
    if (_db != null && _db!.isOpen) {
      await _db!.close();
      _db = null;
    }
  }
}

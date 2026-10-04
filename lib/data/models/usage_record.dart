import '../../features/vpn_native/models/app_usage_entry.dart';

/// Database entity representing a periodic data usage snapshot for an application.
class UsageRecord {
  final int? id;
  final String packageName;
  final int rxBytes;
  final int txBytes;
  final DateTime timestamp;

  const UsageRecord({
    this.id,
    required this.packageName,
    required this.rxBytes,
    required this.txBytes,
    required this.timestamp,
  });

  int get totalBytes => rxBytes + txBytes;

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'packageName': packageName,
      'rxBytes': rxBytes,
      'txBytes': txBytes,
      'timestamp': timestamp.millisecondsSinceEpoch,
    };
  }

  factory UsageRecord.fromMap(Map<String, dynamic> map) {
    final timestampMillis = (map['timestamp'] as num?)?.toInt() ?? 0;
    return UsageRecord(
      id: map['id'] as int?,
      packageName: map['packageName'] as String? ?? 'unknown',
      rxBytes: (map['rxBytes'] as num?)?.toInt() ?? 0,
      txBytes: (map['txBytes'] as num?)?.toInt() ?? 0,
      timestamp: timestampMillis > 0
          ? DateTime.fromMillisecondsSinceEpoch(timestampMillis)
          : DateTime.now(),
    );
  }

  AppUsageEntry toAppUsageEntry() {
    return AppUsageEntry(
      packageName: packageName,
      rxBytes: rxBytes,
      txBytes: txBytes,
      totalBytes: totalBytes,
      lastUpdated: timestamp,
    );
  }

  @override
  String toString() {
    return 'UsageRecord(id=$id, $packageName: Rx=$rxBytes, Tx=$txBytes, Time=$timestamp)';
  }
}

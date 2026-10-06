/// Database entity representing a permanent daily usage aggregate for an application.
/// One row per app per calendar day. Never pruned.
class DailyAggregateRecord {
  final String date; // YYYY-MM-DD in local time
  final String packageName;
  final int rxBytes;
  final int txBytes;
  final int totalBytes;

  const DailyAggregateRecord({
    required this.date,
    required this.packageName,
    required this.rxBytes,
    required this.txBytes,
    required this.totalBytes,
  });

  Map<String, dynamic> toMap() {
    return {
      'date': date,
      'packageName': packageName,
      'rxBytes': rxBytes,
      'txBytes': txBytes,
      'totalBytes': totalBytes,
    };
  }

  factory DailyAggregateRecord.fromMap(Map<String, dynamic> map) {
    final rx = (map['rxBytes'] as num?)?.toInt() ?? 0;
    final tx = (map['txBytes'] as num?)?.toInt() ?? 0;
    final total = (map['totalBytes'] as num?)?.toInt() ?? (rx + tx);

    return DailyAggregateRecord(
      date: map['date'] as String? ?? '',
      packageName: map['packageName'] as String? ?? '',
      rxBytes: rx,
      txBytes: tx,
      totalBytes: total,
    );
  }

  @override
  String toString() {
    return 'DailyAggregateRecord($date, $packageName: Total=$totalBytes, Rx=$rxBytes, Tx=$txBytes)';
  }
}

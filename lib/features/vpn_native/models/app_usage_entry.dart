/// Model representing data usage statistics for an application.
class AppUsageEntry {
  final String packageName;
  final int rxBytes; // Received bytes
  final int txBytes; // Transmitted bytes
  final int totalBytes;
  final DateTime lastUpdated;

  const AppUsageEntry({
    required this.packageName,
    required this.rxBytes,
    required this.txBytes,
    required this.totalBytes,
    required this.lastUpdated,
  });

  factory AppUsageEntry.fromMap(Map<dynamic, dynamic> map) {
    final rx = (map['rxBytes'] as num?)?.toInt() ?? 0;
    final tx = (map['txBytes'] as num?)?.toInt() ?? 0;
    final total = (map['totalBytes'] as num?)?.toInt() ?? (rx + tx);
    final timestamp = (map['lastUpdated'] as num?)?.toInt() ?? 0;

    return AppUsageEntry(
      packageName: map['packageName'] as String? ?? 'unknown',
      rxBytes: rx,
      txBytes: tx,
      totalBytes: total,
      lastUpdated: timestamp > 0
          ? DateTime.fromMillisecondsSinceEpoch(timestamp)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'packageName': packageName,
      'rxBytes': rxBytes,
      'txBytes': txBytes,
      'totalBytes': totalBytes,
      'lastUpdated': lastUpdated.millisecondsSinceEpoch,
    };
  }

  String get humanReadableTotal => formatBytes(totalBytes);
  String get humanReadableRx => formatBytes(rxBytes);
  String get humanReadableTx => formatBytes(txBytes);

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  String toString() {
    return 'AppUsageEntry($packageName: Rx=$humanReadableRx, Tx=$humanReadableTx, Total=$humanReadableTotal)';
  }
}

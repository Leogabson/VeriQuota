import '../../features/vpn_native/models/app_usage_entry.dart';

/// Data structure representing aggregate usage for an entire calendar day.
class DailyHistoryEntry {
  final String date; // YYYY-MM-DD
  final DateTime dateTime;
  final int totalBytes;
  final int rxBytes;
  final int txBytes;

  const DailyHistoryEntry({
    required this.date,
    required this.dateTime,
    required this.totalBytes,
    this.rxBytes = 0,
    this.txBytes = 0,
  });

  String get formattedTotal => AppUsageEntry.formatBytes(totalBytes);

  /// Human-readable date label, e.g. "5 October 2026"
  String get formattedDate {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return '${dateTime.day} ${months[dateTime.month - 1]} ${dateTime.year}';
  }

  Map<String, dynamic> toMap() {
    return {
      'date': date,
      'totalBytes': totalBytes,
      'rxBytes': rxBytes,
      'txBytes': txBytes,
    };
  }
}

/// Data structure representing aggregate usage for a calendar week.
class WeeklyHistoryEntry {
  final DateTime weekStartDate; // Monday 00:00:00
  final DateTime weekEndDate; // Sunday 23:59:59 (or now)
  final int totalBytes;
  final int rxBytes;
  final int txBytes;

  const WeeklyHistoryEntry({
    required this.weekStartDate,
    required this.weekEndDate,
    required this.totalBytes,
    this.rxBytes = 0,
    this.txBytes = 0,
  });

  String get formattedTotal => AppUsageEntry.formatBytes(totalBytes);

  /// Formatted date range, e.g. "Week of 29 Sep – 5 Oct 2026"
  String get formattedRange {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final startDay = weekStartDate.day;
    final startMonth = months[weekStartDate.month - 1];
    final endDay = weekEndDate.day;
    final endMonth = months[weekEndDate.month - 1];
    final year = weekEndDate.year;

    if (startMonth == endMonth) {
      return 'Week of $startDay – $endDay $startMonth $year';
    } else {
      return 'Week of $startDay $startMonth – $endDay $endMonth $year';
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'weekStartDate': weekStartDate.millisecondsSinceEpoch,
      'weekEndDate': weekEndDate.millisecondsSinceEpoch,
      'totalBytes': totalBytes,
      'rxBytes': rxBytes,
      'txBytes': txBytes,
    };
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../data/repository/usage_repository.dart';
import '../../vpn_native/models/app_usage_entry.dart';
import 'dashboard_view_model.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<DashboardViewModel>(
      create: (context) => DashboardViewModel(
        usageRepository: context.read<UsageRepository>(),
      ),
      child: const _DashboardView(),
    );
  }
}

class _DashboardView extends StatelessWidget {
  const _DashboardView();

  void _openDebug(BuildContext context) {
    Navigator.of(context).pushNamed('/debug');
  }

  void _showAppDetailModal(
    BuildContext context,
    AppUsageEntry app,
    DashboardTimeRange timeRange,
  ) {
    final String rangeLabel = switch (timeRange) {
      DashboardTimeRange.today => 'Today',
      DashboardTimeRange.thisWeek => 'This Week',
      DashboardTimeRange.allTime => 'All Time',
      DashboardTimeRange.history => 'History',
    };

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.black12,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  app.packageName,
                  style: AppTextStyles.titleLarge.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Usage Breakdown · $rangeLabel',
                  style: AppTextStyles.bodyMedium,
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundOffWhite,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      _buildDetailRow('Total Measured Data', app.humanReadableTotal, isBold: true),
                      const Divider(height: 20),
                      _buildDetailRow('Received (Download / Rx)', app.humanReadableRx),
                      const SizedBox(height: 8),
                      _buildDetailRow('Transmitted (Upload / Tx)', app.humanReadableTx),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Icon(Icons.shield_outlined, size: 16, color: AppColors.secondaryGray),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Measured locally on this device. Traffic is never uploaded.',
                        style: AppTextStyles.bodyMedium.copyWith(fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }

  static Widget _buildDetailRow(String label, String value, {bool isBold = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: isBold ? AppColors.primaryNavy : AppColors.secondaryGray,
            fontWeight: isBold ? FontWeight.bold : FontWeight.w500,
            fontSize: 14,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: AppColors.primaryNavy,
            fontWeight: isBold ? FontWeight.w800 : FontWeight.w600,
            fontSize: isBold ? 16 : 14,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<DashboardViewModel>();

    return Scaffold(
      backgroundColor: AppColors.backgroundOffWhite,
      appBar: AppBar(
        title: GestureDetector(
          onLongPress: () => _openDebug(context),
          child: const Text(AppConstants.appName),
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_active_outlined),
            tooltip: 'Alerts & Settings',
            onPressed: () => Navigator.of(context).pushNamed('/alerts'),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: InkWell(
              onTap: () => viewModel.toggleVpnMonitoring(),
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: viewModel.isVpnActive
                      ? Colors.green.withValues(alpha: 0.12)
                      : Colors.grey.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: viewModel.isVpnActive ? Colors.green : Colors.grey,
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: viewModel.isVpnActive ? Colors.green : Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      viewModel.isVpnActive ? 'Active' : 'Paused',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: viewModel.isVpnActive ? Colors.green[800] : Colors.grey[800],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await viewModel.checkVpnStatus();
          await viewModel.loadHistoricalData();
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // --- Live Real-Time Session Card ---
                    _buildLiveSessionCard(viewModel),
                    const SizedBox(height: 20),
                    // --- Time-Range Filter ---
                    _buildTimeRangeSelector(context, viewModel),
                    const SizedBox(height: 12),
                    // --- Real Date / Range Subtitle ---
                    _buildDateRangeSubtitle(viewModel),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          viewModel.selectedTimeRange == DashboardTimeRange.history
                              ? 'Daily Breakdown'
                              : 'Data Usage by App',
                          style: AppTextStyles.titleLarge.copyWith(fontSize: 18),
                        ),
                        Text(
                          viewModel.selectedTimeRange == DashboardTimeRange.history
                              ? '${viewModel.dailyHistory.length} days'
                              : '${viewModel.displayedApps.length} apps',
                          style: AppTextStyles.bodyMedium,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            // --- Section Content (History vs Apps) ---
            if (viewModel.selectedTimeRange == DashboardTimeRange.history)
              _buildDailyHistorySection(context, viewModel)
            else
              _buildAppListSection(context, viewModel),
            const SliverToBoxAdapter(
              child: SizedBox(height: 24),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveSessionCard(DashboardViewModel viewModel) {
    final totalFormatted = AppUsageEntry.formatBytes(viewModel.liveSessionTotalBytes);
    final rxFormatted = AppUsageEntry.formatBytes(viewModel.liveSessionRxBytes);
    final txFormatted = AppUsageEntry.formatBytes(viewModel.liveSessionTxBytes);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.primaryNavy,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'CURRENT SESSION',
                style: TextStyle(
                  fontFamily: AppTextStyles.fontFamily,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: AppColors.surfaceWhite.withValues(alpha: 0.7),
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: viewModel.isVpnActive ? const Color(0xFF4ADE80) : Colors.grey,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    viewModel.isVpnActive ? 'Live' : 'Standby',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.surfaceWhite.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            totalFormatted,
            style: const TextStyle(
              fontFamily: AppTextStyles.fontFamily,
              fontSize: 36,
              fontWeight: FontWeight.w800,
              color: AppColors.surfaceWhite,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                '↓ $rxFormatted down',
                style: TextStyle(
                  color: AppColors.surfaceWhite.withValues(alpha: 0.85),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '•',
                style: TextStyle(color: AppColors.surfaceWhite.withValues(alpha: 0.4)),
              ),
              const SizedBox(width: 12),
              Text(
                '↑ $txFormatted up',
                style: TextStyle(
                  color: AppColors.surfaceWhite.withValues(alpha: 0.85),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTimeRangeSelector(BuildContext context, DashboardViewModel viewModel) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black12),
      ),
      child: Row(
        children: [
          _buildRangeTab(
            label: 'Today',
            range: DashboardTimeRange.today,
            viewModel: viewModel,
          ),
          _buildRangeTab(
            label: 'This Week',
            range: DashboardTimeRange.thisWeek,
            viewModel: viewModel,
          ),
          _buildRangeTab(
            label: 'All Time',
            range: DashboardTimeRange.allTime,
            viewModel: viewModel,
          ),
          _buildRangeTab(
            label: 'History',
            range: DashboardTimeRange.history,
            viewModel: viewModel,
          ),
        ],
      ),
    );
  }

  Widget _buildDateRangeSubtitle(DashboardViewModel viewModel) {
    final String label = switch (viewModel.selectedTimeRange) {
      DashboardTimeRange.today => viewModel.todayDateLabel,
      DashboardTimeRange.thisWeek => viewModel.thisWeekDateLabel,
      DashboardTimeRange.allTime => 'Permanent all-time record',
      DashboardTimeRange.history => 'Past 30 calendar days (permanent daily aggregates)',
    };

    return Row(
      children: [
        const Icon(
          Icons.calendar_today_outlined,
          size: 14,
          color: AppColors.secondaryGray,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: 'Manrope',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.secondaryGray,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDailyHistorySection(BuildContext context, DashboardViewModel viewModel) {
    if (viewModel.isLoadingHistory) {
      return const SliverToBoxAdapter(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(40.0),
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }

    final history = viewModel.dailyHistory;

    if (history.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
          child: Center(
            child: Column(
              children: [
                Icon(
                  Icons.calendar_month_outlined,
                  size: 48,
                  color: AppColors.secondaryGray.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 12),
                Text(
                  'No daily history recorded yet',
                  style: AppTextStyles.titleLarge.copyWith(fontSize: 16),
                ),
                const SizedBox(height: 6),
                Text(
                  'Permanent daily aggregates will appear here as each calendar day completes.',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final entry = history[index];
            final isToday = entry.date == UsageRepository.formatDate(DateTime.now());

            return Card(
              elevation: 0,
              color: Colors.white,
              margin: const EdgeInsets.symmetric(vertical: 4),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Colors.black12, width: 0.5),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isToday
                            ? AppColors.primaryNavy.withValues(alpha: 0.08)
                            : const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        isToday ? Icons.today : Icons.event_note,
                        size: 20,
                        color: isToday ? AppColors.primaryNavy : AppColors.secondaryGray,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                entry.formattedDate,
                                style: const TextStyle(
                                  fontFamily: 'Manrope',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primaryNavy,
                                ),
                              ),
                              if (isToday) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppColors.primaryNavy,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'Today',
                                    style: TextStyle(
                                      fontFamily: 'Manrope',
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '↓ ${AppUsageEntry.formatBytes(entry.rxBytes)}   ↑ ${AppUsageEntry.formatBytes(entry.txBytes)}',
                            style: const TextStyle(
                              fontFamily: 'Manrope',
                              fontSize: 12,
                              color: AppColors.secondaryGray,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      entry.formattedTotal,
                      style: const TextStyle(
                        fontFamily: 'Manrope',
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primaryNavy,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
          childCount: history.length,
        ),
      ),
    );
  }

  Widget _buildRangeTab({
    required String label,
    required DashboardTimeRange range,
    required DashboardViewModel viewModel,
  }) {
    final isSelected = viewModel.selectedTimeRange == range;

    return Expanded(
      child: InkWell(
        onTap: () => viewModel.setTimeRange(range),
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.primaryNavy : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: AppTextStyles.fontFamily,
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                color: isSelected ? AppColors.surfaceWhite : AppColors.secondaryGray,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAppListSection(BuildContext context, DashboardViewModel viewModel) {
    if (viewModel.isLoadingHistory) {
      return const SliverToBoxAdapter(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(40.0),
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }

    final apps = viewModel.displayedApps;

    if (apps.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
          child: Center(
            child: Column(
              children: [
                Icon(
                  Icons.data_usage_outlined,
                  size: 48,
                  color: AppColors.secondaryGray.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 12),
                Text(
                  'No recorded usage yet',
                  style: AppTextStyles.titleLarge.copyWith(fontSize: 16),
                ),
                const SizedBox(height: 6),
                Text(
                  'As you browse and use apps, your on-device\nmeasurements will appear here automatically.',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final maxBytes = viewModel.maxHistoricalUsageBytes;

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final app = apps[index];
            final fraction = (app.totalBytes / maxBytes).clamp(0.02, 1.0);

            return Card(
              elevation: 0,
              color: Colors.white,
              margin: const EdgeInsets.symmetric(vertical: 4),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Colors.black12, width: 0.5),
              ),
              child: InkWell(
                onTap: () => _showAppDetailModal(context, app, viewModel.selectedTimeRange),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              app.packageName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color: AppColors.primaryNavy,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            app.humanReadableTotal,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                              color: AppColors.primaryNavy,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Visual relative progress bar
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: Stack(
                          children: [
                            Container(
                              height: 6,
                              color: const Color(0xFFE5E7EB),
                            ),
                            FractionallySizedBox(
                              widthFactor: fraction,
                              child: Container(
                                height: 6,
                                decoration: BoxDecoration(
                                  color: AppColors.primaryNavy,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Rx: ${app.humanReadableRx}  •  Tx: ${app.humanReadableTx}',
                        style: AppTextStyles.bodyMedium.copyWith(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
          childCount: apps.length,
        ),
      ),
    );
  }
}

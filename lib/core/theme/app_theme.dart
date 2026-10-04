import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_text_styles.dart';

abstract final class AppTheme {
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      fontFamily: AppTextStyles.fontFamily,
      scaffoldBackgroundColor: AppColors.backgroundOffWhite,
      colorScheme: const ColorScheme(
        brightness: Brightness.light,
        primary: AppColors.primaryNavy,
        onPrimary: AppColors.surfaceWhite,
        secondary: AppColors.secondaryGray,
        onSecondary: AppColors.surfaceWhite,
        error: AppColors.alertAccent,
        onError: AppColors.surfaceWhite,
        surface: AppColors.backgroundOffWhite,
        onSurface: AppColors.primaryNavy,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.backgroundOffWhite,
        foregroundColor: AppColors.primaryNavy,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: AppTextStyles.fontFamily,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: AppColors.primaryNavy,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primaryNavy,
          foregroundColor: AppColors.surfaceWhite,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: AppTextStyles.labelLarge,
        ),
      ),
    );
  }
}

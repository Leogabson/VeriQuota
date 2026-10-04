import 'package:flutter/material.dart';

/// Locked brand colors for VeriQuota.
abstract final class AppColors {
  /// Primary / navy (#0F1E33) - dominant color, wordmark, app icon background.
  static const Color primaryNavy = Color(0xFF0F1E33);

  /// Background / off-white (#F5F4F1) - institutional, paper-like calm surface.
  static const Color backgroundOffWhite = Color(0xFFF5F4F1);

  /// Secondary text / gray (#6B7280) - supporting text and captions.
  static const Color secondaryGray = Color(0xFF6B7280);

  /// Alert accent (#E4572E) - reserved ONLY for warnings, alerts, and high-urgency states.
  static const Color alertAccent = Color(0xFFE4572E);

  /// Surface white for elevated cards and button text on dark surfaces.
  static const Color surfaceWhite = Color(0xFFFFFFFF);
}

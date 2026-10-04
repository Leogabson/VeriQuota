package com.veriquota.app.vpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import com.veriquota.app.MainActivity
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Manages threshold-based alerting directly within the native layer.
 * Operates independently of Flutter engine lifecycle so alerts trigger
 * reliably even when the app is backgrounded or detached.
 */
object AlertManager {

    private const val TAG = "VeriQuotaAlertManager"
    const val ALERT_CHANNEL_ID = "veriquota_alerts_channel"
    private const val PREFS_NAME = "veriquota_alert_prefs"

    private const val KEY_ENABLED = "alert_enabled"
    private const val KEY_THRESHOLD_BYTES = "alert_threshold_bytes"
    private const val KEY_WINDOW_MINUTES = "alert_window_minutes"

    // 15-minute cooldown per app to prevent alert spam
    private const val ALERT_COOLDOWN_MS = 15 * 60 * 1000L

    private var appContext: Context? = null

    // In-memory cached configuration for zero-overhead evaluation in packet loop
    private val isEnabledState = AtomicBoolean(false)
    private val thresholdBytesState = AtomicLong(50L * 1024 * 1024) // Default 50 MB
    private val windowMinutesState = AtomicInteger(15) // Default 15 minutes

    // Cooldown tracker: packageName -> timestamp of last notification
    private val lastAlertTimestamps = ConcurrentHashMap<String, Long>()

    val isEnabled: Boolean get() = isEnabledState.get()
    val thresholdBytes: Long get() = thresholdBytesState.get()
    val windowMinutes: Int get() = windowMinutesState.get()

    fun init(context: Context) {
        val app = context.applicationContext
        appContext = app
        loadPreferences(app)
        createNotificationChannel(app)
    }

    fun createNotificationChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                ALERT_CHANNEL_ID,
                "VeriQuota Data Alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "High data usage alerts for background and foreground apps"
                enableVibration(true)
                setShowBadge(true)
            }
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            manager?.createNotificationChannel(channel)
        }
    }

    private fun loadPreferences(context: Context) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val enabled = prefs.getBoolean(KEY_ENABLED, false)
        val threshold = prefs.getLong(KEY_THRESHOLD_BYTES, 50L * 1024 * 1024)
        val window = prefs.getInt(KEY_WINDOW_MINUTES, 15)

        isEnabledState.set(enabled)
        thresholdBytesState.set(threshold)
        windowMinutesState.set(window)

        Log.d(TAG, "Loaded alert config: enabled=$enabled, thresholdBytes=$threshold, windowMinutes=$window")
    }

    fun setAlertThreshold(context: Context, enabled: Boolean, thresholdBytes: Long, windowMinutes: Int) {
        val app = context.applicationContext
        appContext = app

        isEnabledState.set(enabled)
        thresholdBytesState.set(thresholdBytes)
        windowMinutesState.set(windowMinutes)

        val prefs = app.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit()
            .putBoolean(KEY_ENABLED, enabled)
            .putLong(KEY_THRESHOLD_BYTES, thresholdBytes)
            .putInt(KEY_WINDOW_MINUTES, windowMinutes)
            .apply()

        // Clear cooldown when config changes so new rules apply immediately
        lastAlertTimestamps.clear()
        Log.i(TAG, "Updated alert config: enabled=$enabled, thresholdBytes=$thresholdBytes, windowMinutes=$windowMinutes")
    }

    fun getAlertThreshold(context: Context): Map<String, Any> {
        val app = context.applicationContext
        loadPreferences(app)
        return mapOf(
            "enabled" to isEnabledState.get(),
            "thresholdBytes" to thresholdBytesState.get(),
            "windowMinutes" to windowMinutesState.get()
        )
    }

    /**
     * Evaluates whether the given app crossed the threshold within the configured window.
     * Called by TrafficAggregator on packet arrival.
     */
    fun checkThreshold(packageName: String, currentTimestamp: Long) {
        if (!isEnabledState.get()) return

        val threshold = thresholdBytesState.get()
        if (threshold <= 0) return

        val window = windowMinutesState.get()
        if (window <= 0) return

        // 1. Check cooldown (15 minutes per app)
        val lastAlert = lastAlertTimestamps[packageName] ?: 0L
        if (currentTimestamp - lastAlert < ALERT_COOLDOWN_MS) {
            return
        }

        // 2. Query usage for the rolling window
        val startMillis = currentTimestamp - (window.toLong() * 60_000L)
        val snapshot = TrafficAggregator.getTimeRangeUsage(packageName, startMillis, currentTimestamp)
        val totalBytes = snapshot.totalBytes

        if (totalBytes >= threshold) {
            // Trigger alert notification
            lastAlertTimestamps[packageName] = currentTimestamp
            triggerNotification(packageName, totalBytes, window)
        }
    }

    private fun triggerNotification(packageName: String, totalBytes: Long, windowMinutes: Int) {
        val context = appContext ?: return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return

        val appLabel = resolveAppLabel(context, packageName)
        val formattedUsage = formatBytesToMb(totalBytes)

        val title = "High Data Usage Alert"
        val message = "$appLabel used ${formattedUsage}MB in the last $windowMinutes minutes."

        val launchIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }

        val pendingIntent = PendingIntent.getActivity(
            context,
            packageName.hashCode(),
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val iconRes = context.applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.stat_notify_error

        val notification = NotificationCompat.Builder(context, ALERT_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(message)
            .setStyle(NotificationCompat.BigTextStyle().bigText(message))
            .setSmallIcon(iconRes)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()

        // Distinct ID per app so notifications don't overwrite other apps' alerts
        val notificationId = 20000 + (packageName.hashCode() and 0x7FFF)
        manager.notify(notificationId, notification)
        Log.i(TAG, "Triggered data alert for $packageName: $message (Notification ID: $notificationId)")
    }

    private fun resolveAppLabel(context: Context, packageName: String): String {
        if (packageName.startsWith("uid.") || packageName.contains("(UID")) {
            return packageName
        }
        return try {
            val pm = context.packageManager
            val appInfo = pm.getApplicationInfo(packageName, 0)
            pm.getApplicationLabel(appInfo).toString()
        } catch (e: Exception) {
            packageName
        }
    }

    private fun formatBytesToMb(bytes: Long): String {
        val mb = bytes.toDouble() / (1024.0 * 1024.0)
        return if (mb < 10.0) {
            String.format(java.util.Locale.US, "%.1f", mb)
        } else {
            mb.toLong().toString()
        }
    }
}

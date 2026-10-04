package com.veriquota.app

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.veriquota.app.vpn.AlertManager
import com.veriquota.app.vpn.TrafficAggregator
import com.veriquota.app.vpn.VeriQuotaVpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val METHOD_CHANNEL = "com.veriquota.app/vpn_control"
        private const val EVENT_CHANNEL = "com.veriquota.app/vpn_events"
        private const val VPN_REQUEST_CODE = 2001
        private const val NOTIFICATION_REQUEST_CODE = 2002
    }

    private var pendingVpnResult: MethodChannel.Result? = null
    private var pendingNotificationResult: MethodChannel.Result? = null
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var streamRunnable: Runnable? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize native alert manager
        AlertManager.init(this)

        // 1. MethodChannel for commands
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startVpnMonitoring" -> handleStartVpn(result)
                    "stopVpnMonitoring" -> handleStopVpn(result)
                    "getCurrentUsage" -> handleGetCurrentUsage(result)
                    "getTimeRangeUsage" -> handleGetTimeRangeUsage(call, result)
                    "isVpnRunning" -> result.success(VeriQuotaVpnService.isVpnActive)
                    "setAlertThreshold" -> handleSetAlertThreshold(call, result)
                    "getAlertThreshold" -> handleGetAlertThreshold(result)
                    "requestNotificationPermission" -> handleRequestNotificationPermission(result)
                    "areNotificationsEnabled" -> handleAreNotificationsEnabled(result)
                    else -> result.notImplemented()
                }
            }

        // 2. EventChannel for live updates
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    startLiveStream()
                }

                override fun onCancel(arguments: Any?) {
                    stopLiveStream()
                    eventSink = null
                }
            })
    }

    private fun handleStartVpn(result: MethodChannel.Result) {
        val prepareIntent = VpnService.prepare(this)
        if (prepareIntent != null) {
            pendingVpnResult = result
            startActivityForResult(prepareIntent, VPN_REQUEST_CODE)
        } else {
            // Already prepared, start service immediately
            startVpnService()
            result.success(true)
        }
    }

    private fun handleStopVpn(result: MethodChannel.Result) {
        val stopIntent = Intent(this, VeriQuotaVpnService::class.java).apply {
            action = VeriQuotaVpnService.ACTION_STOP
        }
        startService(stopIntent)
        result.success(true)
    }

    private fun handleGetCurrentUsage(result: MethodChannel.Result) {
        val snapshot = TrafficAggregator.getCurrentUsageSnapshot().map { it.toMap() }
        result.success(snapshot)
    }

    private fun handleGetTimeRangeUsage(call: MethodCall, result: MethodChannel.Result) {
        val startMillis = (call.argument<Number>("startMillis"))?.toLong() ?: 0L
        val endMillis = (call.argument<Number>("endMillis"))?.toLong() ?: System.currentTimeMillis()
        val packageName = call.argument<String>("packageName")

        if (packageName != null) {
            val usage = TrafficAggregator.getTimeRangeUsage(packageName, startMillis, endMillis)
            result.success(usage.toMap())
        } else {
            val list = TrafficAggregator.getAllTimeRangeUsage(startMillis, endMillis).map { it.toMap() }
            result.success(list)
        }
    }

    private fun startVpnService() {
        val startIntent = Intent(this, VeriQuotaVpnService::class.java).apply {
            action = VeriQuotaVpnService.ACTION_START
        }
        startService(startIntent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK) {
                startVpnService()
                pendingVpnResult?.success(true)
            } else {
                pendingVpnResult?.success(false)
            }
            pendingVpnResult = null
        }
    }

    private fun startLiveStream() {
        stopLiveStream()
        streamRunnable = object : Runnable {
            override fun run() {
                val snapshot = TrafficAggregator.getCurrentUsageSnapshot().map { it.toMap() }
                eventSink?.success(snapshot)
                mainHandler.postDelayed(this, 2000L) // Emit every 2 seconds
            }
        }
        mainHandler.post(streamRunnable!!)
    }

    private fun stopLiveStream() {
        streamRunnable?.let { mainHandler.removeCallbacks(it) }
        streamRunnable = null
    }

    private fun handleSetAlertThreshold(call: MethodCall, result: MethodChannel.Result) {
        val enabled = call.argument<Boolean>("enabled") ?: false
        val thresholdBytes = (call.argument<Number>("thresholdBytes"))?.toLong() ?: (50L * 1024 * 1024)
        val windowMinutes = (call.argument<Number>("windowMinutes"))?.toInt() ?: 15
        AlertManager.setAlertThreshold(this, enabled, thresholdBytes, windowMinutes)
        result.success(true)
    }

    private fun handleGetAlertThreshold(result: MethodChannel.Result) {
        val config = AlertManager.getAlertThreshold(this)
        result.success(config)
    }

    private fun handleRequestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
                result.success(true)
            } else {
                pendingNotificationResult = result
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    NOTIFICATION_REQUEST_CODE
                )
            }
        } else {
            val enabled = NotificationManagerCompat.from(this).areNotificationsEnabled()
            result.success(enabled)
        }
    }

    private fun handleAreNotificationsEnabled(result: MethodChannel.Result) {
        val enabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        } else {
            NotificationManagerCompat.from(this).areNotificationsEnabled()
        }
        result.success(enabled)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == NOTIFICATION_REQUEST_CODE) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingNotificationResult?.success(granted)
            pendingNotificationResult = null
        }
    }

    override fun onDestroy() {
        stopLiveStream()
        super.onDestroy()
    }
}

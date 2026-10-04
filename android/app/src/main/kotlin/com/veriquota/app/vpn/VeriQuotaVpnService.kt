package com.veriquota.app.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import com.veriquota.app.MainActivity
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

class VeriQuotaVpnService : VpnService() {

    private val TAG = "VeriQuotaVpnService"
    private var vpnInterface: ParcelFileDescriptor? = null
    private var tunWriter: TunWriter? = null
    private var tcpRelay: TCPRelayWorker? = null
    private var udpRelay: UDPRelayWorker? = null
    private var appAttributor: AppAttributor? = null

    private var readerThread: Thread? = null
    private val isRunning = AtomicBoolean(false)

    companion object {
        const val ACTION_START = "com.veriquota.app.START_VPN"
        const val ACTION_STOP = "com.veriquota.app.STOP_VPN"
        const val NOTIFICATION_CHANNEL_ID = "veriquota_vpn_channel"
        const val NOTIFICATION_ID = 1001

        private val _isVpnActive = AtomicBoolean(false)
        val isVpnActive: Boolean get() = _isVpnActive.get()
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        AlertManager.init(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_STOP) {
            stopVpn()
            return START_NOT_STICKY
        }

        startVpn()
        return START_STICKY
    }

    private fun startVpn() {
        if (isRunning.getAndSet(true)) {
            Log.d(TAG, "VPN is already running")
            return
        }

        _isVpnActive.set(true)
        startForegroundServiceWithNotification()

        appAttributor = AppAttributor(this)

        try {
            val builder = Builder()
            builder.setSession("VeriQuota")
            builder.addAddress("10.0.0.2", 32)
            builder.addRoute("0.0.0.0", 0)
            builder.addDnsServer("8.8.8.8")
            builder.addDnsServer("1.1.1.1")
            builder.setMtu(1500)
            builder.setBlocking(true)
            builder.allowBypass()

            vpnInterface = builder.establish()
            val pfd = vpnInterface
            if (pfd == null) {
                Log.e(TAG, "Failed to establish VPN interface (null PFD)")
                stopVpn()
                return
            }

            val inputStream = FileInputStream(pfd.fileDescriptor)
            val outputStream = FileOutputStream(pfd.fileDescriptor)

            val writer = TunWriter(outputStream)
            tunWriter = writer

            val attributor = appAttributor!!
            tcpRelay = TCPRelayWorker(this, writer, attributor).apply { start() }
            udpRelay = UDPRelayWorker(this, writer, attributor).apply { start() }

            readerThread = Thread({ runTunReaderLoop(inputStream) }, "VeriQuota-TUN-Reader").apply {
                isDaemon = true
                start()
            }

            Log.i(TAG, "VeriQuota VPN service started successfully")
        } catch (e: Exception) {
            Log.e(TAG, "Error starting VPN interface", e)
            stopVpn()
        }
    }

    private fun runTunReaderLoop(inputStream: FileInputStream) {
        val buffer = ByteArray(32768)

        while (isRunning.get()) {
            try {
                val bytesRead = inputStream.read(buffer)
                if (bytesRead > 0) {
                    val packet = PacketParser.parse(buffer, bytesRead)
                    if (packet != null) {
                        when {
                            packet.isTcp -> tcpRelay?.handlePacket(packet, buffer)
                            packet.isUdp -> udpRelay?.handlePacket(packet, buffer)
                        }
                    }
                }
            } catch (e: IOException) {
                if (isRunning.get()) {
                    Log.w(TAG, "TUN inputStream read error", e)
                }
                break
            } catch (e: Exception) {
                if (isRunning.get()) {
                    Log.e(TAG, "Unexpected error in TUN reader loop", e)
                }
            }
        }
    }

    private fun stopVpn() {
        if (!isRunning.getAndSet(false)) return
        _isVpnActive.set(false)

        try {
            readerThread?.interrupt()
            readerThread = null

            tcpRelay?.stop()
            tcpRelay = null

            udpRelay?.stop()
            udpRelay = null

            vpnInterface?.close()
            vpnInterface = null
        } catch (e: Exception) {
            Log.e(TAG, "Error while closing VPN interface", e)
        }

        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        Log.i(TAG, "VeriQuota VPN service stopped")
    }

    override fun onDestroy() {
        stopVpn()
        super.onDestroy()
    }

    override fun onRevoke() {
        stopVpn()
        super.onRevoke()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "VeriQuota Data Monitor",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows persistent status while measuring data usage"
                setShowBadge(false)
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun startForegroundServiceWithNotification() {
        val launchIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notification: Notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("VeriQuota Active")
            .setContentText("Measuring per-app data usage locally")
            .setSmallIcon(android.R.drawable.ic_menu_info_details)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }
}

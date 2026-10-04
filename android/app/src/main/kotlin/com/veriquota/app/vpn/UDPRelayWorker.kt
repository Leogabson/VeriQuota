package com.veriquota.app.vpn

import android.net.VpnService
import android.util.Log
import java.io.IOException
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.channels.ClosedChannelException
import java.nio.channels.DatagramChannel
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean

class UDPRelayWorker(
    private val vpnService: VpnService,
    private val tunWriter: TunWriter,
    private val appAttributor: AppAttributor
) {
    private val TAG = "UDPRelayWorker"
    private val isRunning = AtomicBoolean(false)
    private var selector: Selector? = null
    private var workerThread: Thread? = null

    private data class UdpSession(
        val sessionKey: String,
        val clientIp: ByteArray,
        val clientPort: Int,
        val serverIp: ByteArray,
        val serverPort: Int,
        val channel: DatagramChannel,
        val packageName: String,
        var lastActive: Long = System.currentTimeMillis()
    )

    private class PendingUdpRegistration(
        val channel: DatagramChannel,
        val session: UdpSession
    )

    private val sessions = ConcurrentHashMap<String, UdpSession>()
    private val pendingRegistrations = ConcurrentLinkedQueue<PendingUdpRegistration>()

    fun start() {
        if (isRunning.getAndSet(true)) return
        selector = Selector.open()
        workerThread = Thread({ runSelectorLoop() }, "VeriQuota-UDP-Relay").apply {
            isDaemon = true
            start()
        }
    }

    fun stop() {
        if (!isRunning.getAndSet(false)) return
        try {
            selector?.wakeup()
            selector?.close()
        } catch (e: Exception) {
            // Ignore
        }
        for (session in sessions.values) {
            try {
                session.channel.close()
            } catch (e: Exception) {
                // Ignore
            }
        }
        sessions.clear()
        pendingRegistrations.clear()
        workerThread?.interrupt()
        workerThread = null
    }

    fun handlePacket(packet: ParsedPacket, rawBuffer: ByteArray) {
        if (!isRunning.get()) return

        val packageName = appAttributor.getPackageNameForPacket(packet)
        // Record outbound transmission
        TrafficAggregator.recordUsage(packageName, rxBytes = 0L, txBytes = packet.totalLength.toLong())

        val sessionKey = "${PacketUtil.ipToString(packet.sourceIp)}:${packet.sourcePort}->${PacketUtil.ipToString(packet.destIp)}:${packet.destPort}"
        var session = sessions[sessionKey]

        if (session == null || !session.channel.isOpen) {
            try {
                val channel = DatagramChannel.open()
                channel.configureBlocking(false)
                if (!vpnService.protect(channel.socket())) {
                    Log.w(TAG, "Failed to protect UDP socket for $sessionKey")
                }
                channel.connect(InetSocketAddress(packet.destAddress, packet.destPort))

                session = UdpSession(
                    sessionKey = sessionKey,
                    clientIp = packet.sourceIp,
                    clientPort = packet.sourcePort,
                    serverIp = packet.destIp,
                    serverPort = packet.destPort,
                    channel = channel,
                    packageName = packageName
                )
                sessions[sessionKey] = session

                // Decouple registration from TUN reader thread: enqueue and wakeup
                pendingRegistrations.offer(PendingUdpRegistration(channel, session))
                selector?.wakeup()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to create UDP channel for $sessionKey", e)
                return
            }
        }

        session.lastActive = System.currentTimeMillis()

        try {
            if (packet.payloadLength > 0) {
                val byteBuffer = ByteBuffer.wrap(rawBuffer, packet.payloadOffset, packet.payloadLength)
                session.channel.write(byteBuffer)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to write UDP payload to $sessionKey", e)
        }
    }

    private fun processPendingRegistrations() {
        val sel = selector ?: return
        if (!sel.isOpen) return

        while (true) {
            val req = pendingRegistrations.poll() ?: break
            if (!req.channel.isOpen) continue
            try {
                req.channel.register(sel, SelectionKey.OP_READ, req.session)
            } catch (e: ClosedChannelException) {
                // Channel closed before registration, ignore
            } catch (e: Exception) {
                Log.w(TAG, "Failed to register UDP channel for ${req.session.sessionKey}", e)
            }
        }
    }

    private fun runSelectorLoop() {
        val receiveBuffer = ByteBuffer.allocate(32768)
        var lastCleanupTime = System.currentTimeMillis()

        while (isRunning.get()) {
            try {
                processPendingRegistrations()

                val sel = selector ?: break
                val readyChannels = sel.select(1000)

                processPendingRegistrations()

                val now = System.currentTimeMillis()
                if (now - lastCleanupTime > 5_000L) {
                    lastCleanupTime = now
                    cleanupIdleSessions(now)
                }

                if (readyChannels == 0) continue

                val keys = sel.selectedKeys().iterator()
                while (keys.hasNext()) {
                    val key = keys.next()
                    keys.remove()

                    if (!key.isValid) continue

                    if (key.isReadable) {
                        val session = key.attachment() as? UdpSession ?: continue
                        val channel = key.channel() as? DatagramChannel ?: continue

                        receiveBuffer.clear()
                        var bytesRead = 0
                        try {
                            bytesRead = channel.read(receiveBuffer)
                        } catch (e: IOException) {
                            // Remote unreachable / ICMP port unreachable
                            key.cancel()
                            sessions.remove(session.sessionKey)
                            try { channel.close() } catch (ex: Exception) {}
                            continue
                        }

                        if (bytesRead > 0) {
                            session.lastActive = now
                            receiveBuffer.flip()

                            // Build IPv4 + UDP packet to inject into TUN
                            val totalLength = 20 + 8 + bytesRead
                            val packetData = ByteArray(totalLength)

                            // 1. IPv4 Header (20 bytes)
                            packetData[0] = 0x45.toByte() // IPv4, IHL = 5
                            packetData[1] = 0x00.toByte() // DSCP/ECN
                            packetData[2] = ((totalLength shr 8) and 0xFF).toByte()
                            packetData[3] = (totalLength and 0xFF).toByte()
                            packetData[4] = 0x00.toByte() // Identification
                            packetData[5] = 0x00.toByte()
                            packetData[6] = 0x40.toByte() // Don't Fragment
                            packetData[7] = 0x00.toByte()
                            packetData[8] = 64.toByte()   // TTL
                            packetData[9] = 17.toByte()   // UDP protocol

                            // Source IP = server IP, Dest IP = client IP
                            System.arraycopy(session.serverIp, 0, packetData, 12, 4)
                            System.arraycopy(session.clientIp, 0, packetData, 16, 4)

                            // IP Checksum at bytes 10-11
                            val ipChecksum = PacketUtil.calculateChecksum(packetData, 0, 20)
                            packetData[10] = ((ipChecksum shr 8) and 0xFF).toByte()
                            packetData[11] = (ipChecksum and 0xFF).toByte()

                            // 2. UDP Header (8 bytes) at offset 20
                            val udpLength = 8 + bytesRead
                            packetData[20] = ((session.serverPort shr 8) and 0xFF).toByte()
                            packetData[21] = (session.serverPort and 0xFF).toByte()
                            packetData[22] = ((session.clientPort shr 8) and 0xFF).toByte()
                            packetData[23] = (session.clientPort and 0xFF).toByte()
                            packetData[24] = ((udpLength shr 8) and 0xFF).toByte()
                            packetData[25] = (udpLength and 0xFF).toByte()
                            packetData[26] = 0x00.toByte() // Checksum placeholder
                            packetData[27] = 0x00.toByte()

                            // 3. UDP Payload at offset 28
                            receiveBuffer.get(packetData, 28, bytesRead)

                            // Compute UDP Checksum
                            val udpChecksum = PacketUtil.calculateUdpChecksum(
                                session.serverIp,
                                session.clientIp,
                                packetData,
                                20,
                                udpLength
                            )
                            packetData[26] = ((udpChecksum shr 8) and 0xFF).toByte()
                            packetData[27] = (udpChecksum and 0xFF).toByte()

                            // Write back to TUN
                            tunWriter.writePacket(packetData, 0, totalLength)

                            // Record received bytes for the attributed app
                            TrafficAggregator.recordUsage(
                                session.packageName,
                                rxBytes = totalLength.toLong(),
                                txBytes = 0L
                            )
                        }
                    }
                }
            } catch (e: Exception) {
                if (isRunning.get()) {
                    Log.e(TAG, "Error in UDP selector loop", e)
                }
            }
        }
    }

    private fun cleanupIdleSessions(now: Long) {
        val iterator = sessions.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            // Port 53 (DNS) queries have short idle timeout (15s); other UDP streams keep 60s
            val idleTimeout = if (entry.value.serverPort == 53) 15_000L else 60_000L
            if (now - entry.value.lastActive > idleTimeout) {
                try {
                    entry.value.channel.close()
                } catch (e: Exception) {
                    // Ignore
                }
                iterator.remove()
            }
        }
    }
}

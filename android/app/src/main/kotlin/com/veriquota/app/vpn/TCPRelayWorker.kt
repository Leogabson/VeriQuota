package com.veriquota.app.vpn

import android.net.VpnService
import android.util.Log
import java.io.IOException
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.channels.ClosedChannelException
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.nio.channels.SocketChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean

class TCPRelayWorker(
    private val vpnService: VpnService,
    private val tunWriter: TunWriter,
    private val appAttributor: AppAttributor
) {
    private val TAG = "TCPRelayWorker"
    private val isRunning = AtomicBoolean(false)
    private var selector: Selector? = null
    private var workerThread: Thread? = null

    private enum class TcpState {
        CONNECTING,
        CONNECTED,
        CLOSING,
        CLOSED
    }

    private class TcpSession(
        val sessionKey: String,
        val clientIp: ByteArray,
        val clientPort: Int,
        val serverIp: ByteArray,
        val serverPort: Int,
        val channel: SocketChannel,
        val packageName: String
    ) {
        var clientSeq: Long = 0L
        var serverSeq: Long = 0L
        var state: TcpState = TcpState.CONNECTING
        var lastActive: Long = System.currentTimeMillis()
        val pendingOutbound = ConcurrentLinkedQueue<ByteBuffer>()
    }

    private class PendingTcpRegistration(
        val channel: SocketChannel,
        val ops: Int,
        val session: TcpSession
    )

    private val sessions = ConcurrentHashMap<String, TcpSession>()
    private val pendingRegistrations = ConcurrentLinkedQueue<PendingTcpRegistration>()

    fun start() {
        if (isRunning.getAndSet(true)) return
        selector = Selector.open()
        workerThread = Thread({ runSelectorLoop() }, "VeriQuota-TCP-Relay").apply {
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
        val sessionKey = "${PacketUtil.ipToString(packet.sourceIp)}:${packet.sourcePort}->${PacketUtil.ipToString(packet.destIp)}:${packet.destPort}"

        if (packet.isSyn) {
            handleSyn(packet, sessionKey, packageName)
            return
        }

        val session = sessions[sessionKey] ?: return
        session.lastActive = System.currentTimeMillis()

        if (packet.isRst) {
            closeSession(session)
            return
        }

        if (packet.isFin) {
            handleFin(session)
            return
        }

        if (packet.payloadLength > 0) {
            handleData(packet, rawBuffer, session)
        }
    }

    private fun handleSyn(packet: ParsedPacket, sessionKey: String, packageName: String) {
        // Record outbound SYN
        TrafficAggregator.recordUsage(packageName, rxBytes = 0L, txBytes = packet.totalLength.toLong())

        // Clean up any stale session with the same 4-tuple
        sessions.remove(sessionKey)?.let { oldSession ->
            try { oldSession.channel.close() } catch (e: Exception) {}
        }

        try {
            val channel = SocketChannel.open()
            channel.configureBlocking(false)
            if (!vpnService.protect(channel.socket())) {
                Log.w(TAG, "Failed to protect TCP socket for $sessionKey")
            }

            val connectedImmediately = try {
                channel.connect(InetSocketAddress(packet.destAddress, packet.destPort))
            } catch (e: IOException) {
                Log.w(TAG, "Immediate connect failed for $sessionKey", e)
                try { channel.close() } catch (ex: Exception) {}
                return
            }

            val session = TcpSession(
                sessionKey = sessionKey,
                clientIp = packet.sourceIp,
                clientPort = packet.sourcePort,
                serverIp = packet.destIp,
                serverPort = packet.destPort,
                channel = channel,
                packageName = packageName
            )

            // SYN packet consumes 1 sequence number
            session.clientSeq = (packet.tcpSequenceNumber + 1) and 0xFFFFFFFFL
            session.serverSeq = ((System.nanoTime() and 0x7FFFFFFF) % 10_000_000L) + 100_000L

            if (connectedImmediately) {
                session.state = TcpState.CONNECTED
            } else {
                session.state = TcpState.CONNECTING
            }

            sessions[sessionKey] = session

            // Decouple registration from TUN reader thread: enqueue and wakeup
            val ops = if (connectedImmediately) SelectionKey.OP_READ else (SelectionKey.OP_CONNECT or SelectionKey.OP_READ)
            pendingRegistrations.offer(PendingTcpRegistration(channel, ops, session))
            selector?.wakeup()

            // Synthesize SYN-ACK packet back to client with standard MSS option (1460 bytes)
            sendTcpPacket(
                session = session,
                flags = 0x012, // SYN (0x02) | ACK (0x10)
                seq = session.serverSeq,
                ack = session.clientSeq,
                payload = null,
                includeMss = true
            )

            // SYN-ACK consumes 1 sequence number
            session.serverSeq = (session.serverSeq + 1) and 0xFFFFFFFFL

        } catch (e: Exception) {
            Log.e(TAG, "Failed to initiate TCP connection for $sessionKey", e)
        }
    }

    private fun handleData(packet: ParsedPacket, rawBuffer: ByteArray, session: TcpSession) {
        // Record outbound transmission
        TrafficAggregator.recordUsage(session.packageName, rxBytes = 0L, txBytes = packet.totalLength.toLong())

        val data = ByteArray(packet.payloadLength)
        System.arraycopy(rawBuffer, packet.payloadOffset, data, 0, packet.payloadLength)
        val buffer = ByteBuffer.wrap(data)

        if (session.state == TcpState.CONNECTED && session.channel.isConnected && session.pendingOutbound.isEmpty()) {
            try {
                session.channel.write(buffer)
                if (buffer.hasRemaining()) {
                    session.pendingOutbound.add(buffer)
                }
            } catch (e: IOException) {
                Log.w(TAG, "Channel write error for ${session.sessionKey}", e)
                closeSession(session)
                return
            }
        } else {
            session.pendingOutbound.add(buffer)
            // If connected, wake up selector to flush immediately
            if (session.state == TcpState.CONNECTED) {
                selector?.wakeup()
            }
        }

        // Advance expected client sequence number
        session.clientSeq = (session.clientSeq + packet.payloadLength) and 0xFFFFFFFFL

        // Acknowledge received data
        sendTcpPacket(
            session = session,
            flags = 0x010, // ACK
            seq = session.serverSeq,
            ack = session.clientSeq,
            payload = null
        )
    }

    private fun handleFin(session: TcpSession) {
        session.clientSeq = (session.clientSeq + 1) and 0xFFFFFFFFL
        session.state = TcpState.CLOSING

        // Send FIN-ACK response
        sendTcpPacket(
            session = session,
            flags = 0x011, // FIN (0x01) | ACK (0x10)
            seq = session.serverSeq,
            ack = session.clientSeq,
            payload = null
        )
        session.serverSeq = (session.serverSeq + 1) and 0xFFFFFFFFL

        closeSession(session)
    }

    private fun closeSession(session: TcpSession) {
        session.state = TcpState.CLOSED
        sessions.remove(session.sessionKey)
        try {
            session.channel.close()
        } catch (e: Exception) {
            // Ignore
        }
    }

    private fun flushPendingOutbound(channel: SocketChannel, session: TcpSession) {
        while (!session.pendingOutbound.isEmpty()) {
            val buf = session.pendingOutbound.peek() ?: break
            try {
                channel.write(buf)
                if (buf.hasRemaining()) {
                    // Socket send buffer is full, retry on next loop
                    break
                } else {
                    session.pendingOutbound.poll()
                }
            } catch (e: IOException) {
                Log.w(TAG, "Write error during flush for ${session.sessionKey}", e)
                closeSession(session)
                break
            }
        }
    }

    private fun sendTcpPacket(
        session: TcpSession,
        flags: Int,
        seq: Long,
        ack: Long,
        payload: ByteArray? = null,
        includeMss: Boolean = false
    ) {
        val payloadLen = payload?.size ?: 0
        val tcpHeaderLen = if (includeMss) 24 else 20
        val totalLen = 20 + tcpHeaderLen + payloadLen
        val packet = ByteArray(totalLen)

        // 1. IPv4 Header (20 bytes)
        packet[0] = 0x45.toByte() // IPv4, IHL = 5
        packet[1] = 0x00.toByte() // DSCP/ECN
        packet[2] = ((totalLen shr 8) and 0xFF).toByte()
        packet[3] = (totalLen and 0xFF).toByte()
        packet[4] = 0x00.toByte() // Identification
        packet[5] = 0x00.toByte()
        packet[6] = 0x40.toByte() // Don't fragment
        packet[7] = 0x00.toByte()
        packet[8] = 64.toByte()   // TTL
        packet[9] = 6.toByte()    // TCP protocol

        // Source = remote server, Dest = local client
        System.arraycopy(session.serverIp, 0, packet, 12, 4)
        System.arraycopy(session.clientIp, 0, packet, 16, 4)

        val ipChecksum = PacketUtil.calculateChecksum(packet, 0, 20)
        packet[10] = ((ipChecksum shr 8) and 0xFF).toByte()
        packet[11] = (ipChecksum and 0xFF).toByte()

        // 2. TCP Header (tcpHeaderLen bytes) starting at offset 20
        packet[20] = ((session.serverPort shr 8) and 0xFF).toByte()
        packet[21] = (session.serverPort and 0xFF).toByte()
        packet[22] = ((session.clientPort shr 8) and 0xFF).toByte()
        packet[23] = (session.clientPort and 0xFF).toByte()

        // Sequence Number (bytes 24-27)
        packet[24] = ((seq shr 24) and 0xFF).toByte()
        packet[25] = ((seq shr 16) and 0xFF).toByte()
        packet[26] = ((seq shr 8) and 0xFF).toByte()
        packet[27] = (seq and 0xFF).toByte()

        // Acknowledgment Number (bytes 28-31)
        packet[28] = ((ack shr 24) and 0xFF).toByte()
        packet[29] = ((ack shr 16) and 0xFF).toByte()
        packet[30] = ((ack shr 8) and 0xFF).toByte()
        packet[31] = (ack and 0xFF).toByte()

        // Data offset: tcpHeaderLen / 4 words + Reserved + Flags
        packet[32] = (((tcpHeaderLen / 4) shl 4) and 0xF0).toByte()
        packet[33] = (flags and 0xFF).toByte()

        // Window size (65535)
        packet[34] = 0xFF.toByte()
        packet[35] = 0xFF.toByte()

        // Checksum placeholder at bytes 36-37
        packet[36] = 0x00.toByte()
        packet[37] = 0x00.toByte()

        // Urgent pointer at bytes 38-39
        packet[38] = 0x00.toByte()
        packet[39] = 0x00.toByte()

        // MSS Option: Kind=2, Length=4, Value=1460 (0x05B4)
        if (includeMss) {
            packet[40] = 0x02.toByte()
            packet[41] = 0x04.toByte()
            packet[42] = 0x05.toByte()
            packet[43] = 0xB4.toByte()
        }

        // 3. Payload at offset 20 + tcpHeaderLen
        val payloadOffset = 20 + tcpHeaderLen
        if (payload != null && payloadLen > 0) {
            System.arraycopy(payload, 0, packet, payloadOffset, payloadLen)
        }

        // Compute TCP Checksum
        val tcpChecksum = PacketUtil.calculateTcpChecksum(
            session.serverIp,
            session.clientIp,
            packet,
            20,
            tcpHeaderLen + payloadLen
        )
        packet[36] = ((tcpChecksum shr 8) and 0xFF).toByte()
        packet[37] = (tcpChecksum and 0xFF).toByte()

        tunWriter.writePacket(packet, 0, totalLen)
    }

    private fun processPendingRegistrations() {
        val sel = selector ?: return
        if (!sel.isOpen) return

        while (true) {
            val req = pendingRegistrations.poll() ?: break
            if (!req.channel.isOpen) continue
            try {
                req.channel.register(sel, req.ops, req.session)
            } catch (e: ClosedChannelException) {
                // Channel closed before registration
            } catch (e: Exception) {
                Log.w(TAG, "Failed to register TCP channel for ${req.session.sessionKey}", e)
            }
        }
    }

    private fun runSelectorLoop() {
        // Read buffer sized to fit 1460 bytes (standard MSS, ensures MTU 1500 limit is never exceeded)
        val readBuffer = ByteBuffer.allocate(1460)
        var lastCleanupTime = System.currentTimeMillis()

        while (isRunning.get()) {
            try {
                processPendingRegistrations()

                val sel = selector ?: break
                val ready = sel.select(1000)

                processPendingRegistrations()

                val now = System.currentTimeMillis()
                if (now - lastCleanupTime > 10_000L) {
                    lastCleanupTime = now
                    cleanupIdleSessions(now)
                }

                if (ready == 0) continue

                val keys = sel.selectedKeys().iterator()
                while (keys.hasNext()) {
                    val key = keys.next()
                    keys.remove()

                    if (!key.isValid) continue

                    val session = key.attachment() as? TcpSession ?: continue
                    val channel = key.channel() as? SocketChannel ?: continue

                    if (key.isConnectable) {
                        try {
                            if (channel.finishConnect()) {
                                session.state = TcpState.CONNECTED
                                session.lastActive = now
                                key.interestOps(SelectionKey.OP_READ)
                                flushPendingOutbound(channel, session)
                            }
                        } catch (e: IOException) {
                            Log.w(TAG, "Failed to finish TCP connection to ${session.sessionKey}", e)
                            // Synthesize RST back to client
                            sendTcpPacket(
                                session = session,
                                flags = 0x014, // RST (0x04) | ACK (0x10)
                                seq = session.serverSeq,
                                ack = session.clientSeq,
                                payload = null
                            )
                            key.cancel()
                            closeSession(session)
                            continue
                        }
                    }

                    if (key.isReadable) {
                        readBuffer.clear()
                        var bytesRead = -1
                        try {
                            bytesRead = channel.read(readBuffer)
                        } catch (e: IOException) {
                            // Remote closed abruptly
                        }

                        if (bytesRead > 0) {
                            session.lastActive = now
                            readBuffer.flip()
                            val payload = ByteArray(bytesRead)
                            readBuffer.get(payload)

                            // Inject packet to TUN with PSH | ACK
                            sendTcpPacket(
                                session = session,
                                flags = 0x018, // PSH (0x08) | ACK (0x10)
                                seq = session.serverSeq,
                                ack = session.clientSeq,
                                payload = payload
                            )

                            session.serverSeq = (session.serverSeq + bytesRead) and 0xFFFFFFFFL

                            // Record received bytes for the attributed application
                            TrafficAggregator.recordUsage(
                                session.packageName,
                                rxBytes = (40 + bytesRead).toLong(),
                                txBytes = 0L
                            )

                            // Flush any remaining outbound data
                            if (!session.pendingOutbound.isEmpty()) {
                                flushPendingOutbound(channel, session)
                            }
                        } else if (bytesRead == -1) {
                            // Remote end reached EOF -> send FIN-ACK
                            sendTcpPacket(
                                session = session,
                                flags = 0x011, // FIN (0x01) | ACK (0x10)
                                seq = session.serverSeq,
                                ack = session.clientSeq,
                                payload = null
                            )
                            session.serverSeq = (session.serverSeq + 1) and 0xFFFFFFFFL
                            key.cancel()
                            closeSession(session)
                        }
                    }
                }
            } catch (e: Exception) {
                if (isRunning.get()) {
                    Log.e(TAG, "Error in TCP selector loop", e)
                }
            }
        }
    }

    private fun cleanupIdleSessions(now: Long) {
        val iter = sessions.entries.iterator()
        while (iter.hasNext()) {
            val entry = iter.next()
            if (now - entry.value.lastActive > 90_000L) {
                try { entry.value.channel.close() } catch (e: Exception) {}
                iter.remove()
            }
        }
    }
}

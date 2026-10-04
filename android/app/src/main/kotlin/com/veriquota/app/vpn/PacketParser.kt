package com.veriquota.app.vpn

import java.net.InetAddress
import java.nio.ByteBuffer

/**
 * Model representing parsed network packet headers (zero payload inspection).
 */
data class ParsedPacket(
    val ipVersion: Int,
    val protocol: Int, // 6 = TCP, 17 = UDP
    val sourceIp: ByteArray,
    val destIp: ByteArray,
    val sourcePort: Int,
    val destPort: Int,
    val ipHeaderLength: Int,
    val transportHeaderLength: Int,
    val totalLength: Int,
    val payloadOffset: Int,
    val payloadLength: Int,
    // TCP specific
    val tcpSequenceNumber: Long = 0L,
    val tcpAckNumber: Long = 0L,
    val isSyn: Boolean = false,
    val isAck: Boolean = false,
    val isFin: Boolean = false,
    val isRst: Boolean = false,
    val isPsh: Boolean = false
) {
    val isTcp: Boolean get() = protocol == 6
    val isUdp: Boolean get() = protocol == 17

    val sourceAddress: InetAddress by lazy { InetAddress.getByAddress(sourceIp) }
    val destAddress: InetAddress by lazy { InetAddress.getByAddress(destIp) }

    val sessionKey: String
        get() = "$protocol:${PacketUtil.ipToString(sourceIp)}:$sourcePort->${PacketUtil.ipToString(destIp)}:$destPort"

    val reverseSessionKey: String
        get() = "$protocol:${PacketUtil.ipToString(destIp)}:$destPort->${PacketUtil.ipToString(sourceIp)}:$sourcePort"
}

/**
 * High-performance parser extracting IP and TCP/UDP headers without reading payload.
 */
object PacketParser {

    fun parse(buffer: ByteArray, length: Int): ParsedPacket? {
        if (length < 20) return null

        val versionAndIhl = buffer[0].toInt() and 0xFF
        val ipVersion = versionAndIhl shr 4
        if (ipVersion != 4) {
            // IPv4 supported for phase 1 local VPN tunnel
            return null
        }

        val ihl = (versionAndIhl and 0x0F) * 4
        if (length < ihl) return null

        val totalLength = ((buffer[2].toInt() and 0xFF) shl 8) or (buffer[3].toInt() and 0xFF)
        val packetLength = Math.min(totalLength, length)
        val protocol = buffer[9].toInt() and 0xFF

        val sourceIp = buffer.copyOfRange(12, 16)
        val destIp = buffer.copyOfRange(16, 20)

        if (protocol == 6) { // TCP
            if (packetLength < ihl + 20) return null
            val sourcePort = ((buffer[ihl].toInt() and 0xFF) shl 8) or (buffer[ihl + 1].toInt() and 0xFF)
            val destPort = ((buffer[ihl + 2].toInt() and 0xFF) shl 8) or (buffer[ihl + 3].toInt() and 0xFF)

            val seqNum = ((buffer[ihl + 4].toLong() and 0xFF) shl 24) or
                    ((buffer[ihl + 5].toLong() and 0xFF) shl 16) or
                    ((buffer[ihl + 6].toLong() and 0xFF) shl 8) or
                    (buffer[ihl + 7].toLong() and 0xFF)

            val ackNum = ((buffer[ihl + 8].toLong() and 0xFF) shl 24) or
                    ((buffer[ihl + 9].toLong() and 0xFF) shl 16) or
                    ((buffer[ihl + 10].toLong() and 0xFF) shl 8) or
                    (buffer[ihl + 11].toLong() and 0xFF)

            val dataOffsetAndFlags = ((buffer[ihl + 12].toInt() and 0xFF) shl 8) or (buffer[ihl + 13].toInt() and 0xFF)
            val tcpHeaderLength = ((dataOffsetAndFlags shr 12) and 0x0F) * 4
            val flags = dataOffsetAndFlags and 0x01FF

            val isFin = (flags and 0x001) != 0
            val isSyn = (flags and 0x002) != 0
            val isRst = (flags and 0x004) != 0
            val isPsh = (flags and 0x008) != 0
            val isAck = (flags and 0x010) != 0

            val payloadOffset = ihl + tcpHeaderLength
            val payloadLength = Math.max(0, packetLength - payloadOffset)

            return ParsedPacket(
                ipVersion = ipVersion,
                protocol = protocol,
                sourceIp = sourceIp,
                destIp = destIp,
                sourcePort = sourcePort,
                destPort = destPort,
                ipHeaderLength = ihl,
                transportHeaderLength = tcpHeaderLength,
                totalLength = packetLength,
                payloadOffset = payloadOffset,
                payloadLength = payloadLength,
                tcpSequenceNumber = seqNum,
                tcpAckNumber = ackNum,
                isSyn = isSyn,
                isAck = isAck,
                isFin = isFin,
                isRst = isRst,
                isPsh = isPsh
            )
        } else if (protocol == 17) { // UDP
            if (packetLength < ihl + 8) return null
            val sourcePort = ((buffer[ihl].toInt() and 0xFF) shl 8) or (buffer[ihl + 1].toInt() and 0xFF)
            val destPort = ((buffer[ihl + 2].toInt() and 0xFF) shl 8) or (buffer[ihl + 3].toInt() and 0xFF)
            val udpLength = ((buffer[ihl + 4].toInt() and 0xFF) shl 8) or (buffer[ihl + 5].toInt() and 0xFF)

            val payloadOffset = ihl + 8
            val payloadLength = Math.max(0, udpLength - 8)

            return ParsedPacket(
                ipVersion = ipVersion,
                protocol = protocol,
                sourceIp = sourceIp,
                destIp = destIp,
                sourcePort = sourcePort,
                destPort = destPort,
                ipHeaderLength = ihl,
                transportHeaderLength = 8,
                totalLength = packetLength,
                payloadOffset = payloadOffset,
                payloadLength = payloadLength
            )
        }

        return null
    }
}

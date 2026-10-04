package com.veriquota.app.vpn

import java.nio.ByteBuffer

/**
 * Utility functions for IP, TCP, and UDP packet manipulation and RFC 1071 checksum calculations.
 */
object PacketUtil {

    /**
     * Calculates the RFC 1071 internet checksum for a byte array slice.
     */
    fun calculateChecksum(data: ByteArray, offset: Int, length: Int): Int {
        var sum = 0L
        var i = offset
        val end = offset + length

        while (i < end - 1) {
            val word = ((data[i].toInt() and 0xFF) shl 8) or (data[i + 1].toInt() and 0xFF)
            sum += word
            i += 2
        }

        if (i < end) {
            sum += (data[i].toInt() and 0xFF) shl 8
        }

        while (sum shr 16 > 0) {
            sum = (sum and 0xFFFF) + (sum shr 16)
        }

        return (sum.inv() and 0xFFFF).toInt()
    }

    /**
     * Calculates the TCP checksum using the IPv4 pseudo-header and TCP packet data.
     */
    fun calculateTcpChecksum(
        sourceIp: ByteArray,
        destIp: ByteArray,
        tcpPacket: ByteArray,
        tcpOffset: Int,
        tcpLength: Int
    ): Int {
        var sum = 0L

        // Pseudo-header: Source IP (4 bytes)
        sum += ((sourceIp[0].toInt() and 0xFF) shl 8) or (sourceIp[1].toInt() and 0xFF)
        sum += ((sourceIp[2].toInt() and 0xFF) shl 8) or (sourceIp[3].toInt() and 0xFF)

        // Pseudo-header: Destination IP (4 bytes)
        sum += ((destIp[0].toInt() and 0xFF) shl 8) or (destIp[1].toInt() and 0xFF)
        sum += ((destIp[2].toInt() and 0xFF) shl 8) or (destIp[3].toInt() and 0xFF)

        // Pseudo-header: Zero (1 byte) + Protocol (6 for TCP)
        sum += 6

        // Pseudo-header: TCP Length (2 bytes)
        sum += tcpLength

        // TCP header and payload
        var i = tcpOffset
        val end = tcpOffset + tcpLength
        while (i < end - 1) {
            val word = ((tcpPacket[i].toInt() and 0xFF) shl 8) or (tcpPacket[i + 1].toInt() and 0xFF)
            sum += word
            i += 2
        }

        if (i < end) {
            sum += (tcpPacket[i].toInt() and 0xFF) shl 8
        }

        while (sum shr 16 > 0) {
            sum = (sum and 0xFFFF) + (sum shr 16)
        }

        val result = (sum.inv() and 0xFFFF).toInt()
        return if (result == 0) 0xFFFF else result
    }

    /**
     * Calculates the UDP checksum using the IPv4 pseudo-header and UDP packet data.
     */
    fun calculateUdpChecksum(
        sourceIp: ByteArray,
        destIp: ByteArray,
        udpPacket: ByteArray,
        udpOffset: Int,
        udpLength: Int
    ): Int {
        var sum = 0L

        // Pseudo-header: Source IP (4 bytes)
        sum += ((sourceIp[0].toInt() and 0xFF) shl 8) or (sourceIp[1].toInt() and 0xFF)
        sum += ((sourceIp[2].toInt() and 0xFF) shl 8) or (sourceIp[3].toInt() and 0xFF)

        // Pseudo-header: Destination IP (4 bytes)
        sum += ((destIp[0].toInt() and 0xFF) shl 8) or (destIp[1].toInt() and 0xFF)
        sum += ((destIp[2].toInt() and 0xFF) shl 8) or (destIp[3].toInt() and 0xFF)

        // Pseudo-header: Zero + Protocol (17 for UDP)
        sum += 17

        // Pseudo-header: UDP Length
        sum += udpLength

        // UDP header and payload
        var i = udpOffset
        val end = udpOffset + udpLength
        while (i < end - 1) {
            val word = ((udpPacket[i].toInt() and 0xFF) shl 8) or (udpPacket[i + 1].toInt() and 0xFF)
            sum += word
            i += 2
        }

        if (i < end) {
            sum += (udpPacket[i].toInt() and 0xFF) shl 8
        }

        while (sum shr 16 > 0) {
            sum = (sum and 0xFFFF) + (sum shr 16)
        }

        val result = (sum.inv() and 0xFFFF).toInt()
        return if (result == 0) 0xFFFF else result
    }

    fun ipToString(ipBytes: ByteArray): String {
        return "${ipBytes[0].toInt() and 0xFF}.${ipBytes[1].toInt() and 0xFF}.${ipBytes[2].toInt() and 0xFF}.${ipBytes[3].toInt() and 0xFF}"
    }
}

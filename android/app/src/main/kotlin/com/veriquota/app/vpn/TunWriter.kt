package com.veriquota.app.vpn

import java.io.FileOutputStream
import java.io.IOException

/**
 * Thread-safe writer for injecting synthesized or forwarded packets back into the Android TUN interface.
 */
class TunWriter(private val outputStream: FileOutputStream) {

    private val writeLock = Any()

    fun writePacket(data: ByteArray, offset: Int, length: Int) {
        synchronized(writeLock) {
            try {
                outputStream.write(data, offset, length)
            } catch (e: IOException) {
                // Tunnel might be closed during shutdown
            }
        }
    }
}

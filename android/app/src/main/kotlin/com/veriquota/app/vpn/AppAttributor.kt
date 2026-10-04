package com.veriquota.app.vpn

import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.os.Build
import android.os.Process
import android.util.LruCache
import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentHashMap

/**
 * Maps network connection 5-tuples to the originating Android application package name.
 * Uses ConnectivityManager.getConnectionOwnerUid on Android 10+ (API 29+) with high-performance caching.
 */
class AppAttributor(private val context: Context) {

    private val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
    private val packageManager: PackageManager = context.packageManager

    // Cache UID to package name
    private val uidToPackageCache = ConcurrentHashMap<Int, String>()

    // Cache sessionKey (protocol:src:port->dst:port) to package name to avoid repeated system calls
    private val sessionToPackageCache = LruCache<String, String>(2048)

    /**
     * Resolves the application package name responsible for the given packet.
     */
    fun getPackageNameForPacket(packet: ParsedPacket): String {
        // Check session cache first
        val cached = sessionToPackageCache.get(packet.sessionKey)
        if (cached != null) return cached

        val uid = resolveUid(packet)
        val packageName = if (uid >= 0) {
            resolvePackageForUid(uid)
        } else {
            "android.system.network"
        }

        sessionToPackageCache.put(packet.sessionKey, packageName)
        return packageName
    }

    private fun resolveUid(packet: ParsedPacket): Int {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && connectivityManager != null) {
            try {
                val localAddress = InetSocketAddress(packet.sourceAddress, packet.sourcePort)
                val remoteAddress = InetSocketAddress(packet.destAddress, packet.destPort)
                val uid = connectivityManager.getConnectionOwnerUid(packet.protocol, localAddress, remoteAddress)
                if (uid != Process.INVALID_UID) {
                    return uid
                }
            } catch (e: Exception) {
                // Connection may be closed or not yet committed in kernel table
            }
        }
        return Process.INVALID_UID
    }

    private fun resolvePackageForUid(uid: Int): String {
        return uidToPackageCache.computeIfAbsent(uid) {
            try {
                val packages = packageManager.getPackagesForUid(uid)
                if (!packages.isNullOrEmpty()) {
                    packages[0]
                } else if (uid < 10000) {
                    SystemUidLabels.getLabel(uid)
                } else {
                    val name = packageManager.getNameForUid(uid)
                    name ?: "uid.$uid"
                }
            } catch (e: Exception) {
                if (uid < 10000) {
                    SystemUidLabels.getLabel(uid)
                } else {
                    "uid.$uid"
                }
            }
        }
    }
}

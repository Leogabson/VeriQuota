package com.veriquota.app.vpn

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

data class AppUsageSnapshot(
    val packageName: String,
    val rxBytes: Long,
    val txBytes: Long,
    val lastUpdated: Long
) {
    val totalBytes: Long get() = rxBytes + txBytes

    fun toMap(): Map<String, Any> {
        return mapOf(
            "packageName" to packageName,
            "rxBytes" to rxBytes,
            "txBytes" to txBytes,
            "totalBytes" to totalBytes,
            "lastUpdated" to lastUpdated
        )
    }
}

/**
 * Thread-safe in-memory traffic aggregator storing cumulative and minute-bucketed data usage.
 * No data is persisted to disk or transmitted externally.
 */
object TrafficAggregator {

    private class ByteCounter {
        val rx = AtomicLong(0L)
        val tx = AtomicLong(0L)
        val lastSeen = AtomicLong(System.currentTimeMillis())

        fun add(rxBytes: Long, txBytes: Long, timestamp: Long) {
            if (rxBytes > 0) rx.addAndGet(rxBytes)
            if (txBytes > 0) tx.addAndGet(txBytes)
            lastSeen.set(timestamp)
        }
    }

    // Cumulative usage per package name
    private val cumulativeUsage = ConcurrentHashMap<String, ByteCounter>()

    // Minute bucket key: timestamp / 60000 -> Map<PackageName, ByteCounter>
    private val minuteBuckets = ConcurrentHashMap<Long, ConcurrentHashMap<String, ByteCounter>>()

    // Keep up to 120 minutes of history in memory
    private const val MAX_BUCKET_RETENTION_MINUTES = 120L

    fun recordUsage(packageName: String, rxBytes: Long, txBytes: Long, timestamp: Long = System.currentTimeMillis()) {
        // 1. Update cumulative usage
        cumulativeUsage.computeIfAbsent(packageName) { ByteCounter() }
            .add(rxBytes, txBytes, timestamp)

        // 2. Update minute bucket
        val minuteKey = timestamp / 60_000L
        val bucket = minuteBuckets.computeIfAbsent(minuteKey) { ConcurrentHashMap() }
        bucket.computeIfAbsent(packageName) { ByteCounter() }
            .add(rxBytes, txBytes, timestamp)

        // Prune old buckets periodically
        pruneOldBuckets(minuteKey)

        // 3. Native threshold evaluation
        AlertManager.checkThreshold(packageName, timestamp)
    }

    fun getCurrentUsageSnapshot(): List<AppUsageSnapshot> {
        val list = mutableListOf<AppUsageSnapshot>()
        for ((pkg, counter) in cumulativeUsage) {
            list.add(
                AppUsageSnapshot(
                    packageName = pkg,
                    rxBytes = counter.rx.get(),
                    txBytes = counter.tx.get(),
                    lastUpdated = counter.lastSeen.get()
                )
            )
        }
        // Sort descending by total usage
        list.sortByDescending { it.totalBytes }
        return list
    }

    fun getTimeRangeUsage(packageName: String, startMillis: Long, endMillis: Long): AppUsageSnapshot {
        val startMinute = startMillis / 60_000L
        val endMinute = endMillis / 60_000L
        var totalRx = 0L
        var totalTx = 0L
        var lastUpdated = 0L

        for (minute in startMinute..endMinute) {
            val bucket = minuteBuckets[minute] ?: continue
            val counter = bucket[packageName] ?: continue
            totalRx += counter.rx.get()
            totalTx += counter.tx.get()
            lastUpdated = Math.max(lastUpdated, counter.lastSeen.get())
        }

        return AppUsageSnapshot(
            packageName = packageName,
            rxBytes = totalRx,
            txBytes = totalTx,
            lastUpdated = if (lastUpdated > 0) lastUpdated else System.currentTimeMillis()
        )
    }

    fun getAllTimeRangeUsage(startMillis: Long, endMillis: Long): List<AppUsageSnapshot> {
        val startMinute = startMillis / 60_000L
        val endMinute = endMillis / 60_000L
        val aggregated = mutableMapOf<String, Pair<Long, Long>>() // pkg -> (rx, tx)

        for (minute in startMinute..endMinute) {
            val bucket = minuteBuckets[minute] ?: continue
            for ((pkg, counter) in bucket) {
                val current = aggregated[pkg] ?: Pair(0L, 0L)
                aggregated[pkg] = Pair(current.first + counter.rx.get(), current.second + counter.tx.get())
            }
        }

        val list = aggregated.map { (pkg, pair) ->
            AppUsageSnapshot(
                packageName = pkg,
                rxBytes = pair.first,
                txBytes = pair.second,
                lastUpdated = System.currentTimeMillis()
            )
        }.toMutableList()

        list.sortByDescending { it.totalBytes }
        return list
    }

    private fun pruneOldBuckets(currentMinute: Long) {
        val oldestAllowed = currentMinute - MAX_BUCKET_RETENTION_MINUTES
        minuteBuckets.keys.removeIf { it < oldestAllowed }
    }

    fun clear() {
        cumulativeUsage.clear()
        minuteBuckets.clear()
    }
}

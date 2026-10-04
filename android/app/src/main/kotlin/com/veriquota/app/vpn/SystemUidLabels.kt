package com.veriquota.app.vpn

/**
 * Static lookup table mapping well-known Android system UIDs (UID < 10000)
 * to human-readable labels for transparent and auditable traffic monitoring.
 */
object SystemUidLabels {

    private val KNOWN_UID_NAMES: Map<Int, String> = mapOf(
        0 to "Root / Kernel",
        1000 to "System Core",
        1001 to "Radio",
        1002 to "Bluetooth",
        1003 to "Graphics",
        1004 to "Input",
        1005 to "Audio",
        1006 to "Camera",
        1007 to "Log Daemon",
        1008 to "Sensors",
        1009 to "Storage Mount",
        1010 to "Wi-Fi",
        1011 to "ADB",
        1012 to "Package Installer",
        1013 to "Media Server",
        1014 to "DHCP Client",
        1015 to "SD Card",
        1016 to "VPN Service",
        1017 to "Keystore",
        1019 to "DRM",
        1020 to "Multicast DNS",
        1021 to "GPS / Location",
        1023 to "Media Storage",
        1024 to "MTP",
        1026 to "DRM Rights",
        1027 to "NFC",
        1028 to "Network Daemon",
        1029 to "CLAT Translator",
        1030 to "Radio Loop",
        1046 to "Media Codec",
        1047 to "Media Extractor",
        1048 to "Media DRM",
        1049 to "Media Provisioning",
        1050 to "Radio",
        1051 to "Radio",
        1052 to "DNS Tethering",
        1053 to "WebView Zygote",
        1054 to "Vehicle Network",
        1066 to "StatsD",
        1067 to "Incident Daemon",
        1068 to "Secure Element",
        1069 to "Low Memory Killer",
        1073 to "Network Stack",
        1080 to "Context Hub",
        1081 to "KeyMint",
        1082 to "Ultra-Wideband",
        1083 to "Service Manager",
        2000 to "Shell",
        2001 to "Cache",
        3004 to "Network Raw",
        3005 to "Network Admin",
    )

    /**
     * Resolves a human-readable label for a system UID (< 10000).
     * Format: "Android System ($name) · uid $uid"
     * Fallback: "System process · uid $uid"
     */
    fun getLabel(uid: Int): String {
        val friendlyName = KNOWN_UID_NAMES[uid]
        return if (friendlyName != null) {
            "Android System ($friendlyName) · uid $uid"
        } else {
            "System process · uid $uid"
        }
    }
}

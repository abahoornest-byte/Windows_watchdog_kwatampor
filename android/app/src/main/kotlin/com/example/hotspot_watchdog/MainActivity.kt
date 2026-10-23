// android/app/src/main/kotlin/com/example/hotspot_watchdog/MainActivity.kt
package com.example.hotspot_watchdog

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of `campus_hustler/system` (see service_bridge.dart).
 * Every API newer than Android 5.1 (API 22) is behind a SDK_INT check.
 */
class MainActivity : FlutterActivity() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "requestNotificationPermission" -> {
                    requestNotificationPermissionIfNeeded()
                    result.success(true)
                }
                "startForegroundService" -> {
                    startCampusService()
                    result.success(true)
                }
                "stopForegroundService" -> {
                    stopService(Intent(this, CampusForegroundService::class.java))
                    result.success(true)
                }
                "acquireWakeLock" -> {
                    acquireLocks()
                    result.success(true)
                }
                "releaseWakeLock" -> {
                    releaseLocks()
                    result.success(true)
                }
                "moveTaskToBack" -> {
                    moveTaskToBack(true)
                    result.success(true)
                }
                "getStoredHash" -> {
                    result.success(prefs().getString(KEY_HASH, "") ?: "")
                }
                "setStoredHash" -> {
                    val hash = call.argument<String>("hash") ?: ""
                    // commit() is synchronous — the write hits disk before
                    // returning. apply() writes asynchronously on a
                    // background thread and can lose the value if the
                    // process dies shortly after (which was the persistence
                    // bug we saw).
                    val ok = prefs().edit().putString(KEY_HASH, hash).commit()
                    result.success(ok)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("native_error", e.message, null)
        }
    }

    private fun prefs() = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }

    private fun startCampusService() {
        val intent = Intent(this, CampusForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun acquireLocks() {
        try {
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK, "CampusHustler:cpu"
                ).apply { setReferenceCounted(false) }
            }
            if (wakeLock?.isHeld != true) wakeLock?.acquire()
        } catch (_: Exception) {}

        try {
            if (wifiLock == null) {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE)
                        as WifiManager
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    @Suppress("DEPRECATION")
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wm.createWifiLock(mode, "CampusHustler:wifi")
                    .apply { setReferenceCounted(false) }
            }
            if (wifiLock?.isHeld != true) wifiLock?.acquire()
        } catch (_: Exception) {}
    }

    private fun releaseLocks() {
        try { if (wakeLock?.isHeld == true) wakeLock?.release() } catch (_: Exception) {}
        try { if (wifiLock?.isHeld == true) wifiLock?.release() } catch (_: Exception) {}
    }

    companion object {
        private const val CHANNEL = "campus_hustler/system"
        private const val PREFS_NAME = "campus_hustler_prefs"
        private const val KEY_HASH = "unlock_hash"
    }
}
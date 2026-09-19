// SPDX-License-Identifier: AGPL-3.0-or-later
package com.hearth.app

import android.Manifest
import android.app.NotificationManager
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Common mobile plugin. Pre-29 devices never load the Aware driver/API types. */
class NearbyAndroid(private val activity: Activity, messenger: BinaryMessenger) {
    private val context = activity.applicationContext
    private var sink: EventChannel.EventSink? = null
    private val method = MethodChannel(messenger, "hearth/nearby")
    private val events = EventChannel(messenger, "hearth/nearby_events")
    private val aware = if (Build.VERSION.SDK_INT >= 29) NearbyWifiAware(context) { event ->
        sink?.success(event)
    } else null
    init {
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) { sink = eventSink }
            override fun onCancel(arguments: Any?) { sink = null; stop() }
        })
        method.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "capabilities" -> result.success(mapOf(
                        "supported" to ((aware?.supported == true) || context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)),
                        "sdk" to Build.VERSION.SDK_INT,
                        "internet" to internet(),
                        "permitted" to (notificationsPermitted() && (wifiPermitted() || bluetoothPermitted())),
                        "radioReady" to ((wifiPermitted() && radioReady()) || bluetoothReady()),
                        "wifiReady" to ((aware?.supported == true) && wifiPermitted() && radioReady()),
                        "awareSupported" to (aware?.supported == true),
                        "awarePairingSupported" to (Build.VERSION.SDK_INT >= 34 && aware?.pairingSupported == true),
                        "awarePairing" to (aware?.crossPairingSupported == true),
                        "bluetoothReady" to bluetoothReady(),
                        "locationEnabled" to locationEnabled(),
                        "stopped" to context.getSharedPreferences("hearth_nearby", Context.MODE_PRIVATE).getBoolean("stopped", false),
                    ))
                    "rearm" -> {
                        context.getSharedPreferences("hearth_nearby", Context.MODE_PRIVATE)
                            .edit().putBoolean("stopped", false).apply()
                        result.success(null)
                    }
                    "start" -> {
                        check(wifiPermitted() && notificationsPermitted() && radioReady()) { "Wi-Fi Aware unavailable or permission required" }
                        check(!context.getSharedPreferences("hearth_nearby", Context.MODE_PRIVATE).getBoolean("stopped", false)) { "Nearby messaging was stopped" }
                        checkNotNull(aware) { "Wi-Fi Aware unavailable" }.start()
                        result.success(null)
                    }
                    "stop" -> { stop(); result.success(null) }
                    "pair" -> {
                        check(wifiPermitted() && radioReady()) { "Wi-Fi Aware unavailable or permission required" }
                        checkNotNull(aware).pair(activity)
                        result.success(null)
                    }
                    "serviceStart" -> {
                        check(notificationsPermitted()) { "Notification permission is required" }
                        val intent = Intent(context, NearbyForegroundService::class.java)
                        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
                        result.success(null)
                    }
                    "serviceStop" -> { context.stopService(Intent(context, NearbyForegroundService::class.java)); result.success(null) }
                    "disconnect" -> { aware?.disconnect(call.argument<String>("id")); result.success(null) }
                    "send" -> {
                        val transport = aware
                        if (transport == null) result.error("nearby_send", "Wi-Fi Aware unavailable", null)
                        else transport.send(call.argument<String>("id"), call.argument<ByteArray>("bytes"), result)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("nearby", e.message ?: "Nearby unavailable", null)
            }
        }
        NearbyForegroundService.onStop = {
            // Persist the Stop action even if Flutter is suspended.
            context.getSharedPreferences("hearth_nearby", Context.MODE_PRIVATE)
                .edit().putBoolean("stopped", true).apply()
            stop()
            emit(mapOf("type" to "stopped"))
        }
    }

    private fun internet(): String {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val network = cm.activeNetwork ?: return "offline"
        val caps = cm.getNetworkCapabilities(network) ?: return "unknown"
        return if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) "online" else "offline"
    }

    private fun wifiPermitted(): Boolean {
        val permission = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.NEARBY_WIFI_DEVICES
            else Manifest.permission.ACCESS_FINE_LOCATION
        return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    private fun bluetoothPermitted(): Boolean = if (Build.VERSION.SDK_INT >= 31) {
        listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.ACCESS_FINE_LOCATION)
            .all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    } else context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    private fun bluetoothReady(): Boolean = bluetoothPermitted() && locationEnabled() &&
        context.getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled == true

    private fun notificationsPermitted(): Boolean {
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false
        val notifications = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 24 && !notifications.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 26 && notifications.getNotificationChannel("hearth_nearby")?.importance == NotificationManager.IMPORTANCE_NONE) return false
        return true
    }

    private fun locationEnabled(): Boolean {
        val lm = context.getSystemService(LocationManager::class.java)
        return if (Build.VERSION.SDK_INT >= 28) lm.isLocationEnabled
            else lm.isProviderEnabled(LocationManager.GPS_PROVIDER) || lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    }

    private fun radioReady(): Boolean = aware?.available == true && locationEnabled() &&
        (context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).isWifiEnabled

    private fun emit(event: Map<String, Any>) { sink?.success(event) }
    private fun stop() { aware?.stop() }
    fun dispose() {
        aware?.dispose()
        context.stopService(Intent(context, NearbyForegroundService::class.java))
        NearbyForegroundService.onStop = null
        method.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }
}

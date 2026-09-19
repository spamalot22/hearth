// SPDX-License-Identifier: AGPL-3.0-or-later
package com.hearth.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.app.Activity
import android.net.*
import android.net.wifi.aware.*
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * NAN data paths, never the default WLAN. All application frames must complete
 * the shared Dart Noise handshake. Open Android NDPs carry no account metadata.
 * Apple's paired-NAN profile is not assumed compatible with an open NDP.
 */
@android.annotation.TargetApi(29)
class NearbyWifiAware(private val context: Context, private val onEvent: (Map<String, Any>) -> Unit) {
    companion object {
        private const val PORT = 47391
        private const val MAX_FRAME = 32786
        // Android 10/11 reject underscores in NAN service names.
        private const val SERVICE = "hearth-text.tcp"
    }
    private val main = Handler(Looper.getMainLooper())
    private val manager = context.getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager
    private val cm = context.getSystemService(ConnectivityManager::class.java)
    private var session: WifiAwareSession? = null
    private var publisher: PublishDiscoverySession? = null
    private var subscriber: SubscribeDiscoverySession? = null
    private var receiver: BroadcastReceiver? = null
    private var server: ServerSocket? = null
    private var executor = Executors.newFixedThreadPool(6)
    private val links = ConcurrentHashMap<String, Socket>()
    private val paths = mutableMapOf<String, Path>()
    private val candidates = linkedMapOf<PeerHandle, String>()
    private val paired = if (Build.VERSION.SDK_INT >= 37 && NearbyAwarePairing.supported(manager)) {
        NearbyAwarePairing(
            connect = { s, peer, id ->
                if (!running || paths.size >= 4 || paths.containsKey(id)) false
                else { request(s, peer, id, false, generation, paired = true); paths.containsKey(id) }
            },
            disconnect = { id -> paths[id]?.let { drop(it) } },
            verified = { id -> paths[id]?.let { connectPath(it, generation) } },
            diagnostic = { state -> emit(mapOf("type" to "pairingState", "state" to state)) },
        )
    } else null
    private val pendingAccepts = AtomicInteger(0)
    private val pendingWrites = AtomicInteger(0)
    private val writeExecutor = Executors.newSingleThreadExecutor()
    @Volatile private var running = false
    @Volatile private var generation = 0
    private var instance = ""
    private var budgetWindow = 0L
    private var budgetBytes = 0
    private var budgetFrames = 0
    private var discoveryWindow = 0L
    private var discoveryMessages = 0
    private class Path(val id: String, val inbound: Boolean, val paired: Boolean = false) {
        var callback: ConnectivityManager.NetworkCallback? = null
        var address: java.net.Inet6Address? = null
        var network: Network? = null
        var locals = emptySet<java.net.InetAddress>()
        var socket: Socket? = null
        var connecting = false
        var port = PORT
    }
    val supported: Boolean get() = manager != null && context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)
    val available: Boolean get() = manager?.isAvailable == true
    val pairingSupported: Boolean get() = Build.VERSION.SDK_INT >= 34 && manager?.characteristics?.isAwarePairingSupported == true
    val crossPairingSupported: Boolean get() = paired != null
    fun pair(activity: Activity) { checkNotNull(paired) { "This phone cannot pair with iPhone over Wi-Fi Aware" }.pair(activity) }

    fun disconnect(id: String?) { if (id != null) try { links[id]?.close() } catch (_: Exception) {} }
    fun send(id: String?, bytes: ByteArray?, result: MethodChannel.Result) {
        val socket = if (id == null) null else links[id]
        if (bytes == null || bytes.isEmpty() || bytes.size > MAX_FRAME || socket == null) {
            result.error("nearby_send", "Link unavailable or frame too large", null)
            return
        }
        if (pendingWrites.incrementAndGet() > 16) {
            pendingWrites.decrementAndGet()
            result.error("nearby_busy", "Send queue full", null)
            return
        }
        try {
            writeExecutor.execute {
                try {
                    val out = DataOutputStream(socket.getOutputStream())
                    out.writeInt(bytes.size); out.write(bytes); out.flush()
                    main.post { result.success(null) }
                } catch (_: Exception) {
                    try { socket.close() } catch (_: Exception) {}
                    main.post { result.error("nearby_send", "Link disconnected", null) }
                } finally { pendingWrites.decrementAndGet() }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            pendingWrites.decrementAndGet()
            result.error("nearby_send", "Transport stopped", null)
        }
    }
    fun start() {
        if (running) return
        check(supported && available) { "Wi-Fi Aware is not currently available" }
        check(!context.getSharedPreferences("hearth_nearby", Context.MODE_PRIVATE).getBoolean("stopped", false)) { "Nearby messaging was stopped" }
        generation++
        val epoch = generation
        running = true
        instance = UUID.randomUUID().toString().replace("-", "")
        if (executor.isShutdown) executor = Executors.newFixedThreadPool(6)
        receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                if (running && generation == epoch) fail(epoch, "Wi-Fi Aware availability changed")
            }
        }
        try {
            val filter = IntentFilter(WifiAwareManager.ACTION_WIFI_AWARE_STATE_CHANGED)
            if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            else @Suppress("DEPRECATION") context.registerReceiver(receiver, filter)
            // Availability may have changed before receiver registration.
            check(available) { "Wi-Fi Aware is not currently available" }
            retryDiscovery(epoch)
            manager!!.attach(object : AttachCallback() {
                override fun onAttached(value: WifiAwareSession) {
                    if (!running || generation != epoch) { value.close(); return }
                    session = value
                    try { discover(value, epoch) } catch (_: Exception) { fail(epoch, "Wi-Fi Aware discovery unavailable") }
                }
                override fun onAttachFailed() { fail(epoch, "Wi-Fi Aware attach failed") }
            }, main)
            main.postDelayed({ if (running && generation == epoch && (publisher == null || subscriber == null)) fail(epoch, "Wi-Fi Aware startup timed out") }, 15000)
        } catch (e: Exception) { stop(); throw e }
    }

    private fun discover(value: WifiAwareSession, epoch: Int) {
        // The paired subscriber does not use the legacy Android discovery messages.
        try { paired?.start(value) } catch (_: Exception) {
            emit(mapOf("type" to "pairingState", "state" to "unavailable"))
        }
        value.publish(PublishConfig.Builder().setServiceName(SERVICE)
            .setServiceSpecificInfo(instance.toByteArray(Charsets.US_ASCII)).build(),
            object : DiscoverySessionCallback() {
                override fun onPublishStarted(s: PublishDiscoverySession) {
                    if (!running || generation != epoch) { s.close(); return }
                    publisher = s
                    listen(epoch)
                }
                override fun onSessionConfigFailed() { fail(epoch, "Wi-Fi Aware publish failed") }
                override fun onSessionTerminated() { fail(epoch, "Wi-Fi Aware publisher ended") }
                override fun onMessageReceived(peer: PeerHandle, message: ByteArray) {
                    if (!running || generation != epoch || message.size != 2 || message[0] != 72.toByte() || message[1] != 2.toByte()) return
                    if (!acceptDiscovery()) return
                    val s = publisher ?: return
                    val id = "p:" + peer.hashCode()
                    if (paths[id] == null && paths.size < 4) request(s, peer, id, true, epoch)
                    if (paths[id] != null) try { s.sendMessage(peer, 0, byteArrayOf(72, 3)) } catch (_: Exception) {}
                }
            }, main)
        value.subscribe(SubscribeConfig.Builder().setServiceName(SERVICE).build(),
            object : DiscoverySessionCallback() {
                override fun onSubscribeStarted(s: SubscribeDiscoverySession) {
                    if (!running || generation != epoch) { s.close(); return }
                    subscriber = s
                }
                override fun onSessionConfigFailed() { fail(epoch, "Wi-Fi Aware subscribe failed") }
                override fun onSessionTerminated() { fail(epoch, "Wi-Fi Aware subscriber ended") }
                override fun onServiceDiscovered(peer: PeerHandle, info: ByteArray, filters: List<ByteArray>) {
                    if (!running || generation != epoch || info.size != 32 || paths.size >= 4) return
                    val remote = info.toString(Charsets.US_ASCII)
                    if (!remote.matches(Regex("[0-9a-f]{32}")) || instance >= remote) return
                    candidates.remove(peer)
                    if (candidates.size >= 16) {
                        val oldestIdle = candidates.keys.firstOrNull { paths["s:" + it.hashCode()] == null }
                        if (oldestIdle != null) candidates.remove(oldestIdle)
                    }
                    if (candidates.size < 16) candidates[peer] = remote
                    if (paths["s:" + peer.hashCode()] != null) return
                    try { subscriber?.sendMessage(peer, 0, byteArrayOf(72, 2)) } catch (_: Exception) {}
                }
                override fun onServiceLost(peer: PeerHandle, reason: Int) {
                    if (running && generation == epoch) candidates.remove(peer)
                }
                override fun onMessageReceived(peer: PeerHandle, message: ByteArray) {
                    if (!running || generation != epoch || !message.contentEquals(byteArrayOf(72, 3))) return
                    if (!candidates.containsKey(peer) || !acceptDiscovery()) return
                    val s = subscriber ?: return
                    val id = "s:" + peer.hashCode()
                    if (paths[id] == null && paths.size < 4) request(s, peer, id, false, epoch)
                }
            }, main)
    }

    private fun acceptDiscovery(): Boolean {
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - discoveryWindow >= 60000) { discoveryWindow = now; discoveryMessages = 0 }
        discoveryMessages++
        return discoveryMessages <= 64
    }
    private fun retryDiscovery(epoch: Int) {
        if (!running || generation != epoch) return
        session?.let { value -> try { paired?.start(value); paired?.retry() } catch (_: Exception) {} }
        candidates.keys.toList().forEach { peer ->
            if (paths.size < 4 && paths["s:" + peer.hashCode()] == null) {
                try { subscriber?.sendMessage(peer, 0, byteArrayOf(72, 2)) } catch (_: Exception) {}
            }
        }
        main.postDelayed({ retryDiscovery(epoch) }, 20000)
    }

    private fun request(s: DiscoverySession, peer: PeerHandle, id: String, inbound: Boolean, epoch: Int, paired: Boolean = false) {
        if (Build.VERSION.SDK_INT < 29) return
        val path = Path(id, inbound, paired)
        paths[id] = path
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                main.post {
                    if (!running || generation != epoch || paths[id] !== path) return@post
                    val info = caps.transportInfo as? WifiAwareNetworkInfo ?: return@post
                    val address = info.peerIpv6Addr ?: return@post
                    if (path.paired) {
                        // The Apple listener chooses its port. Never dial the legacy port
                        // or a default-network address when paired endpoint data is absent.
                        if (info.port !in 1..65535 || info.transportProtocol != 6) return@post
                        path.port = info.port
                    }
                    path.address = address
                    path.network = network
                    cm.getLinkProperties(network)?.let { properties ->
                        path.locals = properties.linkAddresses.map { it.address }.toSet()
                    }
                    connectPath(path, epoch)
                }
            }
            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                main.post {
                    if (!running || generation != epoch || paths[id] !== path) return@post
                    path.network = network
                    path.locals = properties.linkAddresses.map { it.address }.toSet()
                    connectPath(path, epoch)
                }
            }
            override fun onLost(network: Network) { main.post { drop(path) } }
            override fun onUnavailable() { main.post { drop(path) } }
        }
        path.callback = callback
        try {
            cm.requestNetwork(NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .setNetworkSpecifier(WifiAwareNetworkSpecifier.Builder(s, peer).build()).build(), callback, if (paired) 120000 else 15000)
        } catch (_: Exception) { drop(path) }
        main.postDelayed({ if (paths[id] === path && path.socket == null) drop(path) }, if (paired) 125000 else 20000)
    }

    private fun connectPath(path: Path, epoch: Int) {
        if (path.inbound || path.connecting || path.locals.isEmpty()) return
        if (path.paired && paired?.isVerified(path.id) != true) return
        val network = path.network ?: return
        val address = path.address ?: return
        path.connecting = true
        executor.execute {
            val socket = Socket()
            try {
                network.bindSocket(socket)
                socket.connect(InetSocketAddress(address, path.port), 5000)
                main.post {
                    if (running && generation == epoch && paths[path.id] === path) addSocket(socket, path, epoch)
                    else socket.close()
                }
            } catch (_: Exception) {
                try { socket.close() } catch (_: Exception) {}
                main.post { drop(path) }
            }
        }
    }

    private fun listen(epoch: Int) {
        executor.execute {
            try {
                val listener = ServerSocket().apply { reuseAddress = true; bind(InetSocketAddress(PORT)) }
                synchronized(this) {
                    if (!running || generation != epoch) { listener.close(); return@execute }
                    server = listener
                }
                while (running && generation == epoch) {
                    val socket = listener.accept()
                    if (pendingAccepts.incrementAndGet() > 8) {
                        pendingAccepts.decrementAndGet()
                        socket.close()
                        continue
                    }
                    main.post {
                        pendingAccepts.decrementAndGet()
                        val path = paths.values.firstOrNull {
                            it.inbound && it.socket == null && it.address == socket.inetAddress &&
                                it.locals.contains(socket.localAddress)
                        }
                        // The listener is never a LAN entry point, even on an isolated WLAN.
                        if (running && generation == epoch && path != null) addSocket(socket, path, epoch)
                        else socket.close()
                    }
                }
            } catch (_: Exception) { fail(epoch, "Wi-Fi Aware listener unavailable") }
        }
    }

    private fun addSocket(socket: Socket, path: Path, epoch: Int) {
        if (!running || generation != epoch || paths[path.id] !== path || path.socket != null) { socket.close(); return }
        val id = UUID.randomUUID().toString()
        path.socket = socket
        socket.tcpNoDelay = true
        socket.soTimeout = 90000
        links[id] = socket
        emit(mapOf("type" to "linkUp", "id" to id, "medium" to "wifiAware"))
        executor.execute {
            try {
                val input = DataInputStream(socket.getInputStream())
                var window = android.os.SystemClock.elapsedRealtime()
                var frames = 0
                var byteCount = 0
                while (running && generation == epoch) {
                    val size = input.readInt()
                    if (size <= 0 || size > MAX_FRAME) break
                    val now = android.os.SystemClock.elapsedRealtime()
                    if (now - window >= 60000) { window = now; frames = 0; byteCount = 0 }
                    frames++
                    byteCount += size
                    if (frames > 128 || byteCount > 1024 * 1024 || !acceptFrame(size, now)) break
                    val bytes = ByteArray(size)
                    input.readFully(bytes)
                    emit(mapOf("type" to "bytes", "id" to id, "bytes" to bytes))
                }
            } catch (_: Exception) {
                // Radio loss or peer shutdown.
            } finally {
                links.remove(id)
                try { socket.close() } catch (_: Exception) {}
                emit(mapOf("type" to "linkDown", "id" to id))
                main.post { drop(path) }
            }
        }
    }

    private fun drop(path: Path) {
        if (paths[path.id] !== path) return
        paths.remove(path.id)
        try { path.socket?.close() } catch (_: Exception) {}
        path.callback?.let { try { cm.unregisterNetworkCallback(it) } catch (_: Exception) {} }
        if (path.paired) paired?.released(path.id)
    }
    private fun fail(epoch: Int, message: String) { main.post {
        if (running && generation == epoch) { stop(); emit(mapOf("type" to "error", "message" to message)) }
    } }
    private fun emit(event: Map<String, Any>) { main.post { onEvent(event) } }
    @Synchronized private fun acceptFrame(size: Int, now: Long): Boolean {
        if (now - budgetWindow >= 60000) { budgetWindow = now; budgetFrames = 0; budgetBytes = 0 }
        budgetFrames++
        budgetBytes += size
        return budgetFrames <= 256 && budgetBytes <= 2 * 1024 * 1024
    }
    fun stop() {
        running = false
        generation++
        paired?.stop()
        receiver?.let { try { context.unregisterReceiver(it) } catch (_: Exception) {} }
        receiver = null
        paths.values.toList().forEach { drop(it) }
        candidates.clear()
        links.values.forEach { try { it.close() } catch (_: Exception) {} }
        links.clear()
        synchronized(this) { try { server?.close() } catch (_: Exception) {}; server = null }
        publisher?.close(); publisher = null
        subscriber?.close(); subscriber = null
        session?.close(); session = null
        executor.shutdownNow()
    }
    fun dispose() { stop(); writeExecutor.shutdownNow() }
}

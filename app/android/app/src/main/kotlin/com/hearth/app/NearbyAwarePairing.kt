// SPDX-License-Identifier: AGPL-3.0-or-later
package com.hearth.app

import android.app.Activity
import android.app.AlertDialog
import android.net.wifi.aware.*
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.widget.ArrayAdapter
import java.util.UUID

/** API 37.2 subscriber for Apple's paired NAN profile. No app-managed PIN or PMK. */
class NearbyAwarePairing(
    private val connect: (SubscribeDiscoverySession, PeerHandle, String) -> Boolean,
    private val disconnect: (String) -> Unit,
    private val verified: (String) -> Unit,
    private val diagnostic: (String) -> Unit,
) {
    companion object {
        fun supported(manager: WifiAwareManager?): Boolean {
            if (Build.VERSION.SDK_INT < 37 ||
                Build.VERSION.SDK_INT_FULL < Build.VERSION_CODES_FULL.CINNAMON_BUN_2) return false
            val c = manager?.characteristics ?: return false
            return c.isAwarePairingSupported &&
                c.supportedPairingCipherSuites and Characteristics.WIFI_AWARE_CIPHER_SUITE_NCS_PK_PASN_128 != 0 &&
                c.supportedOffloadBootstrappingMethods and AwarePairingConfig.PAIRING_BOOTSTRAPPING_PIN_CODE_KEYPAD != 0
        }
    }
    private class Candidate(val peer: PeerHandle, val id: String, val number: Int) {
        var verified = false
        var remembered = false
        var pending = false
        var lastAttempt = -30000L
        var seen = SystemClock.elapsedRealtime()
    }
    private val main = Handler(Looper.getMainLooper())
    private val candidates = linkedMapOf<PeerHandle, Candidate>()
    private var session: SubscribeDiscoverySession? = null
    private var starting = false
    private var epoch = 0
    private var nextNumber = 1
    private var dialog: AlertDialog? = null
    private var attemptWindow = 0L
    private var attempts = 0
    val ready get() = session != null

    fun start(owner: WifiAwareSession) {
        if (session != null || starting) return
        starting = true
        val current = ++epoch
        try {
            val config = SubscribeConfig.Builder()
                .setServiceName("_hearth-text._tcp")
                .setSubscribeType(SubscribeConfig.SUBSCRIBE_TYPE_ACTIVE)
                .setFrameworkOffloadedPairingEnabled(true)
                .build()
            owner.subscribe(config, object : DiscoverySessionCallback() {
                override fun onSubscribeStarted(value: SubscribeDiscoverySession) {
                    if (epoch != current) { value.close(); return }
                    session = value
                    starting = false
                    diagnostic("ready")
                }
                override fun onSessionConfigFailed() { failed(current) }
                override fun onSessionTerminated() { failed(current) }
                override fun onServiceDiscovered(info: ServiceDiscoveryInfo) {
                    if (epoch != current || session == null) return
                    val peer = info.peerHandle
                    val candidate = candidates[peer] ?: run {
                        if (candidates.size >= 16) return
                        Candidate(peer, "paired:" + UUID.randomUUID(), nextNumber++).also { candidates[peer] = it }
                    }
                    candidate.seen = SystemClock.elapsedRealtime()
                    candidate.remembered = info.pairedAlias != null
                    if (candidate.verified) attempt(candidate, false)
                }
                override fun onPairingVerificationSucceed(peer: PeerHandle, alias: String) {
                    if (epoch != current) return
                    val candidate = candidates[peer] ?: return
                    if (!candidate.remembered) return
                    candidate.verified = true
                    verified(candidate.id)
                    diagnostic("verified")
                    attempt(candidate, false)
                }
                override fun onPairingSetupSucceeded(peer: PeerHandle, alias: String) {
                    if (epoch != current) return
                    val candidate = candidates[peer] ?: return
                    // Only explicit selection may start a first-time connection.
                    if (candidate.pending) {
                        candidate.verified = true
                        verified(candidate.id)
                        diagnostic("paired")
                    }
                }
                override fun onPairingVerificationFailed(peer: PeerHandle) { rejected(current, peer) }
                override fun onPairingSetupFailed(peer: PeerHandle) { rejected(current, peer) }
                override fun onServiceLost(peer: PeerHandle, reason: Int) {
                    if (epoch != current) return
                    candidates.remove(peer)?.let { disconnect(it.id) }
                }
            }, main)
            main.postDelayed({ if (epoch == current && starting) failed(current) }, 15000)
        } catch (e: Exception) { stop(); throw e }
    }

    fun pair(activity: Activity) {
        check(ready && !activity.isFinishing && !activity.isDestroyed) { "Paired Wi-Fi discovery is unavailable" }
        if (dialog != null) return
        val current = epoch
        var rows = emptyList<Candidate>()
        val adapter = ArrayAdapter<String>(activity, android.R.layout.simple_list_item_1)
        val picker = AlertDialog.Builder(activity)
            .setTitle("Pair Wi-Fi Aware device")
            .setAdapter(adapter) { _, index ->
                if (epoch == current) rows.getOrNull(index)?.let { candidate ->
                    if (candidates[candidate.peer] === candidate) attempt(candidate, true)
                }
            }
            .setNegativeButton("Cancel", null)
            .create()
        dialog = picker
        picker.setOnDismissListener { if (dialog === picker) dialog = null }
        fun refresh() {
            if (dialog !== picker || epoch != current) return
            val now = SystemClock.elapsedRealtime()
            rows = candidates.values.filter { !it.pending && now - it.seen < 45000 }
            adapter.clear()
            adapter.addAll(rows.map { "Wi-Fi device ${it.number}" })
            picker.setTitle(if (rows.isEmpty()) "Searching for Wi-Fi devices" else "Pair Wi-Fi Aware device")
            main.postDelayed({ refresh() }, 1000)
        }
        picker.show()
        refresh()
    }

    private fun attempt(candidate: Candidate, explicit: Boolean) {
        val s = session ?: return
        val now = SystemClock.elapsedRealtime()
        if (candidate.pending || (!explicit && !candidate.verified) || now - candidate.lastAttempt < 30000) return
        if (explicit) {
            if (now - attemptWindow >= 60000) { attemptWindow = now; attempts = 0 }
            if (++attempts > 3) return
        }
        candidate.lastAttempt = now
        candidate.pending = connect(s, candidate.peer, candidate.id)
        if (candidate.pending) diagnostic(if (explicit) "selected" else "reconnecting")
    }

    fun released(id: String) {
        candidates.values.firstOrNull { it.id == id }?.pending = false
    }
    fun isVerified(id: String): Boolean = candidates.values.any { it.id == id && it.verified }

    fun retry() {
        val now = SystemClock.elapsedRealtime()
        for (candidate in candidates.values.toList()) {
            if (now - candidate.seen >= 120000 && !candidate.pending) candidates.remove(candidate.peer)
            else if (candidate.verified) attempt(candidate, false)
        }
    }

    private fun rejected(current: Int, peer: PeerHandle) {
        if (epoch != current) return
        candidates[peer]?.let { it.verified = false; it.pending = false; disconnect(it.id) }
        diagnostic("rejected")
    }
    private fun failed(current: Int) {
        if (epoch != current) return
        stop()
        diagnostic("unavailable")
    }
    fun stop() {
        epoch++
        starting = false
        dialog?.dismiss(); dialog = null
        val old = session
        session = null
        candidates.values.toList().forEach { disconnect(it.id) }
        candidates.clear()
        old?.close()
    }
}

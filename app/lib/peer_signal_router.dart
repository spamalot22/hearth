// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'mesh_control.dart';
import 'signal_auth.dart';

/// Routing state for carrying authenticated WebRTC signalling over an existing
/// mesh. Routes only live while their next-hop data channel is alive; the
/// persistent candidate cache stores identities, not stale network addresses.
class PeerSignalRouter {
  PeerSignalRouter({
    required this.selfPeer,
    required this.channel,
    this.maxRoutes = 1024,
    this.maxSeenSignals = 4096,
    this.seenTtl = const Duration(minutes: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static final RegExp _peerPattern = RegExp(r'^[0-9a-f]{64}$');
  static const int maxRoutedSignalBytes = 256 * 1024;
  static const int maxIceCandidateBytes = 16 * 1024;

  final String selfPeer;
  final String channel;
  final int maxRoutes;
  final int maxSeenSignals;
  final Duration seenTtl;
  final DateTime Function() _now;

  final LinkedHashMap<String, String> _routes = LinkedHashMap();
  final LinkedHashMap<String, DateTime> _seen = LinkedHashMap();

  /// Learns that [destination] is reachable through the currently-open [via]
  /// peer. A cryptographically authenticated routed signal can also establish
  /// the reverse route to its origin.
  void learnRoute(String destination, String via) {
    if (!_peerPattern.hasMatch(destination) ||
        !_peerPattern.hasMatch(via) ||
        destination == selfPeer ||
        destination == via ||
        via == selfPeer) {
      return;
    }
    _routes.remove(destination);
    _routes[destination] = via;
    while (_routes.length > maxRoutes) {
      _routes.remove(_routes.keys.first);
    }
  }

  /// Drops every route whose first hop disappeared.
  void removeNextHop(String peer) {
    _routes.removeWhere((_, nextHop) => nextHop == peer);
  }

  /// Chooses a known route when possible, otherwise bounded-floods the signal
  /// across open links. Every receiving node deduplicates it, so cycles stop.
  List<String> nextHops({
    required String destination,
    required Iterable<String> openPeers,
    String? exclude,
    int maxFanout = 64,
  }) {
    final open = openPeers
        .where(
          (peer) =>
              peer != exclude &&
              peer != selfPeer &&
              _peerPattern.hasMatch(peer),
        )
        .toSet();
    if (open.contains(destination)) return [destination];

    final preferred = _routes[destination];
    if (preferred != null && open.contains(preferred)) return [preferred];

    final fallback = open.toList()..sort();
    return fallback.take(maxFanout).toList(growable: false);
  }

  bool hasPath(String destination, Iterable<String> openPeers) => nextHops(
    destination: destination,
    openPeers: openPeers,
    maxFanout: 1,
  ).isNotEmpty;

  /// Returns false for a duplicate recently seen signal. The fingerprint uses
  /// only fixed, end-to-end-authenticated fields, so JSON map ordering and hop
  /// metadata cannot create alternate identities for the same signal.
  bool remember(SignalControl signal) {
    final now = _now();
    while (_seen.isNotEmpty && now.difference(_seen.values.first) > seenTtl) {
      _seen.remove(_seen.keys.first);
    }

    final id = fingerprint(signal);
    if (_seen.containsKey(id)) return false;
    _seen[id] = now;
    while (_seen.length > maxSeenSignals) {
      _seen.remove(_seen.keys.first);
    }
    return true;
  }

  String fingerprint(SignalControl signal) {
    final signedBytes = signalSigningBytes(
      channel,
      signal.kind,
      signal.to,
      signal.data,
    );
    return sha256.convert([
      ...utf8.encode(
        '${signal.from}\n${signal.to}\n${signal.kind}\n'
        '${signal.data['sig']}\n${signal.data[signalCapabilityField]}\n',
      ),
      ...signedBytes,
    ]).toString();
  }

  /// Validates shape, size, identity signature, and optional group capability
  /// before a signal is processed or forwarded.
  Future<bool> authenticate(
    SignalControl signal, {
    Uint8List? channelAuthKey,
  }) async {
    if (!_peerPattern.hasMatch(signal.from) ||
        !_peerPattern.hasMatch(signal.to) ||
        signal.from == signal.to ||
        signal.hopsRemaining < 0 ||
        signal.hopsRemaining > kDefaultSignalRouteHops ||
        !_validPayload(signal)) {
      return false;
    }

    try {
      final wireBytes = utf8.encode(jsonEncode(signal.toJson())).length;
      if (wireBytes > maxRoutedSignalBytes) return false;
    } catch (_) {
      return false;
    }

    if (!await verifySignal(
      signal.from,
      signal.to,
      channel,
      signal.kind,
      signal.data,
    )) {
      return false;
    }
    if (channelAuthKey != null &&
        !verifySignalCapabilityProof(
          channelAuthKey,
          signal.from,
          signal.to,
          channel,
          signal.kind,
          signal.data,
        )) {
      return false;
    }
    return true;
  }

  bool _validPayload(SignalControl signal) {
    final signature = signal.data['sig'];
    if (signature is! String || signature.length > 128) return false;
    final capability = signal.data[signalCapabilityField];
    if (capability != null &&
        (capability is! String || capability.length != 64)) {
      return false;
    }

    switch (signal.kind) {
      case 'offer':
      case 'answer':
        final sdp = signal.data['sdp'];
        final type = signal.data['type'];
        return sdp is String &&
            sdp.isNotEmpty &&
            utf8.encode(sdp).length <= maxRoutedSignalBytes &&
            type == signal.kind;
      case 'ice':
        final candidate = signal.data['candidate'];
        final mid = signal.data['sdpMid'];
        final line = signal.data['sdpMLineIndex'];
        return candidate is String &&
            candidate.isNotEmpty &&
            utf8.encode(candidate).length <= maxIceCandidateBytes &&
            (mid == null || (mid is String && mid.length <= 256)) &&
            (line == null || line is num);
      default:
        return false;
    }
  }
}

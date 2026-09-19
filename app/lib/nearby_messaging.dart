// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'channel.dart';
import 'content.dart';
import 'diagnostics.dart';
import 'nearby_bluetooth.dart';
import 'nearby_queue_hive.dart';
import 'settings.dart';

/// Mobile-only opt-in coordinator. Radio adapters see only encrypted frames;
/// they cannot create contacts, admit group members, or acknowledge delivery.
class NearbyMessaging extends ChangeNotifier {
  NearbyMessaging({
    required this.identity,
    required this.settings,
    required this.sessions,
    NearbyBluetoothRadio? bluetooth,
  }) : _bluetooth = bluetooth ?? NearbyBluetooth();

  static const _native = MethodChannel('hearth/nearby');
  static const _events = EventChannel('hearth/nearby_events');
  final Identity identity;
  final SettingsStore settings;
  final Iterable<ChannelSession> Function() sessions;
  final NearbyBluetoothRadio _bluetooth;
  NearbyMux? _mux;
  String? _lastRuntime;
  String? _lastPeers;
  bool _bluetoothRunning = false;
  bool _wifiRunning = false;
  Timer? _signalTimer;
  final _observations = <String, ProximityObservation>{};
  final _labels = <String, int>{};
  int _nextLabel = 1;
  final _policy = NearbyActivationPolicy();
  final _links = <String, _NativeNearbyLink>{};
  final _delivered = <String>{};
  final _routes = <String, ChannelSession>{};
  final _sessionSubs = <ChannelSession, StreamSubscription<Message>>{};
  final _forwardedInner = <String>{};
  final _deliveryAttempts = <String, DateTime>{};
  int _bridging = 0;
  NearbyQueue? _queue;
  NearbyCourier? _courier;
  StreamSubscription<dynamic>? _sub;
  Timer? _timer;
  bool _closed = false;
  int _configuration = 0;
  Future<void>? _refreshing;
  Future<void>? _stopping;
  bool _running = false;
  bool supported = false;
  String _permissionStatus = 'Permission required';
  String? error;
  InternetReachability internet = InternetReachability.unknown;
  NearbyActivation activation = NearbyActivation.disabled;
  int get peerCount => _mux?.peers.length ?? 0;
  bool awarePairingAvailable = false;
  bool get canPairAware => awarePairingAvailable && _wifiRunning;

  Future<void> pairAware() async {
    if (!canPairAware) throw StateError('Wi-Fi Aware is not active');
    await _native.invokeMethod<void>('pair');
  }

  int get queuedCount => _queue?.packets.length ?? 0;
  bool get enabled => settings.nearbyEnabled;
  bool get automatic => settings.nearbyAutomatic;
  bool get scannerEnabled => settings.proximityScanner;
  bool get active => _running;
  bool get _wanted => enabled || scannerEnabled;
  Map<String, NearbyMedium> get connectedPeers => _mux?.peers ?? {};
  List<ProximityObservation> get observations {
    final byPeer = <String, ProximityObservation>{};
    for (final item in _observations.values) {
      if (item.stale(DateTime.now())) continue;
      final key = _mux?.peerFor(item.id) ?? item.id;
      final previous = byPeer[key];
      if (previous == null || item.seenAt.isAfter(previous.seenAt)) {
        byPeer[key] = item;
      }
    }
    return byPeer.values.toList();
  }

  String labelFor(String id) {
    final peer = _mux?.peerFor(id) ?? id;
    if (_labels.length >= 256 && !_labels.containsKey(peer)) {
      _labels.remove(_labels.keys.first);
    }
    return 'Nearby device ${_labels.putIfAbsent(peer, () => _nextLabel++)}';
  }

  String? peerFor(String id) => _mux?.peerFor(id);
  ProximityObservation? signalFor(String peer) {
    for (final observation in observations) {
      if ((_mux?.peerFor(observation.id) ?? observation.id) == peer) {
        return observation;
      }
    }
    return null;
  }

  String get status =>
      error ??
      switch (activation) {
        NearbyActivation.disabled => 'Off',
        NearbyActivation.standby => 'Standby',
        NearbyActivation.waitingForPermission => _permissionStatus,
        NearbyActivation.active =>
          _running ? '$peerCount nearby peers' : 'Starting',
      };

  Future<void> initialize() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }
    try {
      final caps = await _capabilities();
      supported = caps['supported'] == true;
      if (!supported || _closed) return;
      final storage = await HiveNearbyQueueStorage.open();
      _queue = NearbyQueue(storage);
      await _queue!.load();
      if (_closed) return;
      _sub = _events.receiveBroadcastStream().listen(
        _event,
        onError: (Object _) {
          error = 'Nearby connection unavailable';
          if (!_closed) notifyListeners();
        },
      );
      _timer = Timer.periodic(
        const Duration(seconds: 15),
        (_) => unawaited(refresh()),
      );
      _signalTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (scannerEnabled && _running) {
          unawaited(_bluetooth.scanSignals().catchError((Object _) {}));
          _observations.removeWhere((_, item) => item.stale(DateTime.now()));
          notifyListeners();
        }
      });
      await refresh();
    } on MissingPluginException {
      supported = false;
    } catch (_) {
      supported = false;
      error = 'Nearby messaging unavailable';
    }
    if (!_closed) notifyListeners();
  }

  Future<Map<dynamic, dynamic>> _capabilities() async =>
      await _native
          .invokeMapMethod<dynamic, dynamic>('capabilities', {
            'probe': enabled && automatic,
          })
          .timeout(const Duration(seconds: 5)) ??
      {};

  /// Permissions are requested only from an explicit settings action.
  Future<void> configure({
    required bool enabled,
    required bool automatic,
  }) async {
    if (_closed || !supported) return;
    final configuration = ++_configuration;
    if (enabled) await _requestPermissions();
    if (_closed || _configuration != configuration) return;
    await settings.setNearbyAutomatic(automatic);
    if (_closed || _configuration != configuration) return;
    await settings.setNearbyEnabled(enabled);
    error = null;
    await _refreshing;
    await _stop();
    await refresh();
  }

  Future<void> setScanner(bool value) async {
    if (_closed || !supported) return;
    final configuration = ++_configuration;
    if (value) await _requestPermissions();
    if (_closed || _configuration != configuration) return;
    await settings.setProximityScanner(value);
    error = null;
    await _refreshing;
    if (!value) {
      _observations.clear();
      _labels.clear();
    }
    await refresh();
  }

  Future<void> _requestPermissions() async {
    final caps = await _capabilities();
    if (defaultTargetPlatform == TargetPlatform.android) {
      final sdk = caps['sdk'] as int? ?? 0;
      final permissions = [
        if (sdk >= 33) Permission.nearbyWifiDevices,
        Permission.locationWhenInUse,
        if (sdk >= 31) ...[
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.bluetoothAdvertise,
        ],
        if (sdk >= 33) Permission.notification,
      ];
      await permissions.request();
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      await Permission.bluetooth.request();
    }
    await _native.invokeMethod<void>('rearm');
  }

  Future<void> refresh() {
    if (_closed || !supported || _queue == null) return Future<void>.value();
    return _refreshing ??= _refreshOnce().whenComplete(
      () => _refreshing = null,
    );
  }

  Future<void> _refreshOnce() async {
    try {
      await _stopping;
      final caps = await _capabilities();
      if (_closed) return;
      awarePairingAvailable = caps['awarePairing'] == true;
      final runtime =
          'aware=${caps['awareSupported'] == true} '
          'wifiReady=${caps['wifiReady'] == true} '
          'bleReady=${caps['bluetoothReady'] == true} '
          'pairing=${caps['awarePairingSupported'] == true || awarePairingAvailable} '
          'enabled=$enabled automatic=$automatic scanner=$scannerEnabled';
      if (_lastRuntime != runtime) {
        _lastRuntime = runtime;
        HearthDiagnostics.log('nearby capability $runtime');
      }
      if (caps['stopped'] == true && _wanted) {
        await settings.setNearbyEnabled(false);
        await settings.setProximityScanner(false);
      }
      internet = switch (caps['internet']) {
        'online' => InternetReachability.online,
        'offline' => InternetReachability.offline,
        _ => InternetReachability.unknown,
      };
      _permissionStatus = caps['locationEnabled'] == false
          ? 'Location services disabled'
          : caps['radioReady'] == false
          ? 'Wi-Fi and Bluetooth unavailable'
          : 'Nearby or notification permission required';
      activation = _policy.evaluate(
        enabled: _wanted,
        automatic: automatic && !scannerEnabled,
        internet: internet,
        permitted: caps['permitted'] == true && caps['radioReady'] != false,
        now: DateTime.now(),
      );
      if (activation == NearbyActivation.active && !_running) {
        _courier = enabled
            ? NearbyCourier(queue: _queue!, onPacket: _deliver)
            : null;
        _mux = NearbyMux(
          onEvent: (medium, event) {
            HearthDiagnostics.log('nearby link ${medium.name} ${event.name}');
          },
          onPeer: (link) async {
            final courier = _courier;
            if (courier != null) {
              await courier.attach(link);
            } else {
              // Scanner-only mode neither stores nor forwards messages.
              link.incoming.listen((_) {}, onError: (Object _) {});
            }
          },
          onChanged: () {
            if (!_closed) {
              final peers = connectedPeers.values;
              final summary =
                  'aware=${peers.where((m) => m == NearbyMedium.wifiAware).length} '
                  'ble=${peers.where((m) => m == NearbyMedium.bluetooth).length}';
              if (_lastPeers != summary) {
                _lastPeers = summary;
                HearthDiagnostics.log('nearby secure peers $summary');
              }
              notifyListeners();
            }
          },
        );
        _running = true;
        try {
          await _native
              .invokeMethod<void>('serviceStart')
              .timeout(const Duration(seconds: 10));
          if (_closed || !_wanted) {
            await _stop();
            return;
          }
          error = null;
        } catch (_) {
          await _stop();
          error = 'Nearby background start blocked by the system';
        }
      } else if (activation != NearbyActivation.active && _running) {
        await _stop();
      }
      if (_running && _wifiRunning && caps['wifiReady'] == false) {
        _wifiRunning = false;
        await _native
            .invokeMethod<void>('stop')
            .timeout(const Duration(seconds: 5));
      }
      if (_running &&
          _bluetoothRunning &&
          (caps['bluetoothReady'] == false || !_bluetooth.active)) {
        _bluetoothRunning = false;
        await _bluetooth.stop();
      }
      if (_running && !_wifiRunning && caps['wifiReady'] != false) {
        try {
          _wifiRunning = true;
          await _native
              .invokeMethod<void>('start')
              .timeout(const Duration(seconds: 10));
        } catch (_) {
          _wifiRunning = false;
          error = 'Nearby Wi-Fi unavailable';
        }
      }
      if (_running && !_bluetoothRunning && caps['bluetoothReady'] == true) {
        try {
          await _bluetooth.start(
            onLink: (link) async {
              final mux = _mux;
              if (mux == null || !_running) {
                await link.close();
                return;
              }
              await mux.add(link, NearbyMedium.bluetooth);
            },
            onSignal: _signal,
          );
          _bluetoothRunning = true;
        } catch (_) {
          error = 'Bluetooth unavailable; check permissions and radio';
        }
      }
      if (enabled) {
        await _refreshRoutes();
        await _queue!.prune();
        for (final packet in _queue!.packets) {
          if (_closed || !enabled) break;
          await _deliver(packet);
        }
      }
    } catch (_) {
      error = 'Nearby messaging unavailable';
    } finally {
      if (!_closed) notifyListeners();
    }
  }

  void _signal(String id, int rssi) {
    if (_closed || !scannerEnabled || !_running) return;
    if (!_observations.containsKey(id) && _observations.length >= 128) {
      _observations.remove(_observations.keys.first);
    }
    final now = DateTime.now();
    final item = _observations.putIfAbsent(
      id,
      () => ProximityObservation(id, now),
    );
    item.update(rssi, now);
    // The scanner repaints on its bounded five-second sampling clock.
  }

  Future<void> _refreshRoutes() async {
    final routes = <String, ChannelSession>{};
    final current = sessions().toSet();
    for (final old in _sessionSubs.keys.toList()) {
      if (!current.contains(old)) await _sessionSubs.remove(old)?.cancel();
    }
    for (final session in current) {
      routes[await _route(session.channelId)] = session;
      _sessionSubs.putIfAbsent(
        session,
        () => session.engine.stored.listen((message) {
          unawaited(_bridge(session, message));
        }),
      );
    }
    _routes
      ..clear()
      ..addAll(routes);
  }

  Future<void> _bridge(ChannelSession session, Message message) async {
    if (_closed ||
        !enabled ||
        _bridging >= 2 ||
        _forwardedInner.contains(message.idHex) ||
        listEquals(message.device ?? message.author, identity.publicKey)) {
      return;
    }
    final age = DateTime.now().millisecondsSinceEpoch - message.timestampMs;
    if (age < -NearbyPacket.clockSkew.inMilliseconds ||
        age >= NearbyPacket.maxLifetime.inMilliseconds) {
      return;
    }
    _bridging++;
    try {
      final content = parseContent(
        await session.cipher.decrypt(
          message.payload,
          senderDevice: message.device,
        ),
      );
      await publish(session, message, content, local: false);
    } catch (_) {
      // Not every accepted DAG item is decryptable text for this device.
    } finally {
      _bridging--;
    }
  }

  void _rememberInner(String id) {
    _forwardedInner.add(id);
    if (_forwardedInner.length > 1024) {
      _forwardedInner.remove(_forwardedInner.first);
    }
  }

  static Future<String> _route(String channel) async => hex.encode(
    await sha256Digest(utf8.encode('hearth/nearby-route/v1|$channel')),
  );

  static bool _text(Content content) =>
      content is TextContent ||
      content is EditContent ||
      content is DeleteContent;

  Future<void> publish(
    ChannelSession session,
    Message message,
    Content content, {
    bool local = true,
  }) async {
    if (!enabled ||
        _closed ||
        _queue == null ||
        !_text(content) ||
        !sessions().contains(session)) {
      return;
    }
    if (_forwardedInner.contains(message.idHex)) return;
    _rememberInner(message.idHex);
    try {
      final now = DateTime.now();
      final created = DateTime.fromMillisecondsSinceEpoch(message.timestampMs);
      if (created.isAfter(now.add(NearbyPacket.clockSkew)) ||
          !created.add(NearbyPacket.maxLifetime).isAfter(now)) {
        return;
      }
      final body = await session.cipher.encrypt(
        utf8.encode(jsonEncode(message.toJson())),
      );
      if (body.length > NearbyPacket.maxBodyBytes) {
        error = 'Message too large for nearby delivery';
        notifyListeners();
        return;
      }
      final packet = await NearbyPacket.create(
        sender: identity,
        route: await _route(session.channelId),
        encryptedBody: body,
        // A WAN bridge cannot renew an old message's nearby lifetime.
        now: created.isAfter(now) ? now : created,
      );
      if (_closed || !enabled || !sessions().contains(session)) return;
      final result = await _queue!.add(packet, local: local);
      if (result == NearbyAdmission.stored) {
        // Durable custody must not make normal sends wait on a slow radio.
        unawaited(_courier?.reconcile().catchError((Object _) {}));
      }
      if (result == NearbyAdmission.full || result == NearbyAdmission.busy) {
        error = 'Nearby queue full; normal delivery remains available';
      }
    } catch (_) {
      error = 'Could not queue nearby message';
    }
    if (!_closed) notifyListeners();
  }

  Future<void> _deliver(NearbyPacket packet) async {
    if (_closed || !enabled || _delivered.contains(packet.id)) return;
    final session = _routes[packet.route];
    if (session == null) return;
    final now = DateTime.now();
    final attempted = _deliveryAttempts[packet.id];
    if (attempted != null &&
        now.difference(attempted) < const Duration(minutes: 1)) {
      return;
    }
    if (_deliveryAttempts.length >= 256) {
      _deliveryAttempts.remove(_deliveryAttempts.keys.first);
    }
    _deliveryAttempts[packet.id] = now;
    try {
      final plain = await session.cipher.decrypt(packet.body);
      final json = jsonDecode(utf8.decode(plain));
      if (json is! Map<String, dynamic>) return;
      final message = Message.fromJson(json.cast<String, Object?>());
      if (message.channel != session.channelId || !await message.verify()) {
        return;
      }
      final content = parseContent(
        await session.cipher.decrypt(
          message.payload,
          senderDevice: message.device,
        ),
      );
      if (!_text(content) ||
          _closed ||
          !enabled ||
          !sessions().contains(session)) {
        return;
      }
      // receive() applies the existing block/revocation/DM-author checks and
      // propagates accepted text to existing WebRTC peers as usual.
      _rememberInner(message.idHex);
      await session.engine.receive(message);
      if (session.repository.getByHex(message.idHex) == null) return;
      _delivered.add(packet.id);
      if (_delivered.length > 512) _delivered.remove(_delivered.first);
    } catch (_) {
      // It may be foreign traffic, or the channel/device key is not known yet.
    }
  }

  void _event(dynamic value) {
    if (_closed || value is! Map) return;
    final type = value['type'];
    if (type == 'stopped') {
      HearthDiagnostics.log('nearby notification stop');
      unawaited(
        () async {
          await settings.setProximityScanner(false);
          await configure(enabled: false, automatic: automatic);
        }().catchError((Object _) {}),
      );
      return;
    }
    if (!_running) return;
    if (type == 'pairingState') {
      final state = value['state'];
      if (const {
        'ready',
        'verified',
        'paired',
        'selected',
        'reconnecting',
        'rejected',
        'unavailable',
      }.contains(state)) {
        HearthDiagnostics.log('nearby Aware pairing $state');
      }
    } else if (type == 'error') {
      HearthDiagnostics.log('nearby native Aware error');
      error = value['message'] as String? ?? 'Nearby radio unavailable';
      _wifiRunning = false;
      // A Wi-Fi failure must not tear down working Bluetooth links/service.
      notifyListeners();
    } else if (type == 'linkUp' && value['id'] is String) {
      HearthDiagnostics.log('nearby native Aware link ready; securing');
      final id = value['id'] as String;
      if (_links.containsKey(id)) return;
      final link = _NativeNearbyLink(id, _native);
      _links[id] = link;
      unawaited(
        _mux!.add(link, NearbyMedium.wifiAware).then((_) {
          if (!_closed) notifyListeners();
        }),
      );
    } else if (type == 'linkDown' && value['id'] is String) {
      final id = value['id'] as String;
      _links.remove(id);
      unawaited(_mux?.remove(id));
      notifyListeners();
    } else if (type == 'bytes' &&
        value['id'] is String &&
        value['bytes'] is Uint8List) {
      final link = _links[value['id']];
      final bytes = value['bytes'] as Uint8List;
      if (link != null &&
          !link.closed &&
          bytes.length <= NearbyMux.maxWireBytes) {
        link.controller.add(bytes);
      }
    }
  }

  Future<void> _stop() =>
      _stopping ??= _stopOnce().whenComplete(() => _stopping = null);

  Future<void> _stopOnce() async {
    _running = false;
    _wifiRunning = false;
    _bluetoothRunning = false;
    await _bluetooth.stop();
    final mux = _mux;
    _mux = null;
    await mux?.close();
    final courier = _courier;
    _courier = null;
    await courier?.close();
    _links.clear();
    _observations.clear();
    _labels.clear();
    _nextLabel = 1;
    try {
      await _native
          .invokeMethod<void>('stop')
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
    try {
      await _native
          .invokeMethod<void>('serviceStop')
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  Future<void> clearQueue() async {
    if (_closed) return;
    await _queue?.clear();
    if (!_closed) notifyListeners();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _signalTimer?.cancel();
    await _sub?.cancel();
    await _refreshing;
    for (final sub in _sessionSubs.values) {
      await sub.cancel();
    }
    _sessionSubs.clear();
    await _stop();
    super.dispose();
  }
}

class _NativeNearbyLink implements NearbyLink {
  _NativeNearbyLink(this.id, this.native);
  @override
  final String id;
  final MethodChannel native;
  final controller = StreamController<Uint8List>();
  bool closed = false;
  @override
  Stream<Uint8List> get incoming => controller.stream;
  @override
  Future<void> send(Uint8List bytes) =>
      native.invokeMethod<void>('send', {'id': id, 'bytes': bytes});
  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    unawaited(controller.close());
    try {
      await native
          .invokeMethod<void>('disconnect', {'id': id})
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }
}

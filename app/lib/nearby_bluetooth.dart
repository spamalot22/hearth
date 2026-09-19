// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' as ble;
import 'package:core/core.dart';
import 'package:flutter/foundation.dart';

abstract interface class NearbyBluetoothRadio {
  bool get active;
  Future<void> start({
    required Future<void> Function(NearbyLink) onLink,
    required void Function(String, int) onSignal,
  });
  Future<void> scanSignals();
  Future<void> stop();
}

/// Both mobile platforms expose the same GATT service. No account identifier,
/// contact list, or plaintext is advertised. Wi-Fi remains independently active.
class NearbyBluetooth implements NearbyBluetoothRadio {
  @override
  bool get active =>
      _running &&
      _central?.state == ble.BluetoothLowEnergyState.poweredOn &&
      _peripheral?.state == ble.BluetoothLowEnergyState.poweredOn;
  static final serviceId = ble.UUID.fromString(
    'd414c310-9ca3-4d25-9bc7-c7c071877461',
  );
  static final dataId = ble.UUID.fromString(
    'd414c311-9ca3-4d25-9bc7-c7c071877461',
  );
  ble.CentralManager? _central;
  ble.PeripheralManager? _peripheral;
  final _subs = <StreamSubscription<dynamic>>[];
  final _links = <String, _BluetoothLink>{};
  final _connecting = <String, ble.Peripheral>{};
  final _remote = <String, ble.Peripheral>{};
  final _retryAfter = <String, DateTime>{};
  final _subscribing = <String>{};
  Timer? _scanTimer;
  Timer? _scanStop;
  Timer? _idleTimer;
  bool _running = false;
  int _epoch = 0;
  bool _reading = false;
  ble.GATTService? _service;
  late ble.GATTCharacteristic _data;
  late Future<void> Function(NearbyLink) _onLink;
  late void Function(String, int) _onSignal;

  static String _client(ble.Peripheral peer) => 'ble-out:${peer.uuid}';
  static String _server(ble.Central peer) => 'ble-in:${peer.uuid}';
  bool _valid(int epoch) => _running && _epoch == epoch;
  void _ignore(Future<void> work) => unawaited(work.catchError((Object _) {}));

  @override
  Future<void> start({
    required Future<void> Function(NearbyLink) onLink,
    required void Function(String, int) onSignal,
  }) async {
    if (_running) return;
    _onLink = onLink;
    _onSignal = onSignal;
    final c = _central ??= ble.CentralManager();
    final p = _peripheral ??= ble.PeripheralManager();
    _running = true;
    final epoch = ++_epoch;
    try {
      await _powered(c);
      await _powered(p);
      if (!_valid(epoch)) return;
      _data = ble.GATTCharacteristic.mutable(
        uuid: dataId,
        properties: [
          ble.GATTCharacteristicProperty.write,
          ble.GATTCharacteristicProperty.indicate,
        ],
        permissions: [ble.GATTCharacteristicPermission.write],
        descriptors: [],
      );
      final service = ble.GATTService(
        uuid: serviceId,
        isPrimary: true,
        includedServices: [],
        characteristics: [_data],
      );
      _service = service;
      _subs.add(
        c.discovered.listen((event) {
          if (!_valid(epoch)) return;
          final id = _client(event.peripheral);
          // Discovery is filtered by service UUID. This is not identity proof.
          _onSignal(id, event.rssi);
          final retry = _retryAfter[id];
          if (_links.containsKey(id) ||
              _connecting.containsKey(id) ||
              _links.length + _connecting.length >= 6 ||
              (retry != null && DateTime.now().isBefore(retry))) {
            return;
          }
          _ignore(_connect(event.peripheral, epoch));
        }),
      );
      _subs.add(
        c.characteristicNotified.listen((event) {
          if (_valid(epoch) && event.characteristic.uuid == dataId) {
            _links[_client(event.peripheral)]?.receive(event.value);
          }
        }),
      );
      _subs.add(
        c.connectionStateChanged.listen((event) {
          if (event.state == ble.ConnectionState.disconnected) {
            _ignore(
              _links[_client(event.peripheral)]?.close() ??
                  Future<void>.value(),
            );
          }
        }),
      );
      _subs.add(
        p.characteristicNotifyStateChanged.listen((event) {
          if (!_valid(epoch) || event.characteristic.uuid != dataId) return;
          final id = _server(event.central);
          if (!event.state) {
            _ignore(_links[id]?.close() ?? Future<void>.value());
          } else if (!_links.containsKey(id) && !_subscribing.contains(id)) {
            _ignore(_subscribe(event.central, epoch));
          }
        }),
      );
      _subs.add(
        p.characteristicWriteRequested.listen((event) {
          _ignore(() async {
            final link = _links[_server(event.central)];
            if (!_valid(epoch) ||
                link == null ||
                event.characteristic.uuid != dataId ||
                event.request.offset != 0 ||
                !link.receive(event.request.value)) {
              await p.respondWriteRequestWithError(
                event.request,
                error: ble.GATTError.invalidPDU,
              );
            } else {
              await p.respondWriteRequest(event.request);
            }
          }());
        }),
      );
      _subs.add(
        p.characteristicReadRequested.listen((event) {
          _ignore(
            p.respondReadRequestWithError(
              event.request,
              error: ble.GATTError.readNotPermitted,
            ),
          );
        }),
      );
      if (defaultTargetPlatform == TargetPlatform.android) {
        _subs.add(
          p.connectionStateChanged.listen((event) {
            if (event.state == ble.ConnectionState.disconnected) {
              _ignore(
                _links[_server(event.central)]?.close() ?? Future<void>.value(),
              );
            }
          }),
        );
      }
      await p.addService(service).timeout(const Duration(seconds: 5));
      if (!_valid(epoch)) return;
      // UUID only: fits legacy 31-byte advertising packets without names.
      await p
          .startAdvertising(ble.Advertisement(serviceUUIDs: [serviceId]))
          .timeout(const Duration(seconds: 5));
      if (!_valid(epoch)) return;
      await _scan(epoch);
      _scanTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _ignore(_scan(epoch)),
      );
      _idleTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        for (final link in _links.values.toList()) {
          if (DateTime.now().difference(link.lastReceived) >
              const Duration(minutes: 2)) {
            _ignore(link.close());
          }
        }
      });
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<void> _powered(ble.BluetoothLowEnergyManager manager) async {
    if (manager.state == ble.BluetoothLowEnergyState.unknown) {
      await manager.stateChanged
          .firstWhere((e) => e.state != ble.BluetoothLowEnergyState.unknown)
          .timeout(const Duration(seconds: 5));
    }
    if (manager.state != ble.BluetoothLowEnergyState.poweredOn) {
      throw StateError('Bluetooth is unavailable or permission was denied');
    }
  }

  Future<void> _scan(int epoch) async {
    if (!_valid(epoch)) return;
    await _central!
        .startDiscovery(serviceUUIDs: [serviceId])
        .timeout(const Duration(seconds: 5));
    if (!_valid(epoch)) {
      await _central!.stopDiscovery();
      return;
    }
    _scanStop?.cancel();
    _scanStop = Timer(const Duration(seconds: 12), () {
      if (_valid(epoch)) _ignore(_central!.stopDiscovery());
    });
  }

  Future<void> _connect(ble.Peripheral peer, int epoch) async {
    final id = _client(peer);
    _connecting[id] = peer;
    _BluetoothLink? candidate;
    try {
      await _central!.connect(peer).timeout(const Duration(seconds: 10));
      if (!_valid(epoch)) throw StateError('Stopped');
      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          await _central!
              .requestMTU(peer, mtu: 512)
              .timeout(const Duration(seconds: 3));
        } catch (_) {}
      }
      final services = await _central!
          .discoverGATT(peer)
          .timeout(const Duration(seconds: 8));
      final data = services
          .where((s) => s.uuid == serviceId)
          .expand((s) => s.characteristics)
          .firstWhere((c) => c.uuid == dataId);
      final maximum = await _central!
          .getMaximumWriteLength(
            peer,
            type: ble.GATTCharacteristicWriteType.withResponse,
          )
          .timeout(const Duration(seconds: 3));
      if (!_valid(epoch)) throw StateError('Stopped');
      late final _BluetoothLink link;
      link = _BluetoothLink(
        id,
        maximum.clamp(20, 512),
        write: (bytes) => _central!.writeCharacteristic(
          peer,
          data,
          value: bytes,
          type: ble.GATTCharacteristicWriteType.withResponse,
        ),
        disconnect: () async {
          if (identical(_links[id], link)) {
            _remote.remove(id);
            _links.remove(id);
            await _central!.disconnect(peer);
          }
        },
      );
      candidate = link;
      _links[id] = link;
      _remote[id] = peer;
      // Buffer the remote hello if it arrives before the subscription returns.
      await _central!
          .setCharacteristicNotifyState(peer, data, state: true)
          .timeout(const Duration(seconds: 5));
      if (!_valid(epoch)) {
        await link.close();
        return;
      }
      await _onLink(link);
    } catch (_) {
      await candidate?.close();
      if (_valid(epoch)) {
        try {
          await _central!.disconnect(peer);
        } catch (_) {}
      }
    } finally {
      if (_epoch == epoch) {
        _connecting.remove(id);
        if (_retryAfter.length >= 128) {
          _retryAfter.remove(_retryAfter.keys.first);
        }
        _retryAfter[id] = DateTime.now().add(const Duration(seconds: 45));
      }
    }
  }

  Future<void> _subscribe(ble.Central peer, int epoch) async {
    final id = _server(peer);
    if (_links.length + _connecting.length + _subscribing.length >= 6) return;
    _subscribing.add(id);
    try {
      if (!_valid(epoch)) return;
      // Install the receiver before awaiting any platform method: the central
      // can send its hello immediately after subscribing.
      late final _BluetoothLink link;
      link = _BluetoothLink(
        id,
        20,
        write: (bytes) =>
            _peripheral!.notifyCharacteristic(peer, _data, value: bytes),
        disconnect: () async {
          if (identical(_links[id], link)) {
            _links.remove(id);
            if (defaultTargetPlatform == TargetPlatform.android) {
              await _peripheral!.disconnect(peer);
            }
          }
        },
      );
      _links[id] = link;
      final maximum = await _peripheral!
          .getMaximumNotifyLength(peer)
          .timeout(const Duration(seconds: 3));
      if (!_valid(epoch) || link._closed) {
        await link.close();
        return;
      }
      link.mtu = maximum.clamp(20, 512);
      await _onLink(link);
    } catch (_) {
      if (_valid(epoch)) await _links[id]?.close();
    } finally {
      if (_epoch == epoch) _subscribing.remove(id);
    }
  }

  @override
  Future<void> scanSignals() async {
    if (!_running || _reading) return;
    _reading = true;
    final epoch = _epoch;
    try {
      for (final item in _remote.entries.toList()) {
        if (!_valid(epoch)) break;
        try {
          final rssi = await _central!
              .readRSSI(item.value)
              .timeout(const Duration(seconds: 2));
          if (_valid(epoch)) _onSignal(item.key, rssi);
        } catch (_) {}
      }
    } finally {
      _reading = false;
    }
  }

  @override
  Future<void> stop() async {
    _running = false;
    _epoch++;
    _scanTimer?.cancel();
    _scanStop?.cancel();
    _idleTimer?.cancel();
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    try {
      await _central?.stopDiscovery().timeout(const Duration(seconds: 3));
    } catch (_) {}
    try {
      await _peripheral?.stopAdvertising().timeout(const Duration(seconds: 3));
    } catch (_) {}
    for (final link in _links.values.toList()) {
      await link.close();
    }
    for (final peer in _connecting.values.toList()) {
      try {
        await _central?.disconnect(peer).timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    _connecting.clear();
    _subscribing.clear();
    _retryAfter.clear();
    final service = _service;
    _service = null;
    if (service != null) {
      try {
        await _peripheral
            ?.removeService(service)
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
  }
}

class _BluetoothLink implements NearbyLink {
  _BluetoothLink(
    this.id,
    this.mtu, {
    required this.write,
    required this.disconnect,
  });
  @override
  final String id;
  int mtu;
  final Future<void> Function(Uint8List) write;
  final Future<void> Function() disconnect;
  final _reader = NearbyFragmentReader();
  final _input = StreamController<Uint8List>();
  DateTime lastReceived = DateTime.now();
  bool _closed = false;
  Future<void> _tail = Future<void>.value();
  int _pending = 0;
  int _sequence = 0;
  int _buffered = 0;
  @override
  Stream<Uint8List> get incoming => _input.stream;
  bool receive(Uint8List bytes) {
    if (_closed) return false;
    try {
      final frame = _reader.add(bytes, DateTime.now());
      if (frame != null) {
        lastReceived = DateTime.now();
        if (!_input.hasListener && ++_buffered > 4) {
          throw StateError('Unclaimed Bluetooth input');
        }
        _input.add(frame);
      }
      return true;
    } catch (_) {
      unawaited(close());
      return false;
    }
  }

  @override
  Future<void> send(Uint8List bytes) async {
    if (_closed || _pending >= 4) {
      throw StateError('Bluetooth link unavailable');
    }
    _pending++;
    final operation = _tail.then((_) async {
      final started = DateTime.now();
      for (final fragment in nearbyFragments(bytes, mtu, _sequence++)) {
        if (_closed ||
            DateTime.now().difference(started) > const Duration(seconds: 60)) {
          throw StateError('Bluetooth send expired');
        }
        await write(fragment).timeout(const Duration(seconds: 5));
      }
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    try {
      await operation;
    } catch (_) {
      await close();
      rethrow;
    } finally {
      _pending--;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    unawaited(_input.close());
    try {
      await disconnect().timeout(const Duration(seconds: 3));
    } catch (_) {}
  }
}

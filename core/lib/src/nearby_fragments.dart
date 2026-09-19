// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import 'nearby_mux.dart';

/// GATT framing independent of the negotiated MTU. One frame is in flight per
/// direction; ordered writes/indications are required. No unbounded buffering.
Iterable<Uint8List> nearbyFragments(
  Uint8List frame,
  int mtu,
  int sequence,
) sync* {
  if (frame.isEmpty ||
      frame.length > NearbyMux.maxWireBytes ||
      mtu < 20 ||
      mtu > 512) {
    throw ArgumentError('Invalid nearby frame or MTU');
  }
  for (var offset = 0; offset < frame.length; offset += mtu - 6) {
    final end = (offset + mtu - 6).clamp(0, frame.length);
    final bytes = Uint8List(6 + end - offset);
    final header = ByteData.sublistView(bytes);
    header.setUint16(0, sequence & 0xffff);
    header.setUint16(2, offset);
    header.setUint16(4, frame.length);
    bytes.setRange(6, bytes.length, frame, offset);
    yield bytes;
  }
}

class NearbyFragmentReader {
  Uint8List? _buffer;
  int _offset = 0;
  int _sequence = -1;
  DateTime? _started;
  DateTime? _window;
  int _bytes = 0;
  int _chunks = 0;

  Uint8List? add(Uint8List fragment, DateTime now) {
    if (_window == null ||
        now.difference(_window!) >= const Duration(minutes: 1)) {
      _window = now;
      _bytes = 0;
      _chunks = 0;
    }
    _bytes += fragment.length;
    _chunks++;
    if (fragment.length < 7 ||
        fragment.length > 512 ||
        _bytes > 512 * 1024 ||
        _chunks > 16000) {
      throw const FormatException('Invalid or excessive nearby fragments');
    }
    final header = ByteData.sublistView(fragment);
    final sequence = header.getUint16(0);
    final offset = header.getUint16(2);
    final total = header.getUint16(4);
    if (total == 0 ||
        total > NearbyMux.maxWireBytes ||
        offset + fragment.length - 6 > total) {
      throw const FormatException('Invalid nearby fragment size');
    }
    if (offset == 0) {
      if (_buffer != null) {
        throw const FormatException('Interleaved nearby frame');
      }
      _buffer = Uint8List(total);
      _sequence = sequence;
      _offset = 0;
      _started = now;
    }
    final buffer = _buffer;
    if (buffer == null ||
        sequence != _sequence ||
        offset != _offset ||
        total != buffer.length ||
        now.difference(_started!) > const Duration(seconds: 90)) {
      throw const FormatException('Out-of-order or expired nearby frame');
    }
    buffer.setRange(offset, offset + fragment.length - 6, fragment, 6);
    _offset += fragment.length - 6;
    if (_offset != total) return null;
    _buffer = null;
    return buffer;
  }
}

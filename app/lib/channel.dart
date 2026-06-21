import 'dart:async';

import 'package:core/core.dart';

import 'message_storage_hive.dart';
import 'webrtc_mesh.dart';

/// One channel's live stack: its durable DAG ([MessageRepository]), gossip
/// [SyncEngine], and — when running for real — the [WebRtcMesh] that feeds peers
/// in. The UI reads [repository] and publishes through [engine].
class ChannelSession {
  ChannelSession._(
    this.channelId,
    this.repository,
    this.engine,
    this._mesh,
    this._updatesSub,
    this._peersSub,
  );

  final String channelId;
  final MessageRepository repository;
  final SyncEngine engine;
  final WebRtcMesh? _mesh;
  final StreamSubscription<void> _updatesSub;
  final StreamSubscription<FrameChannel>? _peersSub;

  /// Opens a channel. With [live] false (widget tests) storage is in-memory and
  /// no mesh runs, so nothing native is touched. [onUpdate] fires whenever this
  /// channel stores a message.
  static Future<ChannelSession> open({
    required String channelId,
    required Identity identity,
    required Uri relayUrl,
    required bool live,
    required void Function() onUpdate,
  }) async {
    final storage = live
        ? await HiveMessageStorage.open(channelId)
        : InMemoryMessageStorage();
    final repository = MessageRepository(storage);
    await repository.load();
    final engine = SyncEngine(repository, channelId);
    final updatesSub = engine.updates.listen((_) => onUpdate());

    WebRtcMesh? mesh;
    StreamSubscription<FrameChannel>? peersSub;
    if (live) {
      mesh = WebRtcMesh(
        baseUrl: relayUrl,
        channel: channelId,
        identity: identity,
      );
      // Each connected peer becomes a gossip session against this channel.
      peersSub = mesh.peerConnected.listen(engine.addPeer);
    }

    return ChannelSession._(
      channelId,
      repository,
      engine,
      mesh,
      updatesSub,
      peersSub,
    );
  }

  Future<void> close() async {
    await _updatesSub.cancel();
    await _peersSub?.cancel();
    await _mesh?.close();
    await engine.close();
  }
}

/// Owns every open [ChannelSession] and tracks which one is active. Channels are
/// opened lazily and kept running (so messages keep arriving in the background);
/// the UI binds to [active].
class ChannelManager {
  ChannelManager({
    required this.identity,
    required this.relayUrl,
    required this.live,
    required this.onUpdate,
  });

  final Identity identity;
  final Uri relayUrl;

  /// False in widget tests — keeps storage in-memory and the mesh off.
  final bool live;

  /// Called when a channel updates or the active selection changes.
  final void Function() onUpdate;

  final Map<String, ChannelSession> _sessions = {};
  String? _activeId;

  /// Open channels, in insertion order.
  Iterable<String> get channelIds => _sessions.keys;
  String? get activeId => _activeId;
  ChannelSession? get active => _activeId == null ? null : _sessions[_activeId];

  /// Opens [channelId] if it isn't already open, then makes it active.
  Future<void> open(String channelId) async {
    if (!_sessions.containsKey(channelId)) {
      _sessions[channelId] = await ChannelSession.open(
        channelId: channelId,
        identity: identity,
        relayUrl: relayUrl,
        live: live,
        onUpdate: onUpdate,
      );
    }
    _activeId = channelId;
    onUpdate();
  }

  /// Switches the active channel to an already-open [channelId].
  void activate(String channelId) {
    if (_sessions.containsKey(channelId)) {
      _activeId = channelId;
      onUpdate();
    }
  }

  Future<void> close() async {
    for (final session in _sessions.values.toList()) {
      await session.close();
    }
    _sessions.clear();
  }
}

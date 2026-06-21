/// Hearth core — identity, signed messages, and (soon) the message DAG.
///
/// Pure Dart with no Flutter imports, so it stays portable across every target
/// and could later be swapped for a Rust module without touching the UI.
library;

export 'src/dag.dart' show MessageStore;
export 'src/encryption.dart' show PairBox, SealedBox, ed25519PublicToX25519;
export 'src/frame.dart'
    show FrameChannel, GiveFrame, HaveFrame, SyncFrame, WantFrame;
export 'src/identity.dart'
    show Identity, InMemoryKeyStore, KeyStore, sha256Digest;
export 'src/message.dart' show Message, kHearthMessageVersion;
export 'src/repository.dart' show MessageRepository;
export 'src/storage.dart' show InMemoryMessageStorage, MessageStorage;
export 'src/sync.dart' show SyncEngine, SyncSession;
export 'src/transport.dart' show RelayTransport, Transport, TransportException;

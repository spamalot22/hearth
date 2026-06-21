/// Hearth core — identity, signed messages, and (soon) the message DAG.
///
/// Pure Dart with no Flutter imports, so it stays portable across every target
/// and could later be swapped for a Rust module without touching the UI.
library;

export 'src/dag.dart' show MessageStore;
export 'src/identity.dart' show Identity, KeyStore, InMemoryKeyStore;
export 'src/message.dart' show Message, kHearthMessageVersion;
export 'src/repository.dart' show MessageRepository;
export 'src/storage.dart' show InMemoryMessageStorage, MessageStorage;
export 'src/transport.dart' show RelayTransport, Transport, TransportException;

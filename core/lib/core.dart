// SPDX-License-Identifier: AGPL-3.0-or-later
/// Hearth core — identity, signed messages, and (soon) the message DAG.
///
/// Pure Dart with no Flutter imports, so it stays portable across every target
/// and could later be swapped for a Rust module without touching the UI.
library;

export 'src/blob.dart'
    show BlobStore, InMemoryBlobStore, blobHash, maxBlobBytes;
export 'src/dag.dart' show MessageStore;
export 'src/device.dart' show DeviceCert, DeviceRevocation;
export 'src/encryption.dart'
    show GroupCipher, PairBox, SealedBox, ed25519PublicToX25519;
export 'src/frame.dart'
    show
        FrameChannel,
        GiveBlobFrame,
        GiveFrame,
        HaveFrame,
        SyncFrame,
        WantBlobFrame,
        WantFrame;
export 'src/identity.dart'
    show Identity, InMemoryKeyStore, KeyStore, sha256Digest;
export 'src/message.dart' show Message, kHearthMessageVersion;
export 'src/mnemonic.dart' show seedToMnemonic, mnemonicToSeed, bip39Words;
export 'src/repository.dart' show MessageRepository;
export 'src/storage.dart' show InMemoryMessageStorage, MessageStorage;
export 'src/sync.dart' show SyncEngine, SyncSession;
export 'src/transport.dart' show RelayTransport, Transport, TransportException;

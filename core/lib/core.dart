// SPDX-License-Identifier: AGPL-3.0-or-later
/// Hearth core — identity, encryption, signed message DAG, and gossip sync.
///
/// Pure Dart with no Flutter imports, so it stays portable across every target
/// and could later be swapped for a Rust module without touching the UI.
library;

export 'src/blob.dart'
    show BlobStore, InMemoryBlobStore, blobHash, maxBlobBytes;
export 'src/dag.dart' show MessageStore;
export 'src/device.dart' show DeviceBundle, DeviceCert, DeviceRevocation;
export 'src/encryption.dart'
    show GroupCipher, MultiDeviceBox, PairBox, SealedBox, ed25519PublicToX25519;
export 'src/frame.dart'
    show
        AckFrame,
        FrameChannel,
        GiveBlobChunkFrame,
        GiveBlobFrame,
        GiveFrame,
        HaveFrame,
        SyncFrame,
        WantBlobFrame,
        WantFrame;
export 'src/identity.dart'
    show Identity, InMemoryKeyStore, KeyStore, sha256Digest;
export 'src/message.dart'
    show Message, kHearthMessageVersion, maxMessagePayloadBytes;
export 'src/mnemonic.dart' show seedToMnemonic, mnemonicToSeed, bip39Words;
export 'src/relay_duty.dart' show RelayDutySchedule;
export 'src/repository.dart'
    show MessageRepository, RepositoryCapacityException;
export 'src/storage.dart' show InMemoryMessageStorage, MessageStorage;
export 'src/sync.dart' show SyncEngine, SyncSession;
export 'src/transport.dart' show RelayTransport, Transport, TransportException;

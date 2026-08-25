# Hearth Core

Pure-Dart protocol and storage primitives for Hearth. This package has no
Flutter dependency and contains the security-critical logic shared by the app:

- Ed25519 root/device identities, certificates, bundles, and revocations.
- Canonically encoded, signed, content-addressed message DAGs.
- X25519/ChaCha20-Poly1305 encryption for sealed, paired, group, and
  multi-device payloads.
- Bounded HAVE/WANT/GIVE/ACK gossip reconciliation and blob transfer.
- Storage and transport interfaces with in-memory test implementations.

The Flutter application supplies persistent Hive stores, WebRTC links, platform
key storage, and UI. The TypeScript relay independently verifies the canonical
message format using locked interoperability fixtures.

```dart
import 'package:core/core.dart';

final identity = await Identity.generate();
```

See the repository [README](../README.md) and
[implementation plan](../IMPLEMENTATION_PLAN.md) for the complete architecture.

Hearth Core is licensed under AGPL-3.0-or-later; see [LICENSE](../LICENSE).

# 🔥 Hearth

**A decentralised, end-to-end-encrypted chat app — a gamer-focused alternative to
Discord/Signal with no servers that own your messages.**

Hearth has no accounts and no central database. Your identity is a keypair on your
device, messages sync **peer-to-peer over WebRTC**, and everything — DMs, group
channels, voice — is **end-to-end encrypted by default**. An optional coordination
relay handles cold-start discovery, bounded encrypted courier traffic, and
provider-backed media search; it can verify authenticity but cannot read messages.

> **Status:** early, fast-moving work in progress. Crypto, message sync, P2P mesh,
> channels, media, voice, identity backup/restore, signed auto-updates, P2P version
> enforcement, relay fallback, and peer-exchange all work today. The relay is
> deployed (self-hosted behind a Tailscale Funnel). See
> [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) for the living plan and the
> decisions log.

---

## Features

- **No accounts.** Your identity is an Ed25519 keypair generated on-device; your
  public key *is* your user id.
- **Multi-device.** Phone and laptop run simultaneously under one identity.
  Each device holds its own subkey certified by the root. The root is recovered
  from a 24-word BIP39 phrase and can optionally be backed up through Android
  Credential Manager or Apple synchronised Keychain. DMs are encrypted per-device;
  revoke a lost device and it is excluded from future key wraps.
- **End-to-end encrypted everywhere** — DMs, group channels, and voice. The relay
  never holds plaintext.
- **Peer-to-peer.** Once peers connect over WebRTC, messages flow directly.
  Low-rate rendezvous and best-effort encrypted courier traffic may continue,
  but the relay is never the source of truth.
- **Invite-only channels.** A channel is an unguessable capability (random id +
  key) shared via an invite code. You name channels and people locally
  (petnames) — nothing is published.
- **Rich media** — emoji, GIFs, stickers, and soundboards. All media is stored as
  content-addressed blobs **on each device** and transferred P2P; search (GIF via
  Giphy, sounds via Freesound) is proxied through the relay so API keys stay
  server-side.
- **Voice chat** per channel (Discord-style join/leave) with mute, deafen,
  per-user volume, join/leave cues, and live speaking indicators.
- **Offline delivery is epidemic, not routed** — any peer can carry and re-serve
  another's (signed, sealed) messages without being able to forge or read them.
- **Signed auto-updates with P2P enforcement** — a release signing key (Ed25519)
  produces manifests published with GitHub Releases; peers can propagate them
  epidemically. The app verifies the signature and asset hashes against a
  hardcoded public key. Numeric version ordering plus a monotonic sequence prevent
  downgrades.
- **Peer-exchange & cached peers** — once you hold a single live link, peers in
  that shared channel introduce each other and carry authenticated SDP/ICE, so
  the mesh can re-knit without the relay. Successfully reached peer identities
  are cached locally for quick retries; historical/offline contacts are not
  broadcast, avoiding unnecessary social-graph disclosure.
- **Authenticated signalling and presence** — announce requests are
  Ed25519-signed; group announcements additionally prove possession of the
  channel key; and signal mailbox reads require a short-lived token. Clients
  verify relay-returned presence claims themselves and distinguish relay-visible
  members from peers with a direct connection.
- **Distributed relay duty** — connected channel components rotate two relay
  workers, with handoff overlap, while other peers pause routine announce,
  signal, and courier polling after a bounded mailbox drain. Worker selection is
  derived locally from time-varying hashes of authenticated device links and
  grants no message or membership authority. Every standby performs a staggered
  fail-safe probe at least every two minutes, bounding recovery when workers are
  suspended, malicious, or unable to reach the relay.

---

## Architecture

The guiding principle: **clients are the source of truth; the server is a
disposable convenience.**

```
┌─────────────── Device A ───────────────┐        ┌─────────────── Device B ───────────────┐
│  Flutter app (UI)                       │        │  Flutter app (UI)                       │
│  ├─ Identity (root + device keys)       │        │  ├─ Identity (root + device keys)       │
│  ├─ Hive (messages, contacts, channels, │        │  ├─ Hive (…)                            │
│  │        blobs, media, local state)    │        │  │                                      │
│  └─ core (pure Dart)                    │        │  └─ core (pure Dart)                    │
│     ├─ Message DAG (signed, hashed)     │        │     ├─ Message DAG                      │
│     ├─ SyncEngine (HAVE/WANT/GIVE/ACK)  │        │     ├─ SyncEngine                       │
│     └─ Encryption (MultiDevice/Group)   │        │     └─ Encryption                       │
└───────┬─────────────────────────────┬───┘        └───┬─────────────────────────────┬──────┘
        │  encrypted data channel (gossip + blobs)      │
        └───────────────  WebRTC P2P  ──────────────────┘   ← messages/voice go here
        │                                                │
        │   signalling + presence only (SDP/ICE),        │
        └──────────────►   Relay (Hono)   ◄──────────────┘   ← never sees plaintext
                         /announce /peers /signal
                         /messages /poll  (offline courier)
                         /gif/search /sound/search (keyed proxy)
```

### Identity
An Ed25519 **root identity** ([`core/lib/src/identity.dart`](core/lib/src/identity.dart))
is the stable user id, shown as `hearth#<fingerprint>` until you assign a local
petname. There is no registration or server-side account. Each installed device
uses a separate Ed25519 subkey and derives X25519 keys for encryption.

**Multi-device:** your root identity certifies per-device subkeys
([`core/lib/src/device.dart`](core/lib/src/device.dart)). Each device holds only
its subkey — messages are authored by the root but signed by the device, carrying
a certificate so peers verify the chain. Enrollment derives the root from the
recovery phrase or optional synced credential, signs the device certificate and
bundle, then removes the root from device-local runtime storage. DMs use
`MultiDeviceBox`; revocation excludes a device from future key wraps.

### Messages — a signed, content-addressed DAG
A message ([`message.dart`](core/lib/src/message.dart)) carries its author,
channel, payload, and links to the previous messages it saw (`prev`). It is
**Ed25519-signed** and **content-addressed** (its id is `multihash(sha256)` of its
bytes), so it can't be forged or altered without detection. Messages form an
append-only **DAG** ([`dag.dart`](core/lib/src/dag.dart)) reconciled as a CRDT:
peers exchange heads and converge to the same deterministic topological order
regardless of arrival order or duplication.

### Transport — WebRTC mesh + gossip
[`app/lib/webrtc_mesh.dart`](app/lib/webrtc_mesh.dart) maintains a **full mesh**:
one `RTCPeerConnection` per peer. The relay provides cold-start rendezvous and
bounded encrypted courier holding; it never acts as a WebRTC media or data
transport. To avoid glare,
the peer with the greater public key offers. **Signalling is authenticated**: every
offer/answer/ICE is Ed25519-signed and verified ([`signal_auth.dart`](app/lib/signal_auth.dart));
group signals also carry a channel-key HMAC. A malicious relay therefore cannot
impersonate a peer, swap a DTLS fingerprint, or introduce its own identity into a
group mesh.

The same signed announcements provide short-lived relay-visible presence. Group
presence also carries a channel-key HMAC, and clients independently verify both
proofs before showing a member online. Presence only decorates identities already
known locally; it is not accepted as membership evidence. A small relay icon
distinguishes this fallback status from a direct WebRTC connection; it does not
imply that the relay can read messages or join voice.

After one data channel opens, peer exchange becomes the signalling network:
connected members introduce all sides of the shared channel and forward those
same signed SDP/ICE envelopes. Reverse routes are learned from authenticated
traffic; bounded hop counts, per-link rate limits, and short-lived deduplication
stop loops and amplification. Successfully peer-routed signalling is not copied
to the relay. If repeated P2P-routed attempts fail, or every live link is lost,
the relay (or another future bootstrap mechanism) is used only to exchange fresh
signed SDP/ICE for another direct attempt.

Once a data channel opens, a **`SyncEngine`** ([`sync.dart`](core/lib/src/sync.dart))
gossips messages with `HAVE`/`WANT`/`GIVE` frames and **verifies every message on
receipt** — so any peer can relay anyone's messages without being trusted.

### Encryption — E2E by default
[`encryption.dart`](core/lib/src/encryption.dart), built on ChaCha20-Poly1305 +
HKDF-SHA256:
- **`MultiDeviceBox`** — DMs, wrapped for every active sender and recipient device.
- **`GroupCipher`** — epoch-labelled group-channel keys; device revocation can
  rotate and wrap a replacement key to remaining authorised devices.
- **`PairBox` / `SealedBox`** — retained lower-level and legacy-compatible
  primitives used by the encryption layer and tests.

The message envelope (text / gif / sticker / sound) is encrypted *inside* the
signed message payload, so encryption composes with the DAG and the relay only
ever sees ciphertext.

### Channels & DMs
A **group channel** ([`group_channel.dart`](app/lib/group_channel.dart)) is a
*capability*: a random unguessable id + a 32-byte encryption key + a local name.
You create one or join via an **invite code** (`hearth:<base64url(id,key,name)>`).
Two people who both make a "games" channel get different ids — no collisions, and
only invitees can find it. **DMs** use a deterministic channel id derived from the
two sorted root pubkeys and `MultiDeviceBox` encryption, so every enrolled device
for either contact can decrypt them.

### Media — content-addressed blobs
GIFs, stickers, and soundboard clips are stored as **content-addressed blobs**
([`blob.dart`](core/lib/src/blob.dart)) — a blob's id is its hash, so a reference
can't be forged. Bytes are fetched **on demand** from peers (`WantBlob`/`GiveBlob`),
never gossiped to everyone, and persisted locally, so received media joins your
re-usable **media library**. Search is **proxied through the relay** so provider
API keys never ship in the client: `/gif/search` (Giphy) and `/sound/search`
(Freesound, filtered to CC0). A chosen result is fetched once and turned into a
local blob — after that it's pure P2P, with no CDN dependency at render.

### Voice
[`app/lib/voice.dart`](app/lib/voice.dart) runs a **second `WebRtcMesh`** on a
`voice:<channelId>` namespace, carrying the mic. The mic track is added *before*
the offer so audio rides in the initial SDP — no renegotiation is bolted onto the
gossip-critical mesh. Includes mute, deafen, per-user volume, generated join/leave
cues every client plays locally, and live speaking indicators driven by WebRTC
`audioLevel` stats. Voice occupancy is announced directly to channel peers and,
when the relay is reachable, as a short-lived independently signed flag on the
channel's existing presence heartbeat. That fallback only keeps the participant
count accurate; voice media is always direct P2P and never traverses the relay.
Voice signalling first travels over the already-established channel data mesh,
including bounded forwarding by shared channel peers. Relay rendezvous is enabled
only after that direct path has had time to connect.

### AI bot (local LLM, decentralised hosting)
[`app/lib/inference_bot.dart`](app/lib/inference_bot.dart) provides an **@bot**
you can mention in any channel. The bot runs a GGUF model locally on whichever
peer has one installed — inference is **not distributed** across devices (the full
model runs on one machine), but hosting is **decentralised**: there's no AI server,
any peer can volunteer by downloading a model in Settings → AI. Requests are
broadcast via the mesh; the first available peer responds. Uses llama.cpp under
the hood (via fllama FFI); runs on CPU by default, with automatic GPU offload on
macOS (Metal) and Linux/Windows (CUDA if available).

### The relay (backend)
[`backend/`](backend) is a small **Hono** app, and a *dumb relay*: it verifies each
message's signature but **never decrypts or owns history**. It's reduced to a
**coordination service**: cold-start signalling, a bounded encrypted courier
store, and media-search proxies. Direct P2P is preferred. DMs can skip a courier
upload only when a device owned by the remote identity confirms durable receipt;
group messages retain the fallback because an arbitrary group member is not a
custody authority.
Settled components rotate two redundant relay workers instead of making every
client poll independently. Peerless or handshaking clients
immediately resume their own relay activity; outgoing workers drain signalling
through the relay TTL window before reducing activity. Standbys make staggered,
low-frequency probes so worker failure cannot suppress relay access indefinitely.
The relay is optional,
swappable, and designed to self-host as one in-memory Docker container behind a
tunnel. The current deployment uses Portainer + Tailscale Funnel.
Each relay process publishes a random `relayEpoch`; clients bind their signalling
and courier cursors to that generation and reset them after a container restart
or relay failover, because the relay's in-memory sequence numbers restart at zero.

When WebRTC ICE fails completely, Hearth reports that no direct route is
available. Without TURN, two incompatible symmetric NATs cannot exchange voice
or live data; relay signalling can discover fresh candidates but cannot make an
impossible direct path work.

---

## Repository layout

```
core/      Pure-Dart, platform-agnostic engine (no Flutter):
           identity, message DAG, encryption, blobs, sync/gossip, frames.
app/       Flutter client (web + mobile/desktop): UI, WebRTC mesh, voice,
           Hive storage, media library, channel/contact management.
backend/   TypeScript Hono relay: rendezvous, encrypted courier, and
           media-search proxies. In-memory; self-hosted in Docker via Tailscale.
IMPLEMENTATION_PLAN.md   Living plan, architecture decisions log, roadmap.
```

## Tech stack

- **Client:** Flutter / Dart, `flutter_webrtc`, `hive_ce` (IndexedDB on web, files
  native), `audioplayers`, `file_picker`.
- **Crypto:** the `cryptography` package — Ed25519, X25519, ChaCha20-Poly1305,
  HKDF-SHA256.
- **Backend:** TypeScript, [Hono](https://hono.dev), run with `tsx`; **pnpm**.
  Self-hosted as a Docker container, tunnelled (Tailscale Funnel); shipped via
  GitHub Actions on a version tag → GHCR.
- **Quality:** `flutter analyze` + Dart/TS tests (`vitest`), `lefthook` pre-commit
  (format + analyze + typecheck).

## License

Hearth is licensed under the **GNU Affero General Public License v3.0**
(AGPL-3.0) — see [`LICENSE`](LICENSE). You're free to use, study, modify, and
share it; but any modified version you distribute **or run as a network service**
must make its source available under the same terms. (It's the license Signal
uses — it keeps Hearth, and any hosted fork, open.)

© 2026 the Hearth contributors.

---

## Getting started

**Prerequisites:** Flutter SDK (with Dart), Node.js, and `pnpm`.

**1. Run the relay** (signalling, on `http://localhost:8787`):

```bash
pnpm -C backend install
pnpm -C backend dev
```

**2. Run the app** (web is the quickest target):

```bash
cd app
flutter pub get
flutter run -d chrome            # or: flutter run -d web-server --web-port 8473
```

**3. Test peer-to-peer.** Open the app in **two windows** (e.g. a normal window
and an incognito one so they get separate identities). In one, create a channel
and copy its invite; in the other, join with the invite. Messages, media, and
voice flow directly between them.

### Configuration (optional)

Media **search** needs provider API keys, which live on the relay — never in the
client. Create `backend/.env` (git-ignored):

```bash
GIPHY_KEY=your_giphy_beta_key        # enables GIF search (else: paste-a-URL fallback)
FREESOUND_KEY=your_freesound_token   # enables sound search (CC0-filtered)
```

Without them, GIFs fall back to pasting a URL and sound search is simply
unavailable — everything else works.

## Testing & quality

Local verification should stay lightweight on constrained development hosts:

```bash
dart test core/test             # engine tests
pnpm -C backend test            # relay tests (vitest)
flutter analyze app             # client static analysis
```

GitHub Actions runs the Flutter widget tests and native Android/Windows builds.
See [`AGENTS.md`](AGENTS.md) before running resource-heavy tasks locally.

A `lefthook` pre-commit hook runs format + analyze + backend typecheck.

---

## Security model (in brief)

- Messages are **signed** (authenticity/integrity) and **encrypted** (DMs/groups),
  so the relay and any couriering peer see only ciphertext they can't forge.
- Signalling is **authenticated**, so the relay can't MITM the WebRTC handshake.
- **Signal mailbox reads are token-gated** — announces are Ed25519-signed and
  return a short-lived token; reading your signal mailbox requires the token, so
  strangers can't observe your ICE candidates.
- **Relay-visible presence is verified client-side** — the relay returns the
  peer's original short-lived signed announcement, with a channel-key proof for
  groups. It can suppress status, but cannot forge an accepted member claim.
- **Auto-updates are signature-verified** — clients fetch the latest manifest
  from GitHub Releases and peers may relay it, but the app trusts it only when it
  is signed by the hardcoded release key. GitHub or a peer can withhold an update,
  but cannot forge one.
- **Windows uses a per-user installer** — Hearth installs under
  `%LOCALAPPDATA%\Programs\Hearth`, creates Start Menu/uninstall entries, and
  applies verified updates through the installer.
- **Per-pubkey rate limiting** on signal and message endpoints prevents mailbox
  flooding from anonymous attackers.
- **Courier mailbox IDs are capabilities** carried in a request header rather
  than the URL, keeping them out of routine reverse-proxy access logs. Messages
  are still independently signature-checked by both the relay and recipient.
- **What the relay still learns:** that a peer is online, who they're signalling
  with, and (for media search) your search terms — proxying hides your IP from the
  GIF/sound provider, but the relay sees the query. Hiding *who a message is for*
  (sealed sender) is on the roadmap.
- **Identity backup:** your identity is backed up as a 24-word BIP39 recovery
  phrase. Optional Android Credential Manager or Apple synchronised-Keychain
  backup may retain an encrypted copy for enrollment; otherwise the root is
  derived transiently and discarded. Hearth's relay never holds it.
- **Per-device DM encryption:** DMs are encrypted to each of the recipient's
  active device keys individually (`MultiDeviceBox`). Revoking a device excludes
  it from the key wrap — it physically cannot decrypt future messages.

## Roadmap

- [ ] **Authenticated LAN discovery and local signalling.** This would enable
  relay-free same-network cold starts, but it is deliberately deferred.

Highlights from [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md): forward-secret
DM/group key management, optional group governance and member eviction,
independent cold-start discovery, secondary-platform releases, federation, and
public-directory spam resistance. The plan also keeps a dated decisions log.

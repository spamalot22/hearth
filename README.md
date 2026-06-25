# 🔥 Hearth

**A decentralised, end-to-end-encrypted chat app — a gamer-focused alternative to
Discord/Signal with no servers that own your messages.**

Hearth has no accounts and no central database. Your identity is a keypair on your
device, messages sync **peer-to-peer over WebRTC**, and everything — DMs, group
channels, voice — is **end-to-end encrypted by default**. An optional relay exists
only to introduce peers to each other (and to courier messages to people who are
offline); it can verify that a message is authentic but can never read it.

> **Status:** early, fast-moving work in progress. Crypto, message sync, P2P mesh,
> channels, media, voice, and identity backup/restore work locally today; it does
> not yet run off `localhost` (the relay isn't deployed). See
> [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) for the living plan and the
> decisions log.

---

## Features

- **No accounts.** Your identity is an Ed25519 keypair generated on-device; your
  public key *is* your user id.
- **End-to-end encrypted everywhere** — DMs, group channels, and voice. The relay
  never holds plaintext.
- **Peer-to-peer.** Once two peers connect over WebRTC, messages flow directly
  between them; the backend is out of the loop.
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

---

## Architecture

The guiding principle: **clients are the source of truth; the server is a
disposable convenience.**

```
┌─────────────── Device A ───────────────┐        ┌─────────────── Device B ───────────────┐
│  Flutter app (UI)                       │        │  Flutter app (UI)                       │
│  ├─ Identity (Ed25519 keypair)          │        │  ├─ Identity (Ed25519 keypair)          │
│  ├─ Hive (messages, contacts, channels, │        │  ├─ Hive (…)                            │
│  │        blobs, media, identity seed)  │        │  │                                      │
│  └─ core (pure Dart)                    │        │  └─ core (pure Dart)                    │
│     ├─ Message DAG (signed, hashed)     │        │     ├─ Message DAG                      │
│     ├─ SyncEngine (HAVE/WANT/GIVE)      │        │     ├─ SyncEngine                       │
│     └─ Encryption (Sealed/Pair/Group)   │        │     └─ Encryption                       │
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
Each device generates an **Ed25519 keypair** ([`core/lib/src/identity.dart`](core/lib/src/identity.dart));
the public key is the user id, shown as `hearth#<fingerprint>` until you give the
person a local petname. The secret seed is held in secure storage. There is no
registration and no server-side account. An X25519 key for encryption is derived
from the same Ed25519 key (birational conversion), so one identity covers both
signing and key agreement.

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
one `RTCPeerConnection` per peer. The relay is used only for **rendezvous** —
announce presence, discover peers, and trade SDP/ICE. To avoid glare, the peer
with the greater public key offers. **Signalling is authenticated**: every
offer/answer/ICE is Ed25519-signed and verified ([`signal_auth.dart`](app/lib/signal_auth.dart)),
so a malicious relay can't impersonate a peer or swap a DTLS fingerprint. Once a
data channel opens, a **`SyncEngine`** ([`sync.dart`](core/lib/src/sync.dart))
gossips messages with `HAVE`/`WANT`/`GIVE` frames and **verifies every message on
receipt** — so any peer can relay anyone's messages without being trusted.

### Encryption — E2E by default
[`encryption.dart`](core/lib/src/encryption.dart), built on ChaCha20-Poly1305 +
HKDF-SHA256:
- **`PairBox`** — DMs. A shared key from static X25519 ECDH between the two
  identities.
- **`GroupCipher`** — group channels. A symmetric AEAD with the channel's key.
- **`SealedBox`** — anonymous messages to a recipient (ephemeral X25519).

The message envelope (text / gif / sticker / sound) is encrypted *inside* the
signed message payload, so encryption composes with the DAG and the relay only
ever sees ciphertext.

### Channels & DMs
A **group channel** ([`group_channel.dart`](app/lib/group_channel.dart)) is a
*capability*: a random unguessable id + a 32-byte encryption key + a local name.
You create one or join via an **invite code** (`hearth:<base64url(id,key,name)>`).
Two people who both make a "games" channel get different ids — no collisions, and
only invitees can find it. **DMs** use a deterministic channel id derived from the
two sorted pubkeys, encrypted with `PairBox`; you can only DM people you've added
as contacts.

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
`audioLevel` stats.

### The relay (backend)
[`backend/`](backend) is a small **Hono** app, and a *dumb relay*: it verifies each
message's signature but **never decrypts or owns history**. It's reduced to a
**cold-start bootstrap** — a pubkey-addressed signalling mailbox — plus the
media-search proxies; once peers have a live link, presence/peers/messages flow
pure P2P, so the happy path needs no server. It's optional and swappable (the
client points at any relay URL), and is designed to **self-host** as a single
in-memory Docker container behind a tunnel (no port-forward) — not deployed yet;
see *Rendezvous & connectivity* and *Deployment* in the plan.

---

## Repository layout

```
core/      Pure-Dart, platform-agnostic engine (no Flutter):
           identity, message DAG, encryption, blobs, sync/gossip, frames.
app/       Flutter client (web + mobile/desktop): UI, WebRTC mesh, voice,
           Hive storage, media library, channel/contact management.
backend/   TypeScript Hono relay: cold-start signalling mailbox + media-search
           proxies. In-memory; self-hosted as a Docker container (tunnelled).
IMPLEMENTATION_PLAN.md   Living plan, architecture decisions log, roadmap.
```

## Tech stack

- **Client:** Flutter / Dart, `flutter_webrtc`, `hive_ce` (IndexedDB on web, files
  native), `audioplayers`, `file_picker`.
- **Crypto:** the `cryptography` package — Ed25519, X25519, ChaCha20-Poly1305,
  HKDF-SHA256.
- **Backend:** TypeScript, [Hono](https://hono.dev), run with `tsx`; **pnpm**.
  Self-hosted as a Docker container, tunnelled (Cloudflare Tunnel); shipped via
  GitHub Actions on a version tag → GHCR.
- **Quality:** `flutter analyze` + Dart/TS tests (`vitest`), `lefthook` pre-commit
  (format + analyze + typecheck).

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

```bash
cd app && flutter test          # client + widget tests
cd core && dart test            # engine tests
pnpm -C backend test            # relay tests (vitest)
flutter analyze                 # static analysis (core + app)
```

A `lefthook` pre-commit hook runs format + analyze + backend typecheck.

---

## Security model (in brief)

- Messages are **signed** (authenticity/integrity) and **encrypted** (DMs/groups),
  so the relay and any couriering peer see only ciphertext they can't forge.
- Signalling is **authenticated**, so the relay can't MITM the WebRTC handshake.
- **What the relay still learns:** that a peer is online, who they're signalling
  with, and (for media search) your search terms — proxying hides your IP from the
  GIF/sound provider, but the relay sees the query. Hiding *who a message is for*
  (sealed sender) and not depending on a relay at all (DHT) are on the roadmap.
- **Identity backup:** export/import a recovery code (the seed) backs up your key —
  clearing storage without it still loses the identity. Multi-device is planned.

## Roadmap

Highlights from [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md): self-host the
relay (Docker + Cloudflare Tunnel) to get off `localhost`, server-minimal
contact-graph rendezvous (cached addresses + mutual-contact peer-exchange) → DHT,
multi-device identity, MLS-style group key management, and richer media. The plan
also keeps a dated **decisions log** explaining *why* each choice was made.

## License

Intended to be open-source; a license has not been finalised yet.

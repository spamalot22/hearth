# Hearth — Implementation Plan

> **Hearth** — a gamer-focused, open-source, decentralised Discord alternative.
> Local-first, peer-to-peer by default, with an **optional** coordination
> backend that improves reliability but is never the source of truth.

_Status: living document. Last reconciled with working tree: 2026-08-30._

---

## Product scope (target feature set)

- **Channels are the core primitive** — a channel is a shared, replicated message
  DAG. **Group channels** (many members) and **direct messages** (a private
  2-person channel) are the *same* primitive; only membership scope + encryption
  differ.
- **Messaging and media are implemented** — encrypted text, rich content, files,
  voice messages, voice chat, Windows screen sharing, and synchronised YouTube
  watch parties use the same channel model. Live transport remains direct WebRTC
  and therefore has no symmetric-NAT fallback without TURN.
- **End-to-end encrypted by default — everything.** DMs use per-device
  `MultiDeviceBox` encryption derived through X25519. Groups use a shared
  32-byte channel key with explicit key epochs; device revocation rotates the
  group key and wraps its replacement only for authorised member devices.
  Ed25519 signatures and device certificates authenticate every message.
  Current limitation: these schemes do not provide DM ratcheting or MLS-style
  forward secrecy, and encryption does not hide relay-visible metadata.
- **No central accounts — identity is a keypair.** "Account" features map onto the
  key: **profiles** (signed metadata), **names** via the **petname model** (each
  user assigns private local petnames; the other side's self-asserted nickname is
  only a *suggestion* — no global authority; an optional directory exists later
  just for cold discovery), **recovery** (a 24-word BIP39 phrase plus optional
  Android Credential Manager or Apple synchronised-Keychain backup), and
  **multi-device** (an offline root key certifies device subkeys). There is no
  central login or OIDC dependency.

---

## 0. Guiding principles

1. **Local-first.** Every device is a full node with its own copy of history.
2. **Graceful degradation.** If the backend dies, existing direct P2P components
   keep working. Cold starts, offline courier delivery, and provider search
   degrade until a relay is available again.
3. **Identity = keypair, not an account.** No company owns who you are.
4. **One language per layer, clean boundary.** Dart for the client (`core` +
   `app`); TypeScript for the containerised relay. Canonical fixtures lock the
   Ed25519 wire contract across languages. `core/` remains Flutter-free.
5. **Authenticate every boundary.** Treat peers and relays as untrusted; bound
   frames, queues, downloads, repositories, and externally supplied metadata.

---

## 1. Tech stack decisions

| Concern | Decision | Status |
|---|---|---|
| UI | **Flutter / Dart** | Implemented |
| Core logic | **Dart**, isolated from Flutter in `core/` | Implemented |
| Identity and signing | **Ed25519** root/device identities; `cryptography` in Dart and `@noble/ed25519` in the relay | Implemented |
| P2P transport | **WebRTC** (`flutter_webrtc`) data channels and media | Implemented |
| Bootstrap/backend | Self-hosted **Hono** relay (TypeScript, Docker, bounded in-memory stores) behind **Tailscale Funnel**; pluggable relay URLs and failover | Implemented |
| Relay services | Cold-start signalling, encrypted offline courier, GIF/sound search proxies | Implemented, best effort |
| Data NAT fallback | Direct WebRTC only; no TURN or app-level transport relay | Deliberate limitation |
| Media NAT fallback | Direct WebRTC only; no TURN or app-level media relay | Deliberate limitation |
| E2E encryption | Per-device DM boxes and epoch-based group keys | Implemented; no ratchet/MLS forward secrecy |
| Heavy P2P | DHT/libp2p rejected; it would still require bootstrap and materially increase native complexity | Dropped |

### Target platforms (priority order)
1. **Windows + Android** — primary installed targets. Tagged releases publish a
   signed Windows installer and Android APK; both support native update flows.
2. **Web** — built and published by CI; updates by loading the new deployment.
3. **Later / secondary:** iOS, macOS, and Linux are scaffolded but are not built
   or published by the release workflow and do not have full feature parity.

Deferring iOS removes the only hard cost floor (Apple Developer $99/yr); it
returns only if/when we ship iOS.

### Why TypeScript for the backend (not Dart)?
- The backend is a thin Hono service, not shared client logic, so reusing the
  local-first Dart core would create coupling without meaningful reuse.
- Node has straightforward container tooling for the HTTP relay and provider
  proxies. Cross-language Ed25519 verification is locked by shared fixtures and
  canonical message encoding.

### Why not a Rust core from day one?
- It materially increases FFI and cross-platform build complexity without
  improving the current message/sync hot paths.
- The main likely reason to add Rust is a proven MLS implementation, not speed.
- **Mitigation:** keep `core/` free of UI and Flutter imports so it can become a
  Rust module later with the UI untouched.

### The escape hatch (when we'd reach for Rust)
- We implement MLS for scalable group key rotation → `openmls` (Rust).
- Profiling shows DAG merge / crypto is a hot path in Dart (unlikely early).

---

## 2. Architecture

```
Flutter UI — Windows · Android · web (primary/released targets)
│
├─ core/  (pure Dart, no Flutter imports)
│    identity    offline root + certified device keys
│    model       signed, content-addressed message DAG
│    crypto      X25519/AEAD boxes and canonical Ed25519 signatures
│    sync        HAVE/WANT/GIVE gossip + content-addressed blobs
│
├─ app/   (Flutter orchestration and platform integration)
│    WebRTC meshes      direct chat, voice, and screen media
│    peer signalling    signed SDP/ICE routed over live mesh links
│    local storage      Hive message/blob/profile/device state
│    updates            signed GitHub manifest + native installers
│
└─ backend/  (optional TypeScript/Hono relay; never source of truth)
     cold start         announce/peer/signal mailboxes
     offline courier    bounded encrypted-message holding
     data fallback      bounded encrypted gossip tunnel
     media search       GIF/sound provider proxies
```

### Repo layout (polyglot monorepo)
```
/core      Dart package, no Flutter — protocol, identity, DAG (shared by app)
/app       Flutter app (depends on core)        ── Dart pub workspace ──┘
/backend   TypeScript Hono relay; Docker/Compose deployment behind Tailscale
           Funnel; a version tag publishes multi-architecture images to GHCR
```

### The client/backend relationship (important)
- **The client is local-first and P2P by default.** Connected clients exchange
  messages, blobs, controls, voice, and screen media directly over WebRTC.
- **The backend is optional coordination infrastructure**, not a source of
  truth. It bootstraps disconnected peers, temporarily holds encrypted courier
  messages, can tunnel encrypted chat data, and proxies media searches.
- **Default deploy = a self-hosted, tunnelled Hono container ($0 on hardware you
  already run).** Self-hosters run the same bounded in-memory relay image from
  GHCR behind a Tailscale Funnel sidecar. Cloudflare remains an alternative
  Compose profile; Firebase and Firestore are not part of the current system.
- **The rendezvous endpoint is pluggable in the client** (point at any backend
  URL). That is what keeps it decentralised: your self-hosted relay is just the
  default bootstrap node — replaceable, not authoritative.
- **Cold-start caveat:** peers with no live route between their connected
  components need a relay rendezvous. LAN/mDNS and a distributed relay directory
  are not implemented; a DHT was explicitly rejected.
- **A relay outage does not break an existing direct component.** Live links
  exchange peers and route authenticated SDP/ICE to re-form the same channel.
  A fully disconnected or partitioned component cannot discover the other side.
- **Offline delivery is epidemic, not routed.** Every message is signed +
  content-addressed, so *any* peer can carry and re-serve another's messages
  without forging or altering them (recipients verify the author's signature
  directly); with DM payloads sealed to the recipient, carriers relay **blind**.
  So A can message an offline C, go offline, and C later syncs it from a carrier B
  who couriered it without reading it. The optional backend relay is just "a
  carrier that's always online" — it makes best-effort peer carry reliable. No
  durable database is required for local-first operation. The relay's courier is
  bounded and in-memory, so relay restarts can drop held copies; later P2P gossip
  repairs them if another device still has the message. A carrier still learns
  authorship metadata; sealed sender is not implemented.

### Rendezvous & connectivity

Relay namespaces are **channel capabilities**: a random group id or derived DM
id plus a device public key. Possessing a group id is not enough to join it;
group SDP/ICE also carries an HMAC proving possession of the channel key. The
relay returns other recently announced device keys and their original signed
presence claims in that namespace, and stores short-lived per-recipient
signalling mail. Group presence claims include a channel-key HMAC. Clients verify
both proofs themselves before displaying relay-visible presence. Presence only
decorates identities already established locally; it cannot create membership.

**Connection ladder:**
1. **Relay rendezvous for an entry link.** A signed announce returns a short-lived
   token, peer list, and access to the authenticated signal mailbox. The app
   cycles through configured fallback relays and periodically re-prefers the
   primary after recovery.
2. **Same-channel peer exchange.** Every opened data channel introduces the new
   peer to existing live peers in both directions. Successfully connected peer
   identities are retained in `CandidateCache`; network addresses and stale ICE
   candidates are deliberately not persisted.
3. **Peer-routed signalling.** Existing links carry end-to-end signed SDP/ICE to
   newly introduced or reachable cached identities. Every hop verifies the
   origin signature and optional group-key capability. Six-hop TTLs, bounded
   flooding, deduplication, frame-size limits, connection caps, and per-ingress
   rate limits constrain loops and abuse.
4. **Bounded relay rendezvous fallback.** Peer-routed signalling is attempted
   first. The relay exchanges fresh authenticated SDP/ICE only after those paths
   fail; it does not carry live data or media.

Connected channel components deterministically rotate two redundant relay
workers, with previous-slot overlap during handoff. Every participant ranks the
same authenticated device identifiers. Other members pause routine
announce, signal, and courier polling; peerless and handshaking clients remain
active. A departing worker stops
announcing/courier polling but drains its identity-addressed signal mailbox for
50 seconds, covering relay presence plus signal TTL. Every standby independently
performs a staggered rendezvous, signal, and courier probe at least every two
minutes, bounding recovery if workers are suspended, malicious, or cannot reach
the relay. A locally published DM skips its encrypted courier copy only when an
admitted DM device confirms durable receipt within 1.5 seconds; group messages
always retain the courier fallback. Direct P2P remains the preferred data path,
but describing steady state as "no server traffic" is incorrect. STUN remains
external infrastructure used by WebRTC to discover public mappings.

Group invites include the channel capability, key, inviter identity, and relay
URL. Joining records the inviter as a contact; connected members and gossip then
densify the topology. This improves resilience but does not eliminate the true
cold-start/partition boundary.

### Deployment (self-hosted, tunnelled)

Because the server is a thin coordination service, it is practical and private
to **self-host** — and a single always-on container on hardware you already run
(NAS / Proxmox) keeps it dead simple: the relay stays the current **in-memory Hono
app** — no Firestore, no serverless cold-start-state rewrite, no scale-to-zero
gymnastics (all of which existed only to dodge *cloud* cost). On your own box,
polling cost is irrelevant.

**Shape — one Docker Compose stack (this *is* the IaC):**
- **Relay container** (Hono): rendezvous, a bounded encrypted courier store,
  release compatibility endpoint, and media-search proxies. No database.
- **Exposure: Tailscale Funnel sidecar.** The current deployment uses kernel-mode
  Tailscale with `/dev/net/tun` and `NET_ADMIN`, forwarding privately to the relay
  over the Compose bridge. Cloudflare Tunnel is retained as an alternative.
- **No coturn or TURN service.** Data and media remain P2P and may fail where ICE
  cannot establish a direct path.

**CI/CD — IaC + tag-triggered pipeline:** the `docker-compose.yml` (+ relay
`Dockerfile` + tunnel config) is the infrastructure as code. **GitHub Actions on a
version tag** (`v*`, that *you* push — not push-to-main) builds the relay image and
publishes it to **GHCR**; the box **pulls** it (Watchtower / webhook / manual
`docker compose pull && up -d`). You control the rollout.

**Decentralised by construction:** the relay URL is pluggable and rides in the
invite; any community self-hosts their own the same way — yours on your NAS is just
the default bootstrap node.

---

## 3. Current data model

Every message is a signed, content-addressed object forming a DAG:

```jsonc
{
  "v":         1,
  "id":        "<sha2-256 multihash of canonical signed bytes>",
  "author":    "<root ed25519 pubkey>",
  "channel":   "<channel id>",
  "prev":      ["<id>", "<id>"],      // heads this msg "saw" -> causal order
  "timestamp": 1718900000000,         // advisory only, tiebreak
  "payload":   "<encrypted content-envelope bytes>",
  "sig":       "<ed25519 signature>",
  "device":    "<optional certified device pubkey>",
  "cert":      "<optional root-signed device certificate>"
}
```

- **Ordering:** topological sort of the DAG; ties broken by `(timestamp, id)`.
- **Merge:** append-only set of signed messages = a simple CRDT. Concurrent
  offline posts both survive and order deterministically.
- **Integrity:** altering any signed field invalidates the id and signature;
  downstream `prev` links content-address that id.
- **Canonical encoding:** signed fields use the implemented deterministic
  DAG-CBOR-style encoder, with a locked Dart/TypeScript interoperability fixture.
- **Multi-device:** `author` remains the stable root identity while an optional
  certified device key signs on its behalf. Revocation is applied by sync/app
  policy because it depends on the latest root-signed revocation state.

---

## 4. Phased roadmap

### Phase 0 — Skeleton
- [x] `flutter create` app + `core/` Dart package, wired as a pub workspace;
      `pub get` + `flutter analyze` clean.
- [x] CI verifies core/app/backend and builds Android, Windows installer, and web.
- [x] Removed the scaffolded Dart server; backend is TypeScript/Hono.
- [x] Name: **Hearth** (personal project; low trademark risk accepted).

### Phase 1 — Text chat via the backend relay
_Goal: two clients exchange signed messages through a dumb relay. No P2P yet.
Prove the data model._
- [x] `core`: Ed25519 identity (keypair = id) + `KeyStore` interface for the seed.
- [x] `core`: signed, content-addressed message; canonical (dag-cbor) encoding;
      verify; locked cross-language interop vector + fixture.
- [x] `core`: DAG store (`MessageStore`) — deterministic topological ordering, heads + merge.
- [x] `app`: concrete `KeyStore` (flutter_secure_storage) + `Identity.loadOrCreate` bootstrap.
- [x] `app`: identity screen — generate/persist on first launch, show fingerprint + pubkey.
- [x] `backend`: Hono relay (`POST /messages` verifies sig+id, `GET /poll`) on
      Node + in-memory store; **TS↔Dart interop proven** vs the fixture (dag-cbor + Ed25519).
- [x] ~~`backend`: swap in-memory store → Firestore~~ — **superseded**: stayed with
      in-memory Hono relay (self-hosted Docker, no Firebase).
- [x] ~~`app`: send/receive UI over the relay~~ — **superseded**: UI built directly
      against the P2P mesh + relay courier.

### Phase 2 — Peer-to-peer transport
_Outcome: direct P2P is primary; the backend remains an optional encrypted
courier and cold-start rendezvous._
- [x] `core`: abstract `Transport` interface; `RelayTransport` is stream-based.
- [x] `backend`: signalling + presence endpoints (announce / peers / signal),
      in-memory for now.
- [x] `app`: `WebRtcMesh` (`flutter_webrtc`) — Flutter-only, so
      it lives app-side; public STUN for ICE, deterministic offerer avoids glare.
      Verified two-window: host↔host pair, DTLS up, `hearth` data channel open,
      messages crossing P2P (relay only brokered the handshake).
- [x] `core`: **local persistence** — `MessageStorage` port + `MessageRepository`
      over the DAG; Hive on the app (IndexedDB on web, files on native). Verified:
      history survives reload. Local-first, no backend.
- [x] `core`: **gossip sync / epidemic replication** — `SyncEngine`/`SyncSession`
      over per-peer HAVE/WANT/GIVE frames; walks `prev` to backfill, verifies every
      GIVE, drops off-channel/forged. Delivers A→(carried by B)→C. Verified
      two-window: a late joiner backfills the full history, live both ways.
- [x] **Authenticated signalling** — offers/answers/ICE are Ed25519-signed and
      verified against the sender's pubkey (`signal_auth`), binding the SDP's DTLS
      fingerprint to identity. Closes the active-MITM hole; the relay stays a dumb
      pipe (still sees metadata). Verified two-window + 6 unit tests.
- [x] **DM encryption** — `MultiDeviceBox` encrypts each payload for all active
      sender and recipient devices using X25519-derived AEAD keys. First-contact
      rendezvous, message requests, negotiated private relay mailboxes, and
      durable pending retries handle the pre-DM connection flow.
- [x] **Self-hosted relay deploy** — DONE. Dockerised in-memory Hono relay shipped
      via GitHub Actions (version tag → GHCR), deployed as a **Portainer stack** on a
      small always-on host, exposed public-HTTPS via a **Tailscale Funnel sidecar** (no
      domain, no port-forward; the tailnet node is the container, not the host). The
      app's relay URL is configurable. Funnel needs **kernel mode** (TUN device).
      Cloudflare Tunnel kept as an alt profile. See `backend/DEPLOY.md`.
- [x] **Adaptive relay activity** — signalling polls at 700ms only during a
      handshake and settles to 15s; announces settle from 5s to 10s to remain
      inside the relay's 15-second presence TTL. Distributed workers perform
      routine courier polling while relay-dependent clients fail open to polling.
- [x] **On-demand DM courier uploads** — a peer acknowledges only after verifying
      and durably accepting a message. A DM sender accepts receipts only from a
      currently admitted device owned by the remote identity, skipping the relay
      copy after an ACK and falling back after 1.5 seconds. Groups always retain
      the courier fallback.
- [x] **Distributed relay duty** — primary channel meshes rotate two redundant
      relay workers with handoff overlap. Selection applies time-varying SHA-256
      priorities to consistent authenticated device ids and grants no protocol
      authority. Partial views create additional local workers, relay-dependent
      states fail open to polling, and every standby makes a staggered fail-safe
      probe within two minutes. Outgoing workers drain their signal mailbox
      through the relay TTL window.
- [x] **Server-minimal connectivity** — cached peer identities, symmetric live
      peer exchange, and authenticated P2P-routed signalling re-knit a connected
      channel component without relay rendezvous.
- [x] **Invite bootstrap metadata** — group/contact invites carry the inviter's
      identity and relay URL. Accepting records the inviter and joins the shared
      capability namespace used for rendezvous.
- [x] **Data relay fallback** — after repeated ICE failure, the tunnelled relay
      forwards encrypted gossip frames app-level (no coturn, UDP, or port-forward).
      Voice and screen media remain direct-only.

### Phase 3 — Groups, voice, and the hard stuff
- [x] Group = replicated encrypted log + random id/key capability; observed
      signed member/device state is retained locally and gossiped in the log.
- [x] ~~Permission-conflict resolution rule (owner-key-wins)~~ — **rejected**
      (2026-06-29): no channel ownership model. Block & mute are purely local.
- [x] Voice and Windows screen-share video over WebRTC media, signalled through
      the same authenticated mesh layer.
- [x] **Group encryption** — messages use an epoch-labelled shared channel key.
      Root-signed device revocation triggers a replacement key wrapped to each
      remaining authorised device. MLS remains a possible forward-secrecy upgrade.
- Multi-device identity, two tiers:
      - [x] **(a) export/import the root seed** — DONE. A settings "reveal
        recovery phrase" screen shows a **BIP39 24-word mnemonic** (+ a QR
        encoding the same phrase) with a copy-and-auto-clear; restore accepts the
        phrase (checksum-validated, so a mistyped word is rejected rather than
        silently restoring the wrong key) or scans the QR. This is both "same key
        on another device" and the identity **backup/recovery** mechanism. Codec
        lives in `core` (`mnemonic.dart`, BIP39-vector-tested).
      - [x] **(b) per-device subkeys** certified by a root key — DONE. Full
        concurrent multi-device + per-device DM encryption + device revocation +
        offline-root enrollment ceremony. See 2026-07-04 decisions log.
- [x] **Peer cache + peer-exchange** — clients cache successfully reached peer
      identities and gossip currently reachable members. Existing data channels
      carry authenticated SDP/ICE with bounded forwarding, reverse-route learning,
      deduplication, and rate limits, so stale network addresses are never treated
      as durable routes. A relay is still needed for a true cold start or partition.
- [x] **Pluggable bootstrap relay** — the cold-start relay URL rides in the invite
      and is swappable; a community self-hosts its own. Multi-relay failover
      implemented (2026-06-28).
- [x] ~~DHT (libp2p)~~ — **decided against** (2026-06-25): doesn't reach zero-servers
      and costs a full Rust integration; the self-hosted tunnelled relay is the
      accepted bootstrap node.

### Phase 4 — Polish / ecosystem
- [x] Notifications, per platform (shipped **without FCM** — see 2026-06-30 log):
      - **Android → `background_fetch` polling** (not FCM). A headless isolate
        polls the relay `/poll` on a JobScheduler interval (≥15 min) and raises a
        local notification; no Google push, no Firestore token registry.
      - **Windows → no push service.** App runs resident (tray, launch-on-start)
        and holds its connection, so messages arrive live; surfaced with local OS
        notifications (`flutter_local_notifications`).
      - **Web → Notification API** (permission requested on first user gesture).
      - **iOS → later** (reintroduces Apple $99/yr + APNs key).
      - Rich in-app notifications: sender name, content preview, tap-to-open;
        suppressed for muted channels and blocked users.
      - Self-hoster option later: **UnifiedPush** for de-Googled Android.
- [x] **Rich content** — typed message payloads via an encrypted content envelope:
      - [x] **Emoji** — quick picker added (Unicode text already worked).
      - [x] **GIFs** — relay-proxied Giphy search or URL fallback; selected GIFs
            are downloaded once, content-addressed, and transferred P2P.
      - [x] **Stickers** — sticker picker panel (browse your library of received/
            sent stickers for quick reuse, like the emoji picker but for images).
      - [x] **Soundboards** — per-channel uploadable audio clips, tap to play
            (`audioplayers`), shared channel-wide. Voice panel has a soundboard
            button; plays for all voice participants via control frame.
      - [x] **Files, images, and voice messages** — file picker/recorder inputs,
            inline rendering/playback, and bounded content-addressed storage.
      - [x] **Media blobs** — Hive-backed `BlobStore`, chunked WANT/GIVE transfer,
            content-hash verification, size/assembly limits, and a reusable library.
- [x] **Messaging UX** (all shipped): **replies** (quote-and-respond),
      **emoji reactions** (chips on the target message), **pinned messages**
      (local, per-channel), **in-channel search**, per-channel **mute** toggle,
      and **read receipts** (WhatsApp-style ticks via `ReadWatermarkControl`
      gossiped over the mesh, disable-able per DM). Plus animation polish
      (per-channel accent colour, typing dots, cascade-in, scroll-to-bottom FAB).
      **2026-07-02 batch:** **edit & delete** (append-only DAG revisions,
      author-verified), **chat markdown** (bold/italic/strike/code/links,
      hand-rolled), **voice messages** (record → blob → inline playback), and
      **custom avatars** (≤128px PNG blob riding the profile claim, gradient
      ring kept as the identity cue).
- [x] **Screen share + watch party (Windows)** — Discord-style **screen share**
      (per-sharer star-topology WebRTC mesh, pick window/screen, configurable
      resolution) and a channel-wide **synchronised YouTube watch party**
      (host-controlled `flutter_inappwebview` player, each member can mute/close
      locally). Both gated behind being in voice. Windows-first.
- [x] **QR invites** — invite screen renders a QR of the invite code;
      mobile can **scan-to-join** (`mobile_scanner`).
- [x] **Block & mute (no channel ownership)** — purely local controls:
      - **Voice mute** (ephemeral, per-channel): mute another member's audio
        in a voice session (local only, resets on leave). Separate from the
        per-user volume slider — shows a mute icon on their speaking indicator.
      - **Block** (global, persistent): blocks a pubkey across all interactions.
        Future group messages shown as redacted (still stored in DAG for unblock);
        DMs silently dropped (never stored); auto-muted in voice. Accessible from
        channel member list + contacts. Unblock restores group messages.
      - No hierarchy, no owner, no kick — the blocked person doesn't know.
- [x] **Local/decentralised AI bot** — optional on-device GGUF inference; peers
      request it through bounded channel controls and the first available host responds.
- [ ] Optional federation or automatic relay-directory exchange.
- [ ] Public-discovery spam resistance (proof-of-work/web-of-trust). Current
      channels are invite capabilities and relay endpoints are rate-limited.
- [ ] WASM plugin system.
- [ ] iOS/macOS/Linux release and feature-parity work.

---

## 5. Outstanding decisions and limitations

1. **Forward secrecy.** Current DM and group encryption is authenticated and
   device-aware but does not ratchet. Decide whether the complexity and native
   integration cost of a DM double ratchet and/or MLS is justified.
2. **Group governance and member eviction.** Hearth deliberately has no owner,
   admin, or kick hierarchy. Adding real eviction requires a conflict rule plus a
   new key epoch distributed to everyone except the removed member.
3. **Cold-start expansion.** Today a disconnected component needs one configured
   relay. LAN/mDNS or signed relay-directory exchange could add independent entry
   paths; DHT/libp2p remains rejected.
4. **Public discovery and abuse controls.** Invite capabilities and current rate
   limits are appropriate for private groups. A future public directory would
   need stronger Sybil/spam resistance before launch.
5. **Media connectivity policy.** Voice and screen sharing are direct-only. Keep
   that strict P2P guarantee, or explicitly choose a media relay design for NAT
   pairs that cannot connect directly.
6. **Secondary platforms.** Decide whether iOS, macOS, and Linux should become
   release targets; they currently have Flutter scaffolding but no release gate.

---

## 6. Decisions log

These entries record the design chronologically. Later entries supersede older
choices where they conflict with the current-state sections above.

- **2026-06-20** — UI in Flutter; `core` in Dart, isolated behind an interface so
  P2P/MLS can move to Rust later. Ed25519 identity. WebRTC for real-time. Backend
  is optional and stores no history it isn't asked to relay.
- **2026-06-20** *(superseded → Firebase; see below)* — Backend was **TypeScript
  serverless on AWS** (Lambda Function URLs + DynamoDB, Always-Free), via HTTPS
  short-polling. Dropped the Dart `server` package. TURN = optional coturn
  (Docker). Rendezvous endpoint pluggable. Chose $0 serverless over a ~$5/mo VM.
- **2026-06-20** — Push (Phase 4) via **FCM**, not SNS: FCM covers Android (+ iOS
  via APNs relay, + web); SNS can't do web push. A backend function sends; device
  tokens stored server-side. Floor cost = Apple Developer $99/yr, only if/when iOS.
- **2026-06-20** — Targets scoped to **Windows + Android** first (iOS deferred).
  Push therefore fully free: Android via FCM, Windows via resident tray + local
  notifications (no push service). No Apple $99 floor until iOS happens.
- **2026-06-20** — **Consolidated the backend on Google/Firebase**, superseding
  the AWS choice above. Why: Android push *requires* FCM (Google), so all-AWS is
  impossible — only all-Google is genuinely one provider/account. Stack: Firebase
  Cloud Functions (TS) + Firestore + FCM in one project; keeps TS; Firestore
  real-time listeners can replace polling. Free for tens of users; Functions need
  the Blaze plan (card on file, free within limits + budget alert); dev via the
  Emulator Suite needs no card.
- **2026-06-20** — Project named **Hearth** (personal, unlikely to be monetised →
  accepted low trademark risk without formal clearance; it's a common word, so run
  free UK IPO / app-store checks if it ever goes serious). Git initialised on
  `main`; repo-local identity `spamalot22` + GitHub noreply (work email
  untouched). Internal package names stay generic (`core` / `app`).
- **2026-06-20** — Quality tooling in place: **strict-curated lints**
  (`analysis_options.base.yaml` — strict-casts/inference/raw-types + curated
  rules, shared by both packages); **Lefthook** hooks (pre-commit: format +
  analyze; pre-push: tests — run `lefthook install` after clone); **core at
  99.3% line coverage**. Still TODO: real `app` tests (placeholder only) + a CI
  gate (bundle with the Windows-build CI).
- **2026-06-20** — Backend started as a **plain-Node Hono relay** with an
  in-memory store (not the Firebase emulator yet): the Hono routes are identical
  when later wrapped as a Cloud Function, and the priority was proving TS↔Dart
  interop — now **confirmed** (`@ipld/dag-cbor` reproduces core's canonical signed
  bytes byte-for-byte; Ed25519 verifies cross-language). Node tooling is **pnpm**,
  with the public npmjs registry pinned in `backend/.npmrc` (the global npm
  registry is a work one and must not be used here).
- **2026-06-21** *(superseded → everything-encrypted-by-default; see below)* —
  **Encryption scope:** group channels plaintext (signed) by default —
  moderatable/searchable/bot-friendly — with a per-channel **toggle to E2E**; DMs
  E2E by default. Reversed below in favour of privacy-by-default.
- **2026-06-21** — **Naming decided (petname model):** identity stays the key;
  human names are **local petnames** each user assigns privately. On first contact
  the client *suggests* the other side's self-asserted nickname (from their signed
  profile), but the petname is the user's own choice. Keeps names secure +
  decentralised — only *global* agreement is given up. Safety: nicknames are
  untrusted suggestions, petnames unique per local list, client flags name
  collisions / key changes (TOFU pinning). A namespace/directory is an optional,
  later add-on **only** for cold discovery of strangers by name. Default display
  until petnamed: the `hearth#fingerprint`.
- **2026-06-21** — **Architecture: a database-free P2P core + an _optional_
  always-on relay.** "Do we need a database?" reduces to one feature — offline /
  asynchronous delivery (and push, which needs the same holding). Identity needs no
  DB (export/import the key); signalling/presence is transient (peers just
  re-announce); message history is **local-first** on each device. Delivery is
  **epidemic, not routed**: messages are signed + content-addressed, so any peer can
  carry and re-serve another's without forging/altering, and DM payloads are
  **sealed to the recipient** so carriers relay blind. Canonical target: A messages
  offline C, A goes offline, C later syncs it via carrier B — couriered without
  reading or tampering. A durable DB is needed only to run an always-online carrier
  (the optional relay) and for push; the default core runs with none. **Revised
  ordering:** prioritise **gossip sync** + **DM sealed-box encryption** (X25519),
  both independent of and earlier than heavyweight **group MLS** (still Phase 3) —
  refines the encryption-scope entry above. Caveat: carriers learn message
  _authorship_; hiding the recipient (sealed sender) is a later step.
- **2026-06-21** — **Deferred all multi-device identity (incl. export/import) to
  Phase 3**, to keep Phase 2 on the delivery core (local persistence, gossip, DM
  encryption). Trade accepted for now: no identity backup until then — clearing a
  device's storage loses that key irrecoverably. *(Resolved: seed export/import
  shipped — see 2026-07-01 below.)*
- **2026-06-21** — **Known robustness gaps** (found while testing, deferred): the
  dev relay's signal mailboxes never expire, so a long-lived relay accumulates
  stale offers a freshly-loaded client re-fetches (`since=0`) and churns on; and
  the mesh disposes + re-offers on any connection failure with no backoff, turning
  a blip into a retry storm. Workaround: restart the relay / reopen the tab. Fix
  with signal TTL (like presence) + retry backoff when hardening the relay.
  **Update (2026-06-22): signal TTL shipped (30s); mesh retry backoff still open.**
- **2026-06-21** — **Authenticated the WebRTC signalling.** Offers/answers/ICE are
  Ed25519-signed over the security-critical payload (the SDP's DTLS fingerprint /
  the ICE candidate), bound to kind + recipient; the receiver verifies against the
  sender's pubkey and drops anything unsigned or tampered. Closes the active-MITM
  hole flagged earlier — a relay can't impersonate a peer or swap a fingerprint, so
  the DTLS channel provably terminates at the claimed identity. The relay stays a
  dumb pipe (no server-side verification; still sees metadata — who announces, IPs).
  Crypto in a testable `signal_auth` unit (6 tests). Caveat: this binds the channel
  to the *announced* identity; trusting that a key is who you want is the separate
  petname/TOFU layer.
- **2026-06-21** — **Encryption reversed to E2E-by-default for *everything*** (DMs
  and groups), superseding the plaintext-groups decision. Privacy is the default;
  an opt-*out* to plaintext comes only where a specific feature demands it
  (server-side search/moderation, content bots, or **open public channels** — note
  open/public Discord-style channels become the main thing you'd opt out for, since
  encryption needs a defined member set). Sequencing: **DMs sealed-box (X25519)
  first** — cheap, recipient known; **group encryption** rides with group
  membership (encrypt to the member set), with **MLS** the forward-secrecy +
  rotation upgrade. Costs accepted (weighed explicitly): no server-side
  search/moderation/content-bots, push shows "new message" until on-device decrypt,
  lost key = lost history, new devices must sync history. Sealed-box has **no
  forward secrecy** (a leaked key exposes past DMs) — MLS fixes that for groups;
  DMs can ratchet later if wanted.
- **2026-06-21** — **Rich content planned** (user-requested): emoji, GIFs,
  stickers, soundboards. Approach: a typed **content envelope** in the payload
  (`{t, …}`) that composes under encryption, plus a shared **media-blob
  subsystem** (content-addressed blobs fetched on demand over the data channel,
  referenced by hash — never gossip large media to everyone). Emoji is ~free
  (Unicode text); GIF *search* (Giphy/Tenor) needs a provider **API key** —
  credentials to request when we build it. Soundboards add `audioplayers`.
- **2026-06-22** — **Autonomous build run** (multi-channel onward): shipped
  multi-channel + a channel drawer, encrypted DMs (`PairBox`), the emoji picker,
  the typed content envelope + GIF-by-URL, and the relay signal TTL. Crypto + core
  are unit-tested; the live multi-window behaviour of the app features (DM connect,
  GIF render, channel switching) is **not yet verified in a browser** — pending a
  manual two-window pass. Media-blob foundation (store + on-demand transfer) is
  built + tested; stickers/soundboards still need app upload/render/playback (deps
  + live verify). Also open: encrypted groups (membership), DM auto-join, mesh
  retry backoff, Giphy/Tenor search (API key).
- **2026-06-22** — **Channels redesigned: invite-only + encrypted by default**
  (user request, + fixes a multi-channel signal-routing bug). Removed the open
  `general` channel. A channel = a random **capability id** (unguessable, so only
  invitees know it) + a 32-byte **GroupCipher key** + a **local name** (never
  shared). Create mints both; an **invite code** carries `{id, key, name}` to
  paste; joining = having the invite. Two people who make "games" get different
  ids — no collisions. All channels now encrypted (group key, or DM PairBox); open
  public channels would be the plaintext opt-out, later. Bug fixed alongside: the
  relay's signal mailbox is keyed per `(channel, pubkey)`, so channels no longer
  cross-talk (the "general works for sender only" symptom).
- **2026-06-22** — **GIF search via the relay** (proxied, not in the client):
  decentralisation point — embedding/per-user API keys don't work, so the Tenor
  key lives on the relay (`TENOR_KEY` env), one key per relay operator. App calls
  `/gif/search`; the relay reports `{gifs, configured}`; unreachable/unconfigured
  → the GIF sheet falls back to paste-a-URL with an explanation. Switched provider
  Giphy → **Tenor** (more generous free tier, the messaging default; key needs no
  billing, but ToS wants attribution if public).
- **2026-06-22** — **Relay discovery & resilience designed** (captured, not built;
  see the section above). Relay = disposable hint; the channel is `{id,key}` +
  local history and survives any relay. Signalling relays ride in the invite
  (per-channel); services (GIF/push) use the user's **home relay** (per-user).
  Fallback ladder: invite relays → peer-exchanged → app seed list → LAN/mDNS → DHT
  → out-of-band re-invite. Directory (Phase 3): signed Ed25519 relay identities,
  de-dup by pubkey, relay + peer gossip, **liveness-gated pruning** (prune on
  corroborated death while *you're* online — never on your own contact gap),
  poisoning/eclipse mitigations. Build thin; the **DHT (libp2p)** is the endgame
  and subsumes much of it.
- **2026-06-23** — **Rich media is all local blobs + provider updates.** GIFs,
  stickers, and sounds are now content-addressed **blobs stored on every device**
  (no CDN at render); received media joins a local **media library** that's
  re-sendable in any channel. Sounds carry a name + **emoji icon**; a bundled
  **CC0 starter-pack** loads from `assets/sounds/`. Search providers are
  relay-proxied (key server-side, loaded from gitignored `backend/.env` via
  dotenv): **Giphy** for GIFs — switched from Tenor, which Google is discontinuing
  in 2026 (no new keys from 2026-01-13, service ends 2026-06-30) — and
  **Freesound** for sounds, **CC0-filtered** so results are safe to redistribute
  P2P. Each searched clip is fetched once and blob-ified on send.
- **2026-06-24** — **Self-asserted display names → suggested petnames.** Users set
  their own name, broadcast as signed `ProfileContent` messages (gossiped,
  never rendered in the timeline); clients index author→latest claim as a
  *suggestion*. Used as the display name when no petname is set (the pubkey-derived
  avatar stays the spoof-resistant cue), pre-filled when adding/renaming a contact,
  and offered in a per-channel **bulk-add** pick-list (members who've shared a name;
  tick to add). Self-asserted ⇒ a suggestion, never identity — anyone can claim any
  name, so trust stays on the pubkey + your local petname. **Channel names stay
  force-adopted from the invite** (creator authoritative, no local rename) —
  deliberately *unlike* user names. Also: voice chat (per-channel WebRTC audio mesh,
  mute/deafen/per-user volume, join/leave cues, speaking indicators) and a
  warm-hearth UI with a right-hand channel control panel shipped this stretch.
- **2026-06-25** — **Rendezvous redesigned (server-minimal, contact-graph) + deploy
  self-hosted & tunnelled** — supersedes the Firebase/multi-relay framing for the
  connectivity + deploy story (see "Rendezvous & connectivity" and "Deployment").
  The backend drops to a **cold-start signalling mailbox + media proxies**: once a
  peer has any live link, presence / peer-exchange / messages are pure P2P, so the
  happy path needs no server and an outage only blocks cold-start-with-nobody-
  reachable. Reconnect ladder: **cached candidates → punch via an online mutual
  contact → server cold-start mailbox → TURN** (deferred; managed/VPS, never home).
  Rendezvous is **pubkey-addressed + contact-scoped** (no channel-wide presence, no
  strangers). The contact graph is kept connected by making **invite-accept add the
  inviter** (invite carries the inviter pubkey = bootstrap peer) → channel edges form
  the connected **invite tree** → no islands; bulk-add + gossip add resilience.
  **Why the pivot:** "no always-on *cloud* server" + self-hosting on an always-on box
  you already own (NAS/Proxmox) means the relay stays the **simple in-memory Hono
  container** — deleting the entire serverless/Firestore-durability rewrite (which
  only existed to dodge cloud scale-to-zero cost). Exposed via **Cloudflare Tunnel**
  (no port-forward, no home-IP exposure). **TURN stays off the home network** (can't
  tunnel its UDP range; open relays get abused). IaC = a Docker Compose stack; CI =
  **GitHub Actions on a version tag → GHCR**, the box pulls. (Caveat acknowledged:
  cached addresses fail for ephemeral/symmetric NAT mappings — that rung is for the
  reachable minority; STUN still needed for each peer to learn its own candidate.)
- **2026-06-26** — **Relay deployed off `localhost`** (self-hosted, Portainer). The
  relay ships as a GHCR image (GH Actions on a version tag) and runs as a Portainer
  stack with an official **Tailscale Funnel sidecar** for public HTTPS — no domain, no
  port-forward, and the **tailnet node is the container**, not the NAS. Funnel reaches
  the relay over a private Compose bridge, so neither service owns the other's network
  namespace and they can restart independently. Hard-won gotchas,
  captured in `backend/DEPLOY.md`: Funnel **requires kernel mode** (a real `/dev/net/tun`
  + `NET_ADMIN`) — userspace mode configures Funnel but never receives inbound traffic
  (silent 502); the **Funnel ACL `nodeAttrs` grant** is needed because the container's
  `TS_SERVE_CONFIG` bypasses the CLI's interactive enable; and `NXDOMAIN` on the funnel
  name is usually just stale negative-DNS-cache, not a real failure. The app gained a
  configurable relay-URL setting. (Cloudflare Tunnel remains an alt profile — userspace,
  no TUN, needs a domain.)
- **2026-06-25** — **Dropped libp2p; replaced coturn with a Dart relay-fallback.**
  Considered libp2p (Circuit Relay v2 + DCUtR + Kademlia DHT) for NAT traversal /
  zero-servers. Rejected: it doesn't actually reach zero servers for our use case (the
  **media-search proxies need server-side keys**, the DHT needs bootstrap nodes, and
  browsers/mobile can't be relay/DHT servers), and even partial adoption costs a full
  **rust-libp2p + flutter_rust_bridge** integration. Crucially the goal that motivated
  it — **no coturn, no UDP port-forward** — is reachable in pure Dart: WebRTC ICE
  already hole-punches every non-symmetric pair, and the symmetric↔symmetric minority
  can be relayed **app-level (opaque ciphertext) through the existing tunnelled
  relay**. So: **no libp2p, no coturn, no DHT**; the self-hosted tunnelled relay stays
  the accepted bootstrap node + relay-fallback. WebRTC stays behind the `FrameChannel`
  seam, so libp2p remains a clean future swap if that ever changes.
- **2026-06-27** — **Relay offline courier + P2P connectivity hardening.** Wired the
  existing `RelayTransport` (POST `/messages` + poll `/poll`) into every
  `ChannelSession` as a fallback courier — messages now go to both P2P peers AND
  the relay on send, and new sessions poll the relay for anything missed while
  offline. The courier **pauses** when at least one P2P peer is connected (no wasted
  polls in steady state) and **resumes** when the last peer drops. This fixes the
  "both restart with relay down → messages don't flow" gap.
- **2026-06-27** — **Peer-exchange over the data channel.** `_emitPeer` now
  broadcasts `PeersControl` (our other connected peers) on every new connection;
  `_handleControl` initiates connections to any listed peers we don't already have.
  `SignalControl` carries signed offer/answer/ICE through the mesh (relayed
  signalling), so new connections can form without touching the relay at all once
  you hold a single live link. Together with the **candidate cache** (Hive-backed
  `CandidateCache` storing known peer pubkeys per channel, TTL-based expiry at
  7/14/60/90 days with staggered startup retries), reconnection is near-instant.
- **2026-06-27** — **Contacts-online discovery (later privacy-scoped).** The
  initial implementation broadcast connected identities across channels. It was
  subsequently restricted to peers currently connected in the same channel:
  cross-channel identities did not provide a valid signalling route and leaked
  unnecessary social-graph metadata. See the 2026-08-25 routing decision below.
- **2026-06-27** — **Signed auto-update with P2P version enforcement.** A release
  signing key (Ed25519, generated offline via `sign-release.ts keygen`) produces
  signed manifests with a monotonic `seq` (downgrade protection). The relay serves
  the manifest at `GET /version` (persisted to disk, survives restarts); CI pushes
  it via `POST /version` (authed by `RELEASE_SECRET`). Clients verify the signature
  against a **hardcoded release public key** at startup (forced gate — blocks the
  app if an update is detected). **P2P version enforcement:** on peer connect, each
  side sends a `VersionControl` carrying the signed manifest; the receiver verifies
  independently and triggers the gate if valid + newer. Valid manifests propagate
  epidemically — a single peer seeing the relay spreads the update to the whole mesh.
  Seq is only persisted once you're *running* the matching version (not on detection),
  so missed updates re-trigger on next check.
- **2026-06-27** — **Authenticated signal mailbox reads (Option C).** `POST /announce`
  now accepts an Ed25519 signature over `"announce|channel|pubkey|ts"` (timestamp
  within 30s). A valid signed announce returns a short-lived **token** (random hex,
  60s TTL) that authenticates subsequent `GET /signal` reads. Unauthenticated
  announces still work (backward compat) but receive no token. This prevents
  strangers from polling your signal mailbox to observe ICE candidates / IPs.
- **2026-06-27** — **Per-pubkey rate limiting.** Signal POST: 60 per 10s per sender.
  Message POST: 30 per 10s per author. Prevents a flood from evicting legitimate
  entries from bounded mailboxes/channel stores.
- **2026-06-27** — **UX improvements.** Unread badges per channel (Hive-backed
  `UnreadStore`, marks-read on view, zero on initial load). Background-channel
  notifications (SnackBar). Auto-scroll only when near bottom (not when reading
  history). Composer focus retention (FocusNode survives send). Contacts management
  page (rename, remove, DM, invite-to-channel from a single view). Message slide-in
  animation. "On fire" effect (orange glow + 🔥) when someone sends 4+ msgs in 5s.
  Polished composer (rounded, filled). Version display in drawer header.
- **2026-06-27** — **Bundle ID renamed** `com.example.chat_app` → `com.hearth.app`
  across Android, iOS, macOS, Linux. Dart package `chat_app` → `hearth`. All
  platform configs, Kotlin source, and test imports updated.
- **2026-06-27** — **Windows mic fix.** `getUserMedia` now enumerates audio inputs
  and targets the first by `deviceId` (with `autoGainControl` + `noiseSuppression`),
  then force-enables tracks — fixing the silent-mic issue on Windows desktop where
  the native WebRTC layer picks a non-functional default device.
- **2026-06-27** — **Relay tunnel for symmetric-NAT pairs (removed
  2026-08-30).** When ICE fails 3
  times consecutively, the mesh opens a `RelayTunnel` — a `FrameChannel` that
  POST/polls opaque frame text through `/tunnel` on the relay. Same E2E
  guarantees (the relay sees ciphertext), just routed instead of direct. The
  relay pairs frames by `from|to` with a bounded buffer (100 entries, 30s TTL).
  Tunnels are tracked and closed if a direct WebRTC connection later succeeds.
- **2026-06-27** — **Exponential mesh retry backoff.** Connection failures now
  back off exponentially: 10s → 20s → 40s → 80s → 160s → 300s (5min cap).
  Resets on successful connection. Prevents a flapping peer from thrashing the
  announce/signal loop.
- **2026-06-27** — **Security hardening: mandatory token auth on all relay
  endpoints.** At the time, GET `/signal`, POST `/signal`, POST `/tunnel`, and
  GET `/tunnel` all
  now **require** the auth token from a signed announce (403 without). Tokens
  are short-lived (60s), issued only on Ed25519-verified announces, and bound to
  a pubkey — so an attacker can't read mailboxes, inject garbage signals, or
  drain tunnel buffers without first proving identity. Per-pubkey rate limiting
  (60 signals/10s, 30 messages/10s) prevents flooding even by authenticated
  peers.
- **2026-06-27** — **ContactsOnline hardened.** Incoming `ContactsOnlineControl`
  is capped at 20 entries and filtered to peers we recognise from our candidate
  cache — prevents a malicious peer from triggering mass connection attempts to
  arbitrary pubkeys.
- **2026-06-27** — **Typing indicators.** `TypingControl` frame (sent on input
  change, cleared after 3s idle or on send) drives a "X is typing…" line below
  the message list. Lightweight — rides on the existing mesh control channel.
- **2026-06-27** — **Deafen reflects on mute.** `isMuted` getter now returns
  true when deafened, so the mute button's visual state matches the mic's
  actual state (Discord parity — undeafen restores prior mute state).
- **2026-06-28** — **AI bot (not distributed inference).** Added `@bot` mention →
  local LLM inference via fllama (llama.cpp FFI). The model runs entirely on ONE
  peer's device — originally explored true distributed inference (splitting layers
  across mesh peers) but llama.cpp has no partial-layer API, and WebRTC latency
  (~20-80ms per hop × 32 layers) makes it impractical (~2-3s per token). Instead:
  decentralised *hosting* — any peer with a model volunteers, requests are broadcast,
  first responder wins. Model picker in Settings → AI downloads GGUF files from
  HuggingFace (TinyLlama 1.1B / Phi-3 3.8B / Mistral 7B). Runs on CPU by default;
  `numGpuLayers: 99` enables Metal (macOS) or CUDA (Linux/Windows) offload
  automatically when available. Easy to rip out: inference_bot.dart + control
  frames + ~30 lines in main.dart.
- **2026-06-29** — **Block & mute — no channel ownership.** Rejected the
  "channel owner can kick" model entirely. Hearth has no hierarchy — channels are
  capabilities, not property. Instead: (1) **Voice mute** — ephemeral per-session
  toggle that zeroes a member's audio and replaces their speaking bar with a mute
  icon; resets on leave; purely local. (2) **Block** — global persistent action
  against a pubkey. Future messages in shared group channels render as redacted
  placeholders (message stays in DAG for unblock); DMs from the blocked user are
  silently dropped on receive (never stored — gone permanently). Auto-muted in
  voice (persistent across sessions). Accessible from member list or contacts menu.
  Unblock restores redacted group messages instantly. No MeshControl needed — this
  is entirely client-side state. The blocked person's client continues normally;
  they have no signal they've been blocked. Storage: `blockedUsers` key in Hive
  settings (comma-separated pubkey hexes).
- **2026-06-27** — **Screen share + YouTube watch party (Windows-first).** Both
  gated behind being in voice. **Screen share:** a per-sharer WebRTC mesh on
  `screen:<channel>:<sharer>` where the sharer is the sole offerer
  (`forceInitiator`), giving a star topology + one-way media with no
  renegotiation; `desktopCapturer` picks a window/screen with a configurable
  resolution. **Watch party:** a host-controlled `flutter_inappwebview` IFrame
  player synced over the voice mesh (`YoutubeControl`), followers can't fight
  playback (`controls:0`) but can mute/close locally. Video-id + position are
  validated before touching the WebView (JS-injection guard); nav is
  suffix-allowlisted to YouTube hosts.
- **2026-06-28** — **QR invites.** Invite screen renders the invite code as a QR
  (`qr_flutter`); mobile scans it to join (`mobile_scanner`).
- **2026-06-28** — **Relay hardened for public exposure.** The relay is now
  assumed internet-reachable, so: bounded memory everywhere (LRU caps on
  channels / presence / mailboxes / rate-limiter maps; `MAX_CHANNEL_MESSAGES`),
  a **per-IP** global rate limit (catches keypair-rotating attackers), removal of
  the **unauthenticated `GET /peers`** and the unsigned-announce fallback (a
  signed announce is now mandatory), `timingSafeEqual` on the `RELEASE_SECRET`
  check, HTTP-relay rejection client-side, and a `MAX_BODY_BYTES` cap. Auth token
  moved from a query param to the `Authorization: Bearer` header. Distroless relay
  image (esbuild bundle, Node 24). Relay self-heals its version manifest from the
  latest GitHub release on startup.
- **2026-06-29** — **Read receipts.** `ReadWatermarkControl` broadcasts each
  peer's latest-read message id over the gossip mesh; the UI renders WhatsApp-style
  ticks. Re-broadcast on new-peer connect (so a fresh joiner learns state) and
  backfilled when a referenced id syncs late. Disable-able per DM; state is
  per-channel and local.
- **2026-06-30** — **Messaging UX batch.** Replies (quote-and-respond),
  emoji reactions (chips on the target), pinned messages (local, per-channel),
  in-channel search, per-channel mute, plus animation polish (per-channel accent
  colour, typing dots, cascade-in on batch arrival, slide-in scroll-to-bottom
  FAB). Also a **10 MB blob cap** enforced on both upload (`put`) and receive
  (sync), so oversized media can't be pushed into the store.
- **2026-06-30** — **Notifications shipped without FCM.** Rejected the
  FCM/Firestore-token path (keeps the app Google-free and needs no server-side
  token registry). Instead: **web** uses the Notification API (permission on first
  gesture); **Android** uses `background_fetch` — a headless isolate polls the
  relay `/poll` on a JobScheduler interval (≥15 min) from Hive-persisted state and
  raises a local notification; **Windows** stays resident and notifies live. In-app
  notifications carry sender name + content preview + tap-to-open, and are
  suppressed for muted channels and blocked users. Trade-off accepted: Android
  background latency is bounded by the 15-min JobScheduler floor, not instant push.
- **2026-07-01** — **Code-review follow-ups.** (1) Background-notification
  accuracy: the poller now excludes muted channels, seeds its cursor from the
  foreground courier's relay seq (forward-only), establishes the baseline silently
  on first poll (no "entire backlog" flood), and skips our own relay-echoed
  messages. (2) Relay tunnel: cap distinct `(from|to)` pairs with LRU eviction so
  undrained buffers to never-polling recipients can't grow the map unbounded.
  (3) WebRTC failover is no longer sticky — the client re-probes the primary relay
  ~once a minute and returns to it after it recovers. (4) Read-watermark timestamp
  lookup is cache-guarded (no O(n) history scan per repeat watermark).
- **2026-07-01** — **Identity backup upgraded to a BIP39 recovery phrase.** The
  seed export/import already existed (QR + base64/hex code); replaced the raw code
  as the primary human form with a **24-word BIP39 mnemonic** — easier to write
  down and, crucially, **checksummed**, so a mistyped/transposed word is rejected
  instead of silently restoring a *different* identity (a raw base64/hex code
  can't catch that). The QR now encodes the phrase too; restore accepts the phrase
  or scans the QR. (The old base64/hex code path was dropped, not kept for
  back-compat — no users are live yet.) Codec is a self-contained
  `core/mnemonic.dart` (the standard entropy↔mnemonic mapping, *not* BIP39 PBKDF2
  key-derivation — the seed already is the Ed25519 key), verified against the
  official BIP39 English test vectors.
  This closes the "no identity backup" gap flagged on 2026-06-21. Tier-b
  (per-device subkeys + revocation) remains unbuilt.
- **2026-07-01** — **Code-review fixes (security/robustness).** (1) **Removed the
  relay force-block.** A released build used to show a full-screen "connect to a
  relay" gate whenever the relay was *unreachable*, making the optional relay a
  hard single point of failure — a direct contradiction of the local-first
  principle. Now only a **confirmed newer release** forces an update (still
  enforced peer-to-peer via `VersionControl`); an unreachable relay no longer
  blocks the app, so it keeps working P2P/offline. (2) **Windows self-update
  guard** — the updater `rmdir`s its own install dir, so it now refuses to run
  from a drive root / suspiciously short path (a portable build in an odd
  location must not wipe its parent). (3) **Canonical manifest signing** — the
  update manifest is now signed over a fixed-field, newline-joined form
  (`backend/src/manifest.ts` ↔ `update_checker.dart`), not `JSON.stringify`, so
  verification no longer depends on JS/Dart serializers matching byte-for-byte;
  a shared test literal in both suites guards cross-language drift.
- **2026-07-02** — **UI polish pass (colour + animation).** Colour: per-user /
  per-channel colours now derive from **OKLCH** (perceptually uniform, legible on
  either theme) instead of HSL; gradient avatars; the channel accent tints the
  drawer, unread badges and composer focus ring. Added a **light/dark/auto**
  theme (warm parchment vs charcoal, dark default) with a settings selector, and
  accent colours + badge text adapt to brightness. Animation: a breathing
  **ember glow** app-bar background; audio-reactive **voice speaking rings**; a
  **Hero** full-screen image viewer; **pull-to-refresh** (re-announce + relay
  recheck); a **reaction burst**; **shared-axis** channel transitions (via the
  `animations` package); and an animated **send button**. Continuous ambient
  animations are gated behind `_ambientAnimations` (off under `flutter test`, so
  `pumpAndSettle` still settles); one-shot animations run normally.
- **2026-07-04** — **Block now actually drops DMs (was only redacting).** The
  2026-06-29 block model promised "DMs from a blocked user are silently dropped
  on receive (never stored)", but only the *group* half (store-in-DAG +
  render-redacted) was implemented; DM messages from a blocked peer were still
  ingested and stored, merely hidden at render. Now blocking a peer **closes any
  DM with them and stops it restoring** (`_blockPeer`), and `ChannelManager.openDm`
  refuses a blocked peer (`isBlocked` guard) so no DM session — hence no
  mesh/courier/ingestion — exists for them. Future messages are never received
  or stored; past history stays on disk (unreachable) rather than being purged,
  so an unblock + re-DM would surface it again. Groups are unchanged
  (store-redacted, restore on unblock). Surfaced by the post-release review of
  the contact-card work.
- **2026-07-03** — **Contact cards — cold-start DMs without a shared group.**
  Closed the gap where you could only DM someone whose pubkey you already had
  (via a mutual group or an invite). A **contact card** is the person-level
  analogue of a channel invite: a `hearth-contact:` code (QR + paste, distinct
  scheme so it's never confused with the recovery-phrase QR) carrying your
  pubkey, suggested name, home relay, and an **unguessable rendezvous
  capability** you listen on. The rendezvous id is random, **not** derived from
  the pubkey, so only people you hand a card to can reach you — deliberately
  **not** an always-on pubkey-addressed inbox (option B was considered and
  rejected: it's the enumerable/spam surface). Leak/spam → mint a new card;
  existing DMs are unaffected (they live on their own derived channel).
  **First contact reuses the whole stack:** the joiner announces on the owner's
  rendezvous (a bare `WebRtcMesh`, no cipher/DAG traffic — `rendezvous.dart`),
  signed signalling (`signal_auth`) proves each side's identity, and both then
  call the existing `openDm(peerPubkey)` → the identical derived + **PairBox**
  DM. The rendezvous is introduction-only; the conversation is a normal DM, and
  nothing in the DM/crypto path changed. Also folded in a latent fix: **DMs are
  now persisted (`DmRegistry`) once they have real history and restored on
  startup** like groups (previously only groups restored; a DM only lived while
  on screen). `WebRtcMesh` gained an `onPeerConnectedHex` hook (symmetric with
  `onPeerLeft`) so the rendezvous learns who reached it. **Durable first
  contact (same day):** a scanned card is persisted as a `PendingContact` and
  the joiner keeps announcing on the owner's rendezvous across network drops
  *and* app restarts (resumed on `_init`), retiring the attempt only once the
  DM connects (`onDmConnected` → also records the DM so it restores) or after a
  7-day backstop expiry. So first contact now lands "whenever you're both next
  online", not "both online in the same window". Stays purely outbound (people
  you chose to reach), never an inbound stranger inbox. **Inbound is a
  content-free connection request:** someone reaching your card who *isn't
  already a contact* is recorded as a request (`RequestStore`, persisted) — but
  **no DM is opened**, so they cannot deliver or store a single message on your
  device until you accept. A stranger can announce "I'd like to talk", nothing
  more; the request shows their identity (`hearth#fingerprint`) with **Accept /
  Decline / Block**. Accept runs the usual add-a-petname prompt and only then
  opens the DM (messages start flowing); Decline/Block just forget the pubkey —
  there is never any received content to purge. The joiner's composer is gated
  ("Waiting for X to accept your request") until the DM connects, so a
  well-behaved client can't even queue a message pre-accept. A known contact (or
  a DM you started) is unaffected — the gate is only for inbound first contact.
  **Known limit:** live two-client rendezvous is unverified without a real relay.
  Decisions taken with the user: one rendezvous per identity (not per card),
  restore only DMs with established history, inbound first contact delivers **no
  message content** until explicitly accepted.
- **2026-07-02** — **Messaging batch: edit/delete, markdown, voice messages,
  avatars.** (1) **Edit & delete** fit the append-only DAG: an edit/tombstone is
  a new envelope (`EditContent`/`DeleteContent`) referencing its target;
  `ChannelSession` rebuilds a revision index on refresh where the
  topologically-last edit wins (deterministic on every device) and revisions are
  honoured **only when their author matches the target's author** — a forged
  edit from another key is ignored (widget-tested). Composes under encryption;
  nothing is ever removed from the DAG. (2) **Chat markdown** — a small
  hand-rolled tokenizer (bold/italic/strike/inline code/fenced blocks/links; no
  dependency — flutter_markdown is discontinued and document-shaped). Discord's
  whitespace rule keeps `2 * 3 = 6` and snake_case literal. (3) **Voice
  messages** — mic button records AAC (`record` package), sends as a
  content-addressed blob with duration in the envelope; playback bubble with
  lazy AudioPlayer. macOS gained the mic entitlement for dev. Hidden on web.
  (4) **Custom avatars** — `ProfileContent` gains an optional avatar blob hash;
  the picked image is downscaled to a ≤128px PNG via `dart:ui`, gossiped like
  any blob, and rendered **inside** the pubkey-derived gradient (kept as a ring)
  so the deterministic colours stay the spoof-resistant cue — consistent with
  the petname model's "self-asserted = suggestion, never identity".
- **2026-07-02** — **Android updates download via the system DownloadManager.**
  Previously the APK streamed in-process (`http`), so locking the screen or
  closing the app mid-download killed it. Now a platform channel
  (`hearth/downloader` in `MainActivity.kt`) hands the download to Android's
  **DownloadManager**, which runs in a system process that survives
  background/lock/close and resumes across connectivity drops. Dart enqueues,
  polls status for progress, then **stream-verifies the SHA-256 against the
  signed manifest** before install (same guarantee as before). The pending
  download id + hash are persisted, so `resumePendingUpdate()` on next launch
  finishes an interrupted one (verify + install, or re-attach if still running).
  Windows keeps the in-process flow. No new permissions (app-private storage).
- **2026-07-04** — **@mentions with mention-aware notifications.** `<@pubkeyHex>`
  tokens in message text resolve to the viewer's petname at render time (never
  displays raw hex). A mention picker (triggered by `@` in the composer) lists
  channel members. Notifications highlight messages that mention you.
- **2026-07-04** — **Multi-device identity — Phase A (concurrent multi-device,
  cosmetic revocation).** Shipped all five sub-phases:
  - **(A1) Device certificates** — `DeviceCert` (root signs device subkeys) and
    `DeviceRevocation` in `core/device.dart`. Canonical CBOR signed bytes, JSON
    round-trip, cross-language interop vector locked with the TS relay.
  - **(A2) Device-signed messages** — `Message.create()` accepts `signingDevice`
    + `deviceCert`; messages are *authored* by the root but *signed* by the
    device. `verify()` checks the cert chain: root→device→message. The relay
    (`verifyWire`) also verifies the chain so `author` stays authenticated for
    rate-limiting.
  - **(A3) Device enrollment in the app** — `DeviceKeys.loadOrCreate()` generates
    a stable per-device subkey (persisted in a separate SecureKeyStore slot) and
    re-issues its cert each launch.
  - **(A4) Mesh keyed by device identity** — `WebRtcMesh` announces and signals
    using the device key (not the root). Two devices of the same person appear as
    distinct peers — they connect to each other and coexist without glare or
    mailbox collisions. A `deviceToRoot` map (populated from message certs)
    resolves device mesh peers to root identities for display (typing, presence).
  - **(A5) Device list UI + revocation** — Settings → Devices tab lists enrolled
    devices (name, issued date, this-device marker, revoked badge). Rename
    re-issues cert; revoke issues a signed `DeviceRevocation`, gossips it via
    `DeviceRevocationControl` over the mesh, and peers verify + persist it.
    Enforcement: `SyncEngine.receive()` and `SyncSession._receive()` drop
    messages from revoked devices. Display-time filter hides already-stored
    messages from since-revoked devices.
  Phase A revocation is "cosmetic" — the stolen device still holds the root seed
  and can re-enroll. Real crypto lockout is Phase B.
- **2026-07-04** — **Multi-device identity — Phase B (per-device DM encryption,
  cryptographic revocation).** Shipped five sub-phases:
  - **(B1) MultiDeviceBox** — encrypts a DM plaintext with a random content key,
    then wraps that key to each recipient device's X25519 key via ECDH. Only
    devices that hold a wrap can decrypt. Wire: `version(1) ‖ count(1) ‖
    [devicePub(32) ‖ wrapNonce(12) ‖ wrapMac(16) ‖ wrappedKey(32)]* ‖
    contentNonce(12) ‖ contentMac(16) ‖ ciphertext`.
  - **(B2) DeviceBundle** — a root-signed claim listing active device Ed25519
    keys, published epidemically as `DeviceBundleContent` (bookkeeping message).
    Peers verify the signature + monotonic timestamp (rejects replay of older
    bundles that would re-add a revoked device). Stored per-peer in `DeviceStore`.
  - **(B3) MultiDeviceDmCipher** — wired end-to-end. Encrypts DMs with
    `MultiDeviceBox` when a peer's device bundle is available; falls back to
    `PairBox` for legacy peers. Decrypt uses `message.device` as a sender hint
    (O(1) ECDH). Own device bundle published on boot and after revocations.
  - **(B4) Offline root prep** — `MultiDeviceDmCipher.selfRoot` is nullable.
    When null: MultiDeviceBox works (device ECDH); PairBox messages show 🔒;
    revoke/rename disabled (require root signing).
  - **(B5) Offline root boot flow + enrollment ceremony** — The root seed is no
    longer required at runtime. Boot checks: root seed (legacy) → device+cert
    (offline-root) → enrollment UI. `Identity.fromPublicKey()` creates a
    signing-disabled identity. First boot shows "Create new identity" (shows
    phrase, signs cert+bundle, discards root) or "Enroll this device" (enter
    phrase, derive root transiently, sign, discard). Stale Hive data wiped on
    identity switch. Backup/restore/rename/revoke correctly guarded for canSign.
  A revoked device is now **cryptographically locked out** of future DMs — it
  receives no key wrap in future `MultiDeviceBox` messages.
- **2026-08-23** — **Relay restart recovery and shared-NAT bootstrap hardening.**
  Relay responses now carry a random process epoch. Foreground signalling,
  foreground courier polling, and Android background polling bind their cursors
  to that epoch and retry from zero after a container restart or relay failover,
  preventing a pre-restart cursor from suppressing every new offer/message.
  Increased the bounded per-IP request budget from 60 to 300 requests/minute:
  two clients behind one router each maintain channel, voice, and standing
  contact rendezvous loops, and the old ceiling could rate-limit their own SDP
  and ICE before a direct P2P link formed.
- **2026-08-25** — **Peer-routed signalling completed and hardened.** The
  previously defined `SignalControl` is now used for outbound offers, answers,
  and ICE whenever any live same-channel link exists. Peer exchange teaches
  next hops in both directions; authenticated traffic teaches reverse routes;
  bounded flooding covers missing routes; relay duplication was retained at
  that point and removed by the 2026-08-30 direct-first policy. Every hop verifies the
  origin signature and group capability before forwarding. Six-hop TTLs,
  two-minute/4096-entry deduplication, 256 KiB signal limits, 64-peer fanout,
  and 512 routed signals per ingress peer per minute bound abuse. Cached peers
  are retried whenever a surviving link opens and the live component can route
  to them, while historical peer lists stay private because an offline identity
  is not a usable route. A relay is still required for a true cold start or to
  join disconnected components. Contacts-online routes are scoped to their
  originating channel so one mesh cannot install a bogus next hop learned from
  another.
- **2026-08-25** — **DM courier uploads made on-demand.** Added a bounded ACK
  gossip frame that a peer sends only after validating and durably storing a
  message. Local publication registers its ACK waiter before gossiping to avoid
  races. A DM accepts a receipt only from a currently admitted device owned by
  the remote identity; if one confirms custody within 1.5 seconds, the sender
  skips the relay copy and relies on epidemic forwarding. Another device owned
  by the sender cannot suppress that fallback. Groups always retain their
  encrypted courier copy because arbitrary group members are not trusted custody
  witnesses.
  Invalid, disallowed, revoked-device, and capacity-rejected messages are never
  ACKed. Authenticated LAN discovery remains a deferred README item.
- **2026-08-25** — **Routine relay work distributed across the live component.**
  Primary channel meshes now select two rotating relay workers using
  time-varying SHA-256 priorities over consistent authenticated direct device
  ids. A node compares itself with its direct neighbours, so the component-wide
  highest priority always self-selects even under partial topology views. The previous
  slot overlaps for 30 seconds, small components keep every peer active, and
  peerless or handshaking nodes always perform their own
  relay work. Standby peers pause announce and courier polling, drain
  identity-addressed signals for 50 seconds, then make staggered fail-safe
  rendezvous, signal, and courier probes at least every two minutes. They
  immediately resume full activity on duty change or connectivity loss. The role
  confers no admission, decryption, or verification authority.
  Rotation prevents permanent lowest-key capture; redundancy tolerates one
  uncooperative selected member; differing topology or clock views create extra
  workers rather than a relay blackout. Voice and
  screen-star meshes remain unchanged until their distinct topologies receive a
  separate design.
- **2026-08-26** — **Authenticated relay-visible presence and rendezvous fix.**
  Announcements now return short-lived Ed25519 presence evidence; group claims
  additionally carry a channel-key HMAC. Clients verify the evidence locally and
  use it only to decorate already-known identities, showing a distinct relay icon
  beside members and contacts who are online without a direct WebRTC path. Direct
  peers retain the normal green status without the icon. Answer-only WebRTC peers
  now poll the signal mailbox immediately instead of repeatedly postponing the
  incoming offer behind the idle poll interval.
- **2026-08-30** — **Direct-first voice signalling and discovery-only live
  fallback.** Voice SDP/ICE can now travel over the established parent channel
  mesh, including bounded same-channel forwarding, before its own relay
  rendezvous starts. Current voice presence, direct channel peers, and eligible
  cached channel identities seed those attempts. Successfully peer-routed
  signals are no longer duplicated to the relay; relay signalling is selected
  after repeated connection failures. The app-level `/tunnel` data transport
  and server route were removed, so neither live chat data nor voice can be
  reported as relay-connected. Persistent caches retain authenticated peer
  identities, not stale ICE addresses or ephemeral UDP ports.

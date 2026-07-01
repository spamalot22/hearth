# Hearth — Implementation Plan

> **Hearth** — a gamer-focused, open-source, decentralised Discord alternative.
> Local-first, peer-to-peer by default, with an **optional** coordination
> backend that improves reliability but is never required to function.

_Status: living document. Last updated: 2026-07-01._

---

## Product scope (target feature set)

- **Channels are the core primitive** — a channel is a shared, replicated message
  DAG. **Group channels** (many members) and **direct messages** (a private
  2-person channel) are the *same* primitive; only membership scope + encryption
  differ.
- **Text now; voice next** — text chat works today. Real-time **voice, video, and
  screen-share** come via WebRTC (Phase 3); symmetric-NAT pairs use a relay-fallback (not coturn).
- **End-to-end encrypted by default — everything.** Signed today, encrypted next —
  the payload is opaque bytes (and messages carry a `v` version), so encryption
  slots in with no breaking change. **Decided:** **DMs *and* group channels are
  E2E-encrypted by default** — privacy first. An opt-*out* to plaintext may come
  later, but only where a specific feature genuinely needs it (server-side
  search/moderation, content-reading bots, or open public channels — see the
  encryption-cost note in §6). Implementation: DMs use a **sealed box** (X25519 —
  lands first); encrypted groups need a defined member set, so group encryption
  rides with group membership, and **MLS** adds forward secrecy + key rotation.
  Caveat: encryption hides payloads, not relay-visible metadata (who/when).
- **No central accounts — identity is a keypair.** "Account" features map onto the
  key: **profiles** (signed metadata), **names** via the **petname model** (each
  user assigns private local petnames; the other side's self-asserted nickname is
  only a *suggestion* — no global authority; an optional directory exists later
  just for cold discovery), **recovery** (seed backup) and **multi-device** (root
  key certifies device subkeys, §5). Optional OIDC login is a per-community add-on.

---

## 0. Guiding principles

1. **Local-first.** Every device is a full node with its own copy of history.
2. **Graceful degradation.** If the backend dies, existing chats keep working;
   you only lose *convenience* (new-user discovery, offline relay, push). No
   single point of failure.
3. **Identity = keypair, not an account.** No company owns who you are.
4. **One language per layer, clean boundary.** Dart for the client (`core` +
   `app`); **TypeScript** for the serverless backend. The only cross-language
   cost is re-implementing Ed25519 *verification* server-side (trivial with
   `@noble/ed25519`). Keep `core/` free of Flutter imports so its hot paths can
   move to Rust later if ever forced.
5. **Ship the data model first.** Prove signed messages + ordering before
   touching NAT traversal or voice.

---

## 1. Tech stack decisions

| Concern | Decision | Status |
|---|---|---|
| UI (all platforms) | **Flutter / Dart** | ✅ decided |
| Core logic (identity, message DAG, sync) | **Dart**, isolated behind an interface | ✅ decided |
| Crypto (signing) | **Ed25519** — `cryptography` (Dart client) / `@noble/ed25519` (TS backend) | ✅ decided |
| Real-time transport (P2P) | **WebRTC** (`flutter_webrtc`) data channels + media | ✅ decided |
| Backend (cold-start rendezvous) | **Self-hosted Hono relay** (TypeScript, Docker, in-memory, no DB) — pubkey signalling mailbox + media proxies; **tunnelled** (Cloudflare Tunnel), not port-forwarded | 🔄 revised — was Firebase (see Rendezvous & Deployment) |
| Backend framework / tooling | **Hono** · Docker Compose (the IaC) · **GitHub Actions on a version tag → GHCR**, box pulls | ✅ decided |
| NAT fallback (symmetric NAT) | **App-level encrypted relay** through the tunnelled relay — no coturn, no UDP, no port-forward; hole-punching (WebRTC ICE) handles every other pair | ✅ decided |
| E2E encryption (default) | DMs **sealed box** (X25519, next); groups need membership → **MLS (RFC 9420)** for forward secrecy / rotation (likely Rust `openmls`) | 🔜 next |
| Heavy P2P (DHT / libp2p) | **Decided against** (2026-06-25) — doesn't reach zero-servers (media proxies + bootstrap remain) and costs a full Rust integration; the no-coturn goal is met in Dart | ❌ dropped |

### Target platforms (priority order)
1. **Windows + Android** — the primary targets. Iterate locally on **Android**
   (builds on the Mac) plus macOS/web for speed; **Windows builds via CI/VM**
   (can't build Windows on macOS).
2. **Later / secondary:** iOS, macOS, Linux, web. The Flutter project already has
   all platform folders, so adding them later is free — just not a focus now.

Deferring iOS removes the only hard cost floor (Apple Developer $99/yr); it
returns only if/when we ship iOS.

### Why TypeScript for the backend (not Dart)?
- The backend is a thin rendezvous surface, not shared client logic — the
  "reuse `core`" argument is weak here.
- TS is the native language of Firebase Cloud Functions; that first-class tooling
  matters more than language unity for a handful of small functions.
- Cost: re-implement Ed25519 *verification* server-side. Trivial — both sides are
  RFC 8032 Ed25519, so they interoperate given a canonical signed encoding.

### Why not a Rust core from day one?
- It triples build complexity (FFI + building for 6 targets) for a prototype
  that may still pivot.
- The only place Dart is genuinely weak (MLS group crypto) is a Phase 3+ concern.
- **Mitigation:** keep `core/` free of UI and Flutter imports so it can become a
  Rust module later with the UI untouched.

### The escape hatch (when we'd reach for Rust)
- We implement MLS for scalable group key rotation → `openmls` (Rust).
- Profiling shows DAG merge / crypto is a hot path in Dart (unlikely early).

---

## 2. Architecture

```
Flutter UI — Windows · macOS · Linux · iOS · Android · web
│
├─ core/  (pure Dart, no Flutter imports)
│    identity/   Ed25519 keypair = user ID
│    model/      signed, content-addressed message
│    dag/        causal ordering + CRDT merge
│    store/      local persistence
│    transport/  RelayTransport (Phase 1) · WebRtcTransport (Phase 2, P2P)
│
└─▶ rendezvous only — never a source of truth
        │
   backend/  (TypeScript · Hono · self-hosted Docker · tunnelled · in-memory)
        cold-start  pubkey-addressed signalling mailbox (offer/answer/ICE)
        media       GIF/sound search proxies (server-side API keys)
        ── only hit on cold start; steady-state presence/peers/msgs are P2P ──
        ── pluggable URL (rides in invite) · holds NO plaintext / history ──
        │
   relay-fallback  (same relay, app-level · no coturn · no UDP)
        forwards opaque ciphertext for the ~15% symmetric-NAT↔symmetric pairs
```

### Repo layout (polyglot monorepo)
```
/core      Dart package, no Flutter — protocol, identity, DAG (shared by app)
/app       Flutter app (depends on core)        ── Dart pub workspace ──┘
/backend   TypeScript — Hono relay; Dockerfile + docker-compose.yml (the IaC),
           tunnelled (Cloudflare Tunnel); shipped via GitHub Actions on a tag → GHCR
           (TURN, when needed, is managed/VPS — not in this repo's deploy)
```

### The client/backend relationship (important)
- **The client works P2P with no backend at all.** Two installed clients talk
  directly (WebRTC) once they can reach each other. This is the default.
- **The backend is optional rendezvous infrastructure**, not a host of truth. It
  only helps peers *find* each other and relays encrypted, TTL'd data.
- **Default deploy = a self-hosted, tunnelled Hono container ($0 on hardware you
  already run).** Self-hosters run the *same* in-memory relay image (GHCR) as a
  Docker Compose stack behind a Cloudflare/Tailscale tunnel — no Firebase, no DB,
  no separate server codebase. (Firebase was the original plan; superseded by the
  2026-06-25 self-hosted-relay pivot logged below.)
- **The rendezvous endpoint is pluggable in the client** (point at any backend
  URL). That is what keeps it decentralised: your self-hosted relay is just the
  default bootstrap node — replaceable, not authoritative.
- **Cold-start caveat:** two peers who've *never* connected need a rendezvous point
  (the self-hosted relay, or LAN/mDNS) for the first handshake. Fully serverless first
  contact would need a DHT, which we've decided against — the relay stays.
- **Single point of failure is limited to *new* connections:** if the backend is
  down, existing P2P sessions keep working.
- **Offline delivery is epidemic, not routed.** Every message is signed +
  content-addressed, so *any* peer can carry and re-serve another's messages
  without forging or altering them (recipients verify the author's signature
  directly); with DM payloads sealed to the recipient, carriers relay **blind**.
  So A can message an offline C, go offline, and C later syncs it from a carrier B
  who couriered it without reading it. The optional backend relay is just "a
  carrier that's always online" — it makes best-effort peer carry reliable. No
  durable database is required for this, only for the *convenience* of an always-on
  holder (and for push). Caveat: a carrier still learns it holds a message authored
  by A; hiding the recipient is a later sealed-sender step.

### Rendezvous & connectivity (server-minimal, contact-graph)

**Principle: the server is a cold-start bootstrap, not a participant.** Once a peer
has *any* live P2P link, the backend is out of the loop — messages, presence, peer
discovery and address updates all flow over the mesh. The happy path (any peer
reachable) touches **no server**; a server outage only blocks the narrow "came
online and literally nobody is reachable" cold start.

**Identity-addressed, contact-scoped — no channel-wide presence, no strangers.** We
never broadcast presence to a channel or track strangers; each peer is reached by
its **pubkey**, and you only care about your **contacts'** presence.

**Re-establishing a connection — the ladder, cheapest first:**
1. **Cached last-known candidates → direct reconnect.** Works for peers with a
   stable reachable endpoint (static IP / port-forward / non-symmetric NAT with a
   live mapping). Free, instant, no server. *(Caveat: a NAT port mapping is
   ephemeral and often symmetric, so a cached address is frequently a dead door —
   this rung succeeds for the minority, not everyone.)*
2. **Punch via an online mutual contact.** Once you hold *one* live link, ask that
   peer for everyone's *current* candidates and coordinate a simultaneous
   hole-punch (peer-exchange). Reaches the rest of your graph with no server.
3. **Cold-start mailbox (server)** — only when nothing above is reachable: drop a
   signed offer in the peer's **pubkey-addressed mailbox** to get your *first* live
   link, then #1/#2 take over. The only server signalling, and brief — **stop
   polling once connected; no steady-state heartbeat.**
4. **Relay-fallback** — symmetric-NAT↔symmetric-NAT pairs can't go direct at all, so
   the tunnelled relay forwards their (already-encrypted) traffic app-level. No
   coturn, no UDP, no port-forward — a minority case (see Deployment).

> STUN is still used, but only so each peer learns its *own* current public mapping
> to advertise — a free public service, not our cost.

**Presence & peer-exchange are P2P (steady state):** on coming online you re-enter
the mesh and "I'm online / here's my address" propagates over existing links +
gossip; connected peers tell each other about peers + fresh candidates; address
changes propagate the same way. No server polling.

**The contact graph stays connected — no islands:** accepting an invite
**mandatorily adds the inviter as a contact**, and the invite carries the inviter's
**pubkey** (which doubles as the cold-start bootstrap peer). So a channel's
connection edges form the **invite tree**, which is by definition connected.
Bulk-add / new-member prompts densify the tree (resilience if an inviter is
offline); epidemic gossip + carriers cover offline branches (a delay, not a loss).

**So the server's whole job is:** a tunnelled, pubkey-addressed **cold-start
signalling mailbox** + the **media-search proxies** (server-side API keys). It holds
no plaintext, verifies signatures, and is rarely hit. (Fully-serverless first contact
would need a DHT, which we've **decided against**, so the self-hosted bootstrap node
stays — the contact graph keeps it rarely-needed.)

### Deployment (self-hosted, tunnelled)

Because the server is a thin, rarely-hit bootstrap, it's cheapest *and* most private
to **self-host** — and a single always-on container on hardware you already run
(NAS / Proxmox) keeps it dead simple: the relay stays the current **in-memory Hono
app** — no Firestore, no serverless cold-start-state rewrite, no scale-to-zero
gymnastics (all of which existed only to dodge *cloud* cost). On your own box,
polling cost is irrelevant.

**Shape — one Docker Compose stack (this *is* the IaC):**
- **Relay container** (Hono): the pubkey cold-start mailbox + media-search proxies.
  HTTP only, in-memory, no DB.
- **Exposure: a tunnel, not a port-forward.** Behind a **Cloudflare Tunnel** (or
  Tailscale Funnel) the box dials *out*, so **zero inbound ports**, home IP never
  exposed, TLS + hostname for free — strictly safer than forwarding a port, and a
  dynamic home IP becomes a non-issue.
- **No coturn, no TURN box, ever.** The symmetric-NAT minority is handled by an
  **app-level encrypted relay-fallback through this same tunnelled relay** — it
  forwards opaque ciphertext between two stuck peers. No UDP, no port-forward,
  nothing extra to run.

**CI/CD — IaC + tag-triggered pipeline:** the `docker-compose.yml` (+ relay
`Dockerfile` + tunnel config) is the infrastructure as code. **GitHub Actions on a
version tag** (`v*`, that *you* push — not push-to-main) builds the relay image and
publishes it to **GHCR**; the box **pulls** it (Watchtower / webhook / manual
`docker compose pull && up -d`). You control the rollout.

**Decentralised by construction:** the relay URL is pluggable and rides in the
invite; any community self-hosts their own the same way — yours on your NAS is just
the default bootstrap node.

---

## 3. Data model (the part to nail first)

Every message is a signed, content-addressed object forming a DAG:

```jsonc
{
  "id":        "<hash(payload)>",     // content address
  "author":    "<ed25519 pubkey>",    // == user identity
  "channel":   "<channel id>",
  "prev":      ["<id>", "<id>"],      // heads this msg "saw" -> causal order
  "timestamp": 1718900000,            // advisory only, tiebreak
  "payload":   "<bytes>",             // plaintext for now; encrypted later
  "sig":       "<ed25519 signature>"
}
```

- **Ordering:** topological sort of the DAG; ties broken by `(timestamp, id)`.
- **Merge:** append-only set of signed messages = a simple CRDT. Concurrent
  offline posts both survive and order deterministically.
- **Integrity:** altering history breaks every downstream hash.
- **Canonical encoding:** the signed bytes use a *deterministic* serialization
  (canonical CBOR or fixed field concatenation), **not JSON** — so Dart signing
  and TypeScript verification agree byte-for-byte.

---

## 4. Phased roadmap

### Phase 0 — Skeleton
- [x] `flutter create` app + `core/` Dart package, wired as a pub workspace;
      `pub get` + `flutter analyze` clean.
- [x] Toolchain green (Flutter · Android · Xcode/iOS/macOS · web).
- [x] Removed the scaffolded Dart `server` (backend is now Firebase/TS, Phase 1).
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
_Goal: backend becomes signalling-only; messages flow peer↔peer._
- [x] `core`: abstract `Transport` interface; `RelayTransport` is stream-based.
- [x] `backend`: signalling + presence endpoints (announce / peers / signal),
      in-memory for now.
- [x] `app`: `WebRtcTransport` (flutter_webrtc) + mesh manager — Flutter-only, so
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
- [x] **DM encryption** — `SealedBox` + `PairBox` (X25519 derived from the Ed25519
      id) in `core`; the app sends encrypted DMs over a derived DM channel and
      carriers relay blind. Independent of group MLS. (Limitation: both parties must
      open the DM — no auto-join/notify yet.)
- [x] **Self-hosted relay deploy** — DONE. Dockerised in-memory Hono relay shipped
      via GitHub Actions (version tag → GHCR), deployed as a **Portainer stack** on a
      small always-on host, exposed public-HTTPS via a **Tailscale Funnel sidecar** (no
      domain, no port-forward; the tailnet node is the container, not the host). The
      app's relay URL is configurable. Funnel needs **kernel mode** (TUN device).
      Cloudflare Tunnel kept as an alt profile. See `backend/DEPLOY.md`.
- [x] **Stop polling once connected** — adaptive signalling: fast poll (700ms/5s)
      only while a handshake's in flight or peerless, idle (15s/30s) once settled.
- [x] **Server-minimal connectivity (rest)** — cached-candidate direct reconnect +
      mutual-contact hole-punch (peer-exchange) + P2P presence/gossip, so the server
      is touched *only* on cold start.
- [x] **Invite carries the inviter's pubkey**; accepting mandatorily adds the
      inviter (keeps the invite-tree contact graph connected → no islands). Still to
      wire: the mesh actually *using* the inviter as the first cold-start target.
- [x] **Relay-fallback for symmetric-NAT pairs** — the tunnelled relay forwards their
      already-encrypted traffic app-level (no coturn, no UDP, no port-forward). Pure
      Dart; only needed once real users hit a symmetric↔symmetric pair.

### Phase 3 — Groups, voice, and the hard stuff
- [x] Group = replicated log + membership-as-messages (capability model).
- [x] ~~Permission-conflict resolution rule (owner-key-wins)~~ — **rejected**
      (2026-06-29): no channel ownership model. Block & mute are purely local.
- [x] Voice/video over WebRTC media (signaled over the existing layer).
- [x] **Group encryption** — encrypt each message to the channel's member set
      (sealed-box per member); requires the membership above. **MLS** (Rust
      `openmls`) is the upgrade for forward secrecy + efficient key rotation. (DMs
      are already sealed-box-encrypted from Phase 2.)
- Multi-device identity, two tiers:
      - [x] **(a) export/import the root seed** — DONE. A settings "reveal
        recovery phrase" screen shows a **BIP39 24-word mnemonic** (+ a QR
        encoding the same phrase) with a copy-and-auto-clear; restore accepts the
        phrase (checksum-validated, so a mistyped word is rejected rather than
        silently restoring the wrong key) or scans the QR. This is both "same key
        on another device" and the identity **backup/recovery** mechanism. Codec
        lives in `core` (`mnemonic.dart`, BIP39-vector-tested).
      - [ ] **(b) per-device subkeys** certified by a root key — adds per-device
        revocation. Not built: "multi-device" today means copying the same root
        seed to each device.
- [x] **Address cache + peer-exchange** — clients cache contacts'/members'
      last-known WebRTC candidates and gossip current ones over the mesh, so
      reconnects mostly skip the server (server = cold-start fallback only).
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
- [ ] **Rich content** — typed message payloads via a **content envelope**
      (`{t: text|gif|sticker|sound, …}` inside the payload; composes under
      encryption, since we encrypt the envelope):
      - [x] **Emoji** — quick picker added (Unicode text already worked).
      - [x] **GIFs (URL)** — paste-a-URL renders inline; **Giphy/Tenor search** still
            needs a provider **API key** (credentials — ask the user for it).
      - [x] **Stickers** — sticker picker panel (browse your library of received/
            sent stickers for quick reuse, like the emoji picker but for images).
      - [x] **Soundboards** — per-channel uploadable audio clips, tap to play
            (`audioplayers`), shared channel-wide. Voice panel has a soundboard
            button; plays for all voice participants via control frame.
      - [x] **Media-blob subsystem — foundation** — content-addressed `BlobStore`
            + want/give-blob transfer over the data channel, fetched on demand and
            content-address-verified. *Unit-tested.* Remaining (needs live verify +
            deps): app-side Hive blob store, upload (`file_picker`), inline render,
            soundboard playback (`audioplayers`).
- [x] **Messaging UX** (all shipped): **replies** (quote-and-respond),
      **emoji reactions** (chips on the target message), **pinned messages**
      (local, per-channel), **in-channel search**, per-channel **mute** toggle,
      and **read receipts** (WhatsApp-style ticks via `ReadWatermarkControl`
      gossiped over the mesh, disable-able per DM). Plus animation polish
      (per-channel accent colour, typing dots, cascade-in, scroll-to-bottom FAB).
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
- [ ] Optional federation between communities.
- [ ] Spam resistance (proof-of-work / invite gating / web-of-trust).
- [ ] Plugins (WASM) and local bots.

---

## 5. Open decisions (need a call before they bite)

1. **Multi-device identity flow.** How does your phone + laptop share one
   identity? (Root key certifies per-device subkeys.) Shapes the whole crypto
   layer — decide before Phase 3.
2. **Spam resistance.** Keypairs are free to mint. Proof-of-work? Invite-only
   communities? Web-of-trust? Decide before any public discovery exists.
3. **Permission conflicts.** Two admins act contradictorily while offline — who
   wins? Leaning: one designated owner key whose actions always take precedence.
4. **Bundle / application IDs.** ~~Scaffolding left the default `com.example.*`;
   set real ones (e.g. `com.spamalot22.hearth`) before any app-store release.~~
   Done — renamed to `com.hearth.app` (2026-06-27).
5. **Channel ownership + kick (maybe).** The creator's pubkey rides in the invite
   already; a "kick" could be a signed message from the creator that honest peers
   enforce (drop the target from their mesh, refuse to gossip to them). The kicked
   user still holds the old key (can read history), so a key rotation + re-invite
   for remaining members is needed for true eviction. Alternatively, rotate the
   channel key on kick and distribute the new key to everyone except the kicked
   user. Ties into #3 (permission conflicts). Not urgent — small trusted groups
   don't need it yet.

---

## 6. Decisions log

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
  port-forward, and the **tailnet node is the container**, not the NAS (it shares a
  netns only with the relay, so nothing else on the host is exposed). Hard-won gotchas,
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
- **2026-06-27** — **Cross-channel contacts-online discovery (Option B).**
  `ContactsOnlineControl` broadcasts all currently-connected peers (across all
  channels) to every connection when a new peer joins anywhere. Receivers check
  if any listed pubkey is someone they want to reach and attempt connections.
  Metadata trade-off accepted: a peer learns who you're connected to, but not
  which channels or message content — similar to the relay's existing visibility.
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
- **2026-06-27** — **Relay tunnel for symmetric-NAT pairs.** When ICE fails 3
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
  endpoints.** GET `/signal`, POST `/signal`, POST `/tunnel`, GET `/tunnel` all
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
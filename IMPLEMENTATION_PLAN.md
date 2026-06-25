# Hearth — Implementation Plan

> **Hearth** — a gamer-focused, open-source, decentralised Discord alternative.
> Local-first, peer-to-peer by default, with an **optional** coordination
> backend that improves reliability but is never required to function.

_Status: living document. Last updated: 2026-06-21._

---

## Product scope (target feature set)

- **Channels are the core primitive** — a channel is a shared, replicated message
  DAG. **Group channels** (many members) and **direct messages** (a private
  2-person channel) are the *same* primitive; only membership scope + encryption
  differ.
- **Text now; voice next** — text chat works today. Real-time **voice, video, and
  screen-share** come via WebRTC (Phase 3), with coturn for NAT traversal.
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
| TURN relay (NAT fallback) | **Deferred** — managed (Cloudflare/Metered) or coturn on an isolated VPS when needed; never home-hosted | ✅ decided |
| E2E encryption (default) | DMs **sealed box** (X25519, next); groups need membership → **MLS (RFC 9420)** for forward secrecy / rotation (likely Rust `openmls`) | 🔜 next |
| Heavy P2P (DHT, hole-punching) | **libp2p** — deferred; Rust via `flutter_rust_bridge` if/when needed | ⏳ deferred |

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
- The only places Dart is genuinely weak (libp2p, MLS) are Phase 3+ concerns.
- **Mitigation:** keep `core/` free of UI and Flutter imports so it can become a
  Rust module later with the UI untouched.

### The escape hatch (when we'd reach for Rust)
- We need a real DHT / NAT hole-punching beyond WebRTC's reach → libp2p (Rust).
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
   TURN  (deferred · managed or isolated VPS · NEVER home-hosted)
        relays media for the ~15% symmetric-NAT↔symmetric-NAT pairs
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
- **Default deploy = your Firebase project (free tier, $0).** Self-hosters deploy
  the *same* backend to their own Firebase project, or run the Hono app as a
  plain container off-Firebase — no separate server codebase.
- **The rendezvous endpoint is pluggable in the client** (point at any backend
  URL). That is what keeps it decentralised: your Firebase project is just the
  default bootstrap node, like a DHT seed — replaceable, not authoritative.
- **Cold-start caveat:** two peers who've *never* connected need a rendezvous
  point (a backend, LAN/mDNS, or a DHT) for the first handshake. Fully serverless
  first contact is the Phase 3 DHT/libp2p case.
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
4. **TURN** — symmetric-NAT↔symmetric-NAT pairs can't go direct at all; their media
   must be relayed. Deferred (a minority); managed/VPS-hosted when needed, **never
   self-hosted at home** (see Deployment).

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
no plaintext, verifies signatures, and is rarely hit. (A **DHT** remains the
eventual fully-serverless bootstrap — see roadmap — but the contact graph reaches
the same place via people you already know.)

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
- **TURN is NOT in this stack and NOT on the home network** — it can't be tunnelled
  (wide UDP relay range) and a home-exposed relay is an abuse/exposure risk. Defer
  it; when needed use **managed TURN** (Cloudflare/Metered — pay-per-use, tiny since
  only stuck pairs) or coturn on an **isolated VPS**, always auth'd with
  time-limited creds the relay mints, never open.

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
- [ ] `backend`: swap in-memory store → Firestore; wrap as a Cloud Function on the Emulator.
- [ ] `app`: send/receive UI over the relay (needs the backend).

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
- [ ] **Self-hosted relay deploy** (the cold-start bootstrap, opt-in, not required
      once peers are connected): dockerise the in-memory Hono relay (pubkey
      signalling mailbox + media proxies) as a **Compose stack**, exposed via a
      **Cloudflare Tunnel** (no port-forward, no home-IP exposure); ship via
      **GitHub Actions on a version tag → GHCR**, box pulls. Client points at any
      relay URL. (See "Rendezvous & connectivity" + "Deployment".)
- [x] **Stop polling once connected** — adaptive signalling: fast poll (700ms/5s)
      only while a handshake's in flight or peerless, idle (15s/30s) once settled.
- [ ] **Server-minimal connectivity (rest)** — cached-candidate direct reconnect +
      mutual-contact hole-punch (peer-exchange) + P2P presence/gossip, so the server
      is touched *only* on cold start.
- [x] **Invite carries the inviter's pubkey**; accepting mandatorily adds the
      inviter (keeps the invite-tree contact graph connected → no islands). Still to
      wire: the mesh actually *using* the inviter as the first cold-start target.
- [ ] TURN — **deferred**; managed (Cloudflare/Metered) or isolated-VPS coturn when
      symmetric-NAT pairs actually need it, never home-hosted.

### Phase 3 — Groups, voice, and the hard stuff
- [ ] Group = replicated log + membership-as-messages (capability model).
- [ ] Permission-conflict resolution rule (owner-key-wins, decide in §5).
- [ ] Voice/video over WebRTC media (signaled over the existing layer).
- [ ] **Group encryption** — encrypt each message to the channel's member set
      (sealed-box per member); requires the membership above. **MLS** (Rust
      `openmls`) is the upgrade for forward secrecy + efficient key rotation. (DMs
      are already sealed-box-encrypted from Phase 2.)
- [ ] Multi-device identity, two tiers: **(a) export/import** the root seed
      (recovery phrase / QR) — the simple "same key on another device" path, and
      also the *only* identity **backup/recovery** mechanism; **(b) per-device
      subkeys** certified by a root key — adds per-device revocation. Until this
      ships there is **no identity backup**: clearing storage loses the key.
- [ ] **Address cache + peer-exchange** — clients cache contacts'/members'
      last-known WebRTC candidates and gossip current ones over the mesh, so
      reconnects mostly skip the server (server = cold-start fallback only).
- [ ] **Pluggable bootstrap relay** — the cold-start relay URL rides in the invite
      and is swappable; a community self-hosts its own. (Multi-bootstrap failover +
      a learned-relay list are a later nicety, not core now the contact graph
      carries connectivity. See "Rendezvous & connectivity".)
- [ ] **DHT (libp2p)** — relay-independent cold-start bootstrap (keyed by pubkey /
      channel id); the "no server at all" endgame that subsumes the cold-start
      mailbox. Bigger; likely Rust via `flutter_rust_bridge`.

### Phase 4 — Polish / ecosystem
- [ ] Notifications, per platform:
      - **Android → FCM** (free, no Apple account). A Cloud Function sends via
        `firebase-admin` (same project); device tokens in Firestore (TTL/refresh).
      - **Windows → no push service.** App runs resident (tray, launch-on-start)
        and holds its connection, so messages arrive live; surface them with
        local OS notifications (`flutter_local_notifications`).
      - **iOS / web → later** (iOS reintroduces Apple $99/yr + APNs key; FCM can
        cover both when we get there).
      - Self-hoster option later: **UnifiedPush** for de-Googled Android.
- [ ] **Rich content** — typed message payloads via a **content envelope**
      (`{t: text|gif|sticker|sound, …}` inside the payload; composes under
      encryption, since we encrypt the envelope):
      - [x] **Emoji** — quick picker added (Unicode text already worked).
      - [x] **GIFs (URL)** — paste-a-URL renders inline; **Giphy/Tenor search** still
            needs a provider **API key** (credentials — ask the user for it).
      - [ ] **Stickers** — custom sticker packs as content-addressed media blobs.
      - [ ] **Soundboards** — per-channel uploadable audio clips, tap to play
            (`audioplayers`), shared channel-wide.
      - [x] **Media-blob subsystem — foundation** — content-addressed `BlobStore`
            + want/give-blob transfer over the data channel, fetched on demand and
            content-address-verified. *Unit-tested.* Remaining (needs live verify +
            deps): app-side Hive blob store, upload (`file_picker`), inline render,
            soundboard playback (`audioplayers`).
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
4. **Bundle / application IDs.** Scaffolding left the default `com.example.*`;
   set real ones (e.g. `com.spamalot22.hearth`) before any app-store release.

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
  `main`; repo-local identity `spamalot22` + GitHub noreply (global work email
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
  registry is work's and must not be used here).
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
  device's storage loses that key irrecoverably.
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

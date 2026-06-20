# Hearth — Implementation Plan

> **Hearth** — a gamer-focused, open-source, decentralised Discord alternative.
> Local-first, peer-to-peer by default, with an **optional** coordination
> backend that improves reliability but is never required to function.

_Status: living document. Last updated: 2026-06-20._

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
| Backend (rendezvous + push) | **Firebase**: Cloud Functions (**TypeScript**) + **Firestore** + **FCM**, free tier | ✅ decided |
| Backend framework / tooling | **Hono** in an HTTP Cloud Function · **firebase-admin** · **Firebase CLI** + Emulator Suite | ✅ decided |
| TURN relay (NAT fallback) | **coturn**, self-hosted **Docker** — optional | ✅ decided |
| Group E2E encryption | **MLS (RFC 9420)** — deferred; likely Rust (`openmls`) when needed | ⏳ deferred |
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
   backend/  (TypeScript · Firebase Cloud Functions + Firestore + FCM)
        default:   your Firebase project (free tier)
        self-host: run the same Hono app as a container, off-Firebase
        discovery   pubkey → last-seen presence
        signaling   relays WebRTC offer / answer / ICE
        relay       offline encrypted message hold
        push        FCM sender (firebase-admin)
        ── HTTP contract (pluggable) · Firestore TTL · stores NO chat history ──
        │
   coturn  (Docker · self-hosted · OPTIONAL)
        TURN relay for the ~15% behind symmetric NAT — not serverless-able
```

### Repo layout (polyglot monorepo)
```
/core      Dart package, no Flutter — protocol, identity, DAG (shared by app)
/app       Flutter app (depends on core)        ── Dart pub workspace ──┘
/backend   TypeScript — Hono app deployed as a Firebase Cloud Function (HTTP)
           firebase.json + .firebaserc at repo root · Firestore rules/indexes
           (coturn lives as a docker-compose + turnserver.conf, added Phase 3)
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

### Firebase backend — staying at $0
Everything lives in **one Firebase project** (Cloud Functions + Firestore + FCM).
What keeps it free for tens of users:
1. **Firestore free tier is per-day** (~20K writes/day · 50K reads/day · 1 GiB ·
   10 GiB egress/mo). This is the **binding limit**, eaten mainly by presence
   heartbeats — so keep announces low-frequency and gossip presence peer-to-peer
   once connected. Use **Firestore TTL policies** to auto-expire signalling,
   presence and relay docs for free.
2. **Cloud Functions need the Blaze plan (card on file)** but are free within
   limits (2M invocations/mo · 400K GB-s). Set a **budget alert** → effectively
   $0 at this scale. (You needed a card for AWS too.)
3. **FCM is free and unlimited.**

- **Dev needs no card:** the **Firebase Emulator Suite** runs Functions +
  Firestore locally for free; Blaze is only required to *deploy* Cloud Functions
  to the cloud (Phase 2 onward).
- **Signalling can be push-based for free** via Firestore real-time listeners —
  no WebSocket infra, no polling. We still front it with an **HTTP contract** so
  the client stays provider-agnostic and a self-hoster can reimplement off-Firebase.
- **Verify current Firebase free-tier numbers in the console** — they change.

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
- [ ] `backend`: Hono `POST /messages` + `GET /poll` relay as a Cloud Function;
      Firestore storage; run locally via the **Firebase Emulator Suite** (no card).
- [ ] `app`: send/receive UI over the relay (needs the backend).

### Phase 2 — Peer-to-peer transport
_Goal: backend becomes signalling-only; messages flow peer↔peer._
- [ ] `core`: `WebRtcTransport` (data channels) via `flutter_webrtc`.
- [ ] `backend`: signalling endpoints (offer/answer/ICE) + presence in Firestore;
      public STUN for address discovery.
- [ ] Deploy via **Firebase CLI**: Cloud Function (HTTP) + Firestore rules /
      indexes / TTL; client points at the Function URL. (First cloud deploy needs Blaze.)
- [ ] Gossip sync: exchange heads, walk `prev`, send the diff.
- [ ] coturn (Docker) — optional TURN fallback for symmetric-NAT peers.

### Phase 3 — Groups, voice, and the hard stuff
- [ ] Group = replicated log + membership-as-messages (capability model).
- [ ] Permission-conflict resolution rule (owner-key-wins, decide in §5).
- [ ] Voice/video over WebRTC media (signaled over the existing layer).
- [ ] **MLS** for group key rotation (Rust `openmls` candidate).
- [ ] Multi-device identity (subkeys certified by a root key).

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

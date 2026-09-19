# Nearby Text Messaging

## Scope and current status

The target is opt-in Android/iPhone text messaging over interchangeable local
transports, including encounters with untrusted forwarding devices. Windows and
voice/media are outside this feature's scope. Nearby links do not use the relay,
TURN, or an Internet account. Existing WAN messaging remains unchanged.

The implementation includes Android and iPhone adapters, but is **not yet
release-verified**. Native builds and physical radio behaviour must be checked
before claiming it works on particular phones. Native verification runs in
GitHub CI; physical radio interoperability is not established by compilation.

Implemented in this working tree:

- Pure-Dart signed, expiring envelopes and a bounded persistent courier queue.
- Transport-independent inventory/request/exchange, with restart-safe custody,
  deduplication, backpressure and per-link traffic limits.
- Android native Wi-Fi Aware publish/subscribe and framed NAN data paths on
  capable Android 10+ phones. Older or unsupported phones use Bluetooth.
- Cross-platform Bluetooth GATT discovery and encrypted text exchange using
  `bluetooth_low_energy`, with MTU-aware framing, ordered writes/indications,
  deadlines, quotas and bounded reassembly.
- iOS 26 Wi-Fi Aware on supported hardware, with explicit DeviceDiscoveryUI
  pairing. Older/unpaired phones use Bluetooth. No Multipeer/AWDL or Wi-Fi Direct
  adapter is used. Neither Wi-Fi association nor a discovered beacon is a link.
- A separate Android API 37.2+ paired subscriber for iPhone publishers, using
  framework-managed PIN pairing, explicit peer selection and verified paired
  reconnection. This cross-platform path still requires native and device tests.
- A multipath adapter which keeps working fallbacks and selects usable Wi-Fi
  Aware ahead of Bluetooth. Noise XX encrypts ALL neighbour application frames,
  including inventories and outer envelope metadata, before either radio sends
  them. Proof of possession of one per-activation static key coalesces radios;
  no account identity or contact list is broadcast.
- Mobile settings, opt-in automatic activation, a separate Android connected
  device foreground service, an ongoing notification and a durable Stop action.
- Text/edit/delete publication and ingestion through existing encryption,
  signature verification, block lists, device revocation and channel policies.
- Accepted WAN text from shared channels can enter the nearby queue; nearby
  arrivals enter the existing WAN gossip engine. Media/voice/administrative
  messages are excluded. Bridging never extends the original message's 24-hour
  nearby lifetime, and forwarded WAN text cannot use the owner's reserved quota.
- An independent Settings switch and popup proximity scanner, described below.

Release gates:

- GitHub Android/iPhone compilation and Flutter test verification. CI now has
  an unsigned iPhone compile job; no local native builds are permitted.
- Physical Android/Android, Android/iPhone and iPhone/iPhone tests, including
  radio loss, screen lock and a third store-and-forward carrier.

Scope limits: existing contacts with known device bundles and already-shared
group invites are supported. Contact lookup/first-contact device-key exchange
is not replaced by anonymous proximity discovery. Authenticated LAN discovery
remains the separate README TODO; no isolated LAN is assumed to be usable.
UWB/cellular device-to-device adapters are not implemented. Nearby messaging
does not make those protocols available on unsupported hardware.

### Compatibility boundary

Wi-Fi Aware is preferred only for an established, cryptographically ready link.
BLE runs concurrently so pairing, unavailable Aware resources or unsupported
hardware cannot block delivery. The current matrix is:

| Devices | Primary candidate | Fallback |
| --- | --- | --- |
| Android / Android | Android NAN data path, Android 10+ and capable hardware | Shared GATT |
| iPhone / iPhone | Paired iOS 26 Wi-Fi Aware and capable hardware | Shared GATT |
| Android / iPhone | Paired Aware: Android API 37.2+ with compatible firmware initiates to iOS 26+ | Shared GATT |

**Android/iPhone Wi-Fi Aware is implemented as an unverified, capability-gated
path, not a claim of universal device compatibility.** Apple requires paired NAN
and protected group/management frames. Ordinary Android open NDPs do not meet
that profile. The additional Android subscriber requires API 37.2, Aware pairing,
PASN-128 and framework-offloaded PIN keypad support. The framework owns the PIN,
pairing keys and secured data-path setup; Hearth does not invent or export a PMK.
Firmware must implement Apple's remaining NAN requirements. The presence of
FEATURE_WIFI_AWARE alone is not sufficient. Physical testing is a release gate.

For first pairing, enable nearby mode on both phones. On the iPhone select
**Pair Wi-Fi Aware device**, then **Allow pairing**. On Android select
**Pair Wi-Fi Aware device**, choose the nearby device and complete the system PIN
prompt using the iPhone's displayed PIN. Close the iPhone pairing sheet to resume
normal service publication. The Android selector uses ephemeral local numbers,
not authenticated account names. Pairing does not add a Hearth contact.
There is no Android publisher/iPhone-initiated pairing UI in this path: Android
initiates, but the resulting TCP link carries messages in both directions.

The Android subscriber uses `_hearth-text._tcp` with no legacy discovery
bootstrap. Unknown advertisements never trigger automatic pairing. Subsequent
connections require successful framework pairing verification, and sockets use
only the Aware network's IPv6 address and advertised TCP port. Discovery, retries
and explicit selections are bounded. No paired-path failure downgrades that
connection to an open NDP; the independent encrypted GATT fallback remains.
Older Android phones retain GATT cross-platform communication and the legacy
Android-to-Android Aware adapter.

iPhone pairing is an explicit Settings action while nearby mode is active, never
an automatic system popup. Normal Aware discovery pauses during pairing to avoid
publishing the service twice; BLE continues. Dismissal resumes normal discovery,
while disabling nearby mode dismisses pairing without restarting its radios.
The system pairing sheet offers Allow pairing and
Find device roles. Pairing authorizes a local radio connection, not a Hearth
contact. Xcode 26 is required to compile the adapter; CI selects Xcode 26.3.
Distribution provisioning profiles must include the Wi-Fi Aware entitlement.
Android's API-specific driver is instantiated only on Android 10+; older Android
phones retain the common BLE/service plugin without loading Wi-Fi Aware types.
The legacy Android adapter publishes `hearth-text.tcp`, avoiding underscores
rejected on Android 10/11. It remains separate from the paired subscriber.
Compile SDK 37.2 is required; the minimum and target SDK values are unchanged.

## Connectivity and battery policy

Wi-Fi association is **not** Internet connectivity. Intranet-only access points,
captive portals and client-isolated Wi-Fi must not suppress nearby operation.
Android uses `NET_CAPABILITY_VALIDATED` for Internet status, independently of
Hearth relay availability. A failed Hearth relay does not mark the Internet down.
OS validation is an observation, not proof that every Internet destination works.
On iPhone, NWPath is also not treated as Internet proof. Automatic mode makes a
bounded HTTPS HEAD request to `https://connectivitycheck.gstatic.com/generate_204`
at most every 30 seconds, expecting exactly HTTP 204 and refusing redirects.
Requests have no identifiers, cookies, messages or contact data. They expose the
device's network IP to that endpoint; no probe runs with automatic mode disabled.
Blocking the probe can cause a conservative false-offline result. Android uses
the OS result and makes no extra Hearth Internet probe.

The master setting defaults to off. With automatic mode off, opting in operates
nearby messaging even while the Internet is available. With automatic mode on,
an offline observation must persist for ten seconds before activation, and an
online observation for thirty seconds before deactivation. Polling every fifteen
seconds adds a bounded foreground delay; OS suspension can add further delay.
Unknown observations do not tear down an already active offline link. The
Android notification's Stop action disables both settings and remains
latched natively until an explicit settings action re-arms it.

Only an explicit settings action requests runtime permissions. Wi-Fi Aware
discovery also needs Android Location services enabled. Bluetooth scanning and
relative proximity request location permission conservatively; Hearth does not
read GPS coordinates. Wi-Fi, Bluetooth and notification permissions/availability
are checked before starting. Discovery runs in bounded
scan windows. The service is not a promise of survival after force-stop, process
death, or the OS suspending the app. Swiping away the task stops this implementation;
normal minimisation leaves the service eligible to continue.

Automatic activation is best effort: Android may refuse a foreground-service
start while Hearth is already backgrounded. Resuming the app retries. iOS has no
equivalent permanent foreground service or guaranteed persistent notification.
Bluetooth central/peripheral background modes are declared, but discovery and
execution are throttled by iOS. Aware connections remain eligible while the app
has execution time, not an unlimited background lease. Background iPhone advertisements may be invisible to
Android; the iPhone can instead discover an advertising Android. Process death,
force-quit and suspension can interrupt delivery. Queued ciphertext survives
restart; autonomous radio restoration after process termination is not promised.

The route policy prefers **usable** Wi-Fi over Bluetooth. An associated but
isolated LAN is not a usable route. Working fallbacks remain attached until a
replacement works. Protocol names are not range measurements; no fixed range is
promised inside a steel ship.

## Proximity scanner

Settings contains a separate **Proximity scanner** switch and **Open scanner**
button. The radar is a separate, scrollable dialog, not a replacement Settings
screen. The switch is independent of text couriering and forces local radio
activity even when automatic messaging is on standby. Closing the popup does
not disable its switch; switching it off clears observations and stops scanner
sampling. Radios stop unless enabled nearby messaging still needs them.
Scanner-only mode does not store or forward messages.

Only directly observed Hearth-service devices appear. Third-party advertisements
can spoof that service, so beacons are labelled unverified and do not create
contacts. Link establishment also does not authenticate a contact's identity.
Labels are ephemeral local device numbers, not publicly broadcast handles.
Indirect mesh recipients cannot be ranged from a forwarded packet.

Bluetooth RSSI is sampled while connected and during discovery, smoothed with
an exponential average, and expires after 45 seconds. Three qualitative bands
(close, moderate, distant/obstructed) avoid invented metre precision. Steel,
people, antenna orientation and transmit power substantially affect the result.
There is no bearing sensor: angular dot slots are layout only, explicitly
labelled as unverified direction. Wi-Fi-only peers appear in the device list as
range unknown, never at an invented radius. Measurements are bounded, in-memory
only, never persisted or forwarded. Reduced-motion preferences stop the sweep.

## Trust and wire protocol

The outer `NearbyPacket` contains a protocol version, opaque route hash, creation
and expiry times, encrypted body, forwarding issuer public key, signature and
content hash. The body encrypts the **entire existing signed Hearth message**
using its channel cipher, including its original author and channel metadata.
No channel keys or contact lists are sent to carriers. Participating carriers see
the stable outer route hash and issuer key after decrypting their neighbour link,
which permits traffic correlation; this is not an anonymity
protocol. Guessable channel identifiers also permit guessing their route hashes.

An outer signature provides integrity, not channel membership or recipient
identity. At the destination, the inner signature and certificate are verified,
the payload must decrypt to text/edit/delete, and normal channel acceptance
policies run again. Carriers cannot verify whether opaque ciphertext is actually
text, so hard resource limits are essential. A valid outer signature alone must
never add contacts, update keys, change memberships or mark a message delivered.

Expiry is signed and cannot be extended by a forwarding hop. Packets live at
most 24 hours, carry at most 20 KiB of ciphertext, and use at most 32 KiB on the
packet wire. Oversized messages remain eligible for normal Hearth delivery;
the nearby settings status reports that they could not enter the nearby queue.
The queue holds at most 256 envelopes / 4 MiB of encoded packet bytes, reserves
one quarter of its count and byte budgets for local sends, and caps foreign
traffic at 32 envelopes per issuer. Limits do not prevent Sybil attacks; delivery
remains best effort under congestion or malicious participation.

The neighbour protocol is fixed to Noise_XX_25519_ChaChaPoly_SHA256. It uses the
existing cryptography package's X25519 and ChaCha20-Poly1305 primitives, SHA-256
and HMAC-SHA-256, and the Noise revision 34 state machine. There is no cipher
negotiation or plaintext compatibility mode. Published noise-c reference vectors
check all three handshake messages and bidirectional transport byte-for-byte.
This narrowly scoped implementation is not an independently audited Noise library;
vector agreement and tests are not a substitute for security review.

Each raw link exchanges a 34-byte public bootstrap (72, version 2, random 32-byte
nonce) to choose initiator order. The sorted bootstraps and Hearth protocol domain
are bound into the Noise prologue. Tag 3 carries a Noise handshake; tag 4 carries
authenticated ciphertext. No application payload is allowed during the handshake.
An encrypted one-byte confirmation must arrive before the courier gets a link.
Each link uses fresh ephemeral keys, separate sending/receiving keys and implicit
ordered nonces. Alteration, replay, reordering, bad keys, timeout or malformed data
closes the link. Failed writes also discard the link rather than reuse a nonce.

The shared static key is regenerated at each nearby activation, encrypted in the
XX exchange and never advertised. It binds simultaneous radios to a key-holder,
NOT to a known contact. Unverified strangers cannot provide authenticated account
identity: an active intermediary can establish two neighbour sessions and observe
outer courier metadata. Message E2EE and recipient-side signature/membership
checks still protect contents. Radio service advertisements, packet sizes/timing,
bootstrap nonces and handshake ephemeral keys remain observable. This is not a
promise to hide device presence or all radio-layer management traffic.

Inside the encrypted transport, courier frames use discriminator 0 for bounded
JSON inventory/request (up to 32 hashes), or 1 for an encoded packet. There are no
recipient delivery ACKs in this protocol. Custody never suppresses the existing
WAN/relay fallback. Inventories rotate so larger queues are eventually serviced.
Aware sockets prepend a four-byte big-endian frame length; adapters must
reject lengths over 32786 bytes before allocation (32769 courier bytes plus tag
and 16-byte authentication overhead). The native adapter bounds
connections, input traffic, and queued writes as well as the Dart limits.
Bluetooth uses a six-byte big-endian header (16-bit sequence, offset, total),
with fragments no larger than the negotiated write length or 512 bytes. Invalid
offsets, interleaved frames, oversized data and expired assemblies close the
link. The maximum reassembly is 32786 bytes per link. BLE links that are not
selected can expire and be rediscovered; Wi-Fi failure can use an established
BLE fallback immediately, or wait for Bluetooth discovery if it has expired.

Android Aware requests are limited to four data paths, retried on bounded timers,
and explicitly released on loss/stop. The fixed TCP listener admits only peers
whose remote IPv6 and local interface address match an active Aware request; it
is not a LAN service. iOS uses the paired Aware Network-framework descriptors.
Carrying stored packets between encounters is supported by the courier core;
mobility and reconnection require physical testing. Do not present an anonymous
carrier link as a contact's authenticated online/voice presence.

## Verification

The existing Network diagnostics buffer now records capability changes, native
Aware link establishment, encrypted-link completion/rejection/timeouts and
selected-transport counts. It includes no peer handles, keys, channel identifiers,
addresses, inventories, or message contents. The existing 300-entry memory-only
limit applies. A reported pairing capability is hardware support, not proof of
Android/iPhone interoperability.

Pure-Dart tests cover captive/intranet activation policy, permission gating,
actual encrypted multipath preference/failover, Noise reference vectors, replay,
tampered ciphertext, prologue mismatch, low-order keys, malformed handshakes, fragment MTUs and
reassembly attacks, stale RSSI, tampering, expiry, quotas, durable-write failures,
deduplication, accepted-message bridging boundaries, and simulated encrypted
transfer via a restarted intermediary. Flutter tests cover settings/service
coordination, scanner independence, notification Stop, radio restart, WAN
bridging, text-only publication and popup layout; run them **only in CI**.

Before enabling this in a release, use GitHub Actions for Android/iPhone compilation
and Flutter tests. Do not run native builds locally. Then test two real Android
devices with cellular data disabled, both disconnected from Wi-Fi and associated
with an isolated/intranet-only access point. Exercise discovery confirmation,
both publish/subscribe roles, lost peers, permissions, Wi-Fi off/on, Location off/on,
notification Stop, minimisation, screen lock, app restart and queue exhaustion.
Test a third carrier with the sender offline before the recipient appears.
Repeat across Android/iPhone over BLE, then the gated paired Aware path with
compatible API 37.2 firmware. Test PIN rejection/cancellation, pairing discovery
with several devices, stale selections, stopping during the system prompt,
closing the iPhone sheet, remembered-pair verification and revoked pairings.
Verify both directions over the resulting TCP link. Repeat iPhone/iPhone with
and without Aware pairing. Exercise both BLE roles, GATT
MTUs of 23/185/517, simultaneous Wi-Fi/Bluetooth links, Wi-Fi failure while BLE
is connected, denied Bluetooth/local-network permission, and iOS background
discovery limitations. Verify the scanner at narrow widths and large text,
reduced motion, stale readings, popup close/reopen and notification Stop.

References:

- [Android Wi-Fi Aware](https://developer.android.com/develop/connectivity/wifi/wifi-aware)
- [Android framework-managed pairing](https://developer.android.com/reference/android/net/wifi/aware/SubscribeConfig.Builder#setFrameworkOffloadedPairingEnabled(boolean))
- [Apple peer interoperability requirements, chapter 56](https://developer.apple.com/accessories/Accessory-Design-Guidelines.pdf)
- [Android foreground-service restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)
- [Apple Bluetooth background execution](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
- [Apple Wi-Fi Aware](https://developer.apple.com/documentation/wifiaware)
- [Apple pairing requirement](https://developer.apple.com/forums/thread/791628)
- [Noise specification](https://noiseprotocol.org/noise_rev34.pdf)
- [noise-c reference vectors](https://github.com/rweather/noise-c/blob/master/tests/vector/noise-c-basic.txt)
- [Bluetooth adapter library](https://github.com/yanshouwang/bluetooth_low_energy)

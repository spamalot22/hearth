# Cutting a release

A release is one **version tag**. Pushing it runs two GitHub Actions workflows:

- **`deploy-relay`** → builds the relay image and publishes
  `ghcr.io/spamalot22/hearth-relay:<tag>` (+ `latest`).
- **`release-app`** → builds the client (Android APK, Windows zip, web zip) and
  attaches them to a **GitHub Release**.

## How

```sh
git tag 0.1.6
git push origin 0.1.6      # the PUSH is what triggers it — `git tag` alone does nothing
```

Bare (`0.1.6`) or v-prefixed (`v0.1.6`) both match. Watch it under the repo's
**Actions** tab. (The GitHub web UI — *Releases → Draft a new release → publish* —
also works; publishing creates and pushes the tag.)

## What you get

- **Relay image** on GHCR. Deploy it on the host with `docker compose pull &&
  docker compose up -d` — see [backend/DEPLOY.md](backend/DEPLOY.md).
- **Client builds** on the release page: `hearth-android.apk` (sideload),
  `hearth-windows.zip`, `hearth-web.zip`. The APK is debug-signed — fine to
  sideload; add a release signing config before targeting the Play Store.

## Auto-update (optional — dormant until armed)

Clients can check the relay for a signed release and install it in-app (Android
one-tap; Windows self-replace + relaunch). It's **off** until a signing key is
baked in — without `RELEASE_PUBLIC_KEY` the client never checks, blocks, or
updates.

To arm it:

1. **Generate a release keypair** (once):
   ```sh
   cd backend && pnpm exec tsx src/sign-release.ts keygen
   ```
   Keep `privateKey` secret; `publicKey` is safe to expose.
2. **GitHub → Settings → Secrets and variables → Actions:**
   - Variable `RELEASE_PUBLIC_KEY` = the public key (baked into every build).
   - Variable `RELAY_URL` = the relay's public URL (e.g. the Tailscale Funnel one).
   - Secret `RELEASE_PRIVATE_KEY` = the private key (CI signs the manifest with it).
   - Secret `RELEASE_SECRET` = any random string (authorises `POST /version`).
3. **On the relay** (`backend/.env`): the same `RELEASE_SECRET`, the public key
   as `RELEASE_PUBLIC_KEY` (optional but recommended, so the relay rejects forged
   manifests before storing them), `GITHUB_REPO=spamalot22/hearth`, and
   `GITHUB_TOKEN` = a **read-only** GitHub token (fine-grained, Contents: read).
   The relay proxies the private release assets to clients with this token — it
   never leaves the relay.

Once armed, each tag builds key-baked clients, signs a manifest of the assets, and
POSTs it to the relay; clients on an older version then see an **Install** button.
A released build that can't reach the relay blocks with "connect to a relay" — the
deliberate private-phase kill-switch.

### Android updates need a *stable* signing key

CI builds are **debug-signed with an ephemeral key** (regenerated each run), so an
auto-update APK won't install over a previous one — Android rejects it
(*signatures do not match*). For Android auto-update to work, add a fixed keystore
(committed, or a CI secret) and a `signingConfig` in
`app/android/app/build.gradle.kts` so every build shares one key. Until then an
Android update is uninstall-then-reinstall. Windows + web are unaffected.

## Notes

- The `release-app` job ships **whatever platforms build** — one OS failing won't
  block the others (`release:` runs `if: always()`).
- Client builds pin **Flutter 3.44.2** (`FLUTTER_VERSION` in `release-app.yml`);
  change it there to move the toolchain.
- **Android is CI-only on some dev machines** — a corporate TLS proxy breaks local
  Gradle downloads, so let CI build/verify it. (The fixes for the modern Android
  toolchain — compileSdk 36 across all plugin modules, etc. — are already committed.)
- The user-facing app version (`app/pubspec.yaml` `version:`) is separate from the
  git tag; bump it there if you want the APK/exe to report a new version.

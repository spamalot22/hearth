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

Bare (`0.1.6`) or v-prefixed (`v0.1.6`) tags both work. Push the tag and watch the
repo's **Actions** tab; do not pre-publish a GitHub Release because the workflow
must attach and sign the complete asset set first.

## What you get

- **Relay image** on GHCR. Deploy it on the host with `docker compose pull &&
  docker compose up -d` — see [backend/DEPLOY.md](backend/DEPLOY.md).
- **Client builds** on the release page: `hearth-android.apk` (sideload),
  `hearth-windows.zip`, `hearth-web.zip`, plus the signed `manifest.json` used by
  auto-update clients.

## Auto-update signing

Clients fetch `manifest.json` directly from the latest public GitHub Release and
install in-app (Android one-tap; Windows self-replace + relaunch). They verify its
Ed25519 signature and each downloaded asset's SHA-256 hash before installation.
The relay is not involved and can be offline during a release.

Configure these once:

1. **Generate a release keypair** (once):
   ```sh
   cd backend && pnpm exec tsx src/sign-release.ts keygen
   ```
   Keep `privateKey` secret; `publicKey` is safe to expose.
2. **GitHub → Settings → Secrets and variables → Actions:**
   - Variable `RELEASE_PUBLIC_KEY` = the public key (baked into every build).
   - Secret `RELEASE_PRIVATE_KEY` = the private key (CI signs the manifest with it).
   - Secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
     `ANDROID_KEY_PASSWORD`, and `ANDROID_KEY_ALIAS` = the stable Android release
     signing identity.
   - Variable `RELAY_URL` = the app's default messaging relay URL. This is baked
     into clients but is unrelated to update delivery.

Each tag builds key-baked clients, signs a manifest of the assets, and publishes
everything atomically in one GitHub Release. Missing signing configuration fails
the workflow before a release is published.

### Android updates need a *stable* signing key

Every release APK must use the same stable keystore. CI and Gradle both fail closed
when it is missing; Android will reject an update signed by a different key.

## Notes

- `release-app` publishes only after Android, Windows, and web all build.
- Client builds pin **Flutter 3.44.2** (`FLUTTER_VERSION` in `release-app.yml`);
  change it there to move the toolchain.
- **Android is CI-only on some dev machines** — a corporate TLS proxy breaks local
  Gradle downloads, so let CI build/verify it. (The fixes for the modern Android
  toolchain — compileSdk 36 across all plugin modules, etc. — are already committed.)
- Release builds derive their displayed version and Android version code from the
  git tag; `app/pubspec.yaml` is only the local-development fallback.

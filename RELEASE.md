# Cutting a release

A release is one **version tag**. Pushing it runs **`release-app`**, which:

- Builds the client (Android APK, Windows installer, web zip).
- Builds and publishes `ghcr.io/spamalot22/hearth-relay:<tag>` (+ `latest`).
- Signs the update manifest and publishes the complete **GitHub Release** only
  after the app builds and relay image have succeeded.

**`deploy-relay`** is a manually dispatched relay-only repair workflow.

## How

Commit and push only with the user's explicit approval. Wait for all `ci` jobs
on that commit to succeed before tagging it. Native builds and Flutter tests
must run on GitHub Actions, not on this resource-constrained development host.

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
  `hearth-windows-setup.exe`, `hearth-web.zip`, plus the signed `manifest.json` used by
  auto-update clients.

## Auto-update signing

Clients fetch `manifest.json` directly from the latest public GitHub Release and
install in-app (Android package installer; Windows per-user installer + relaunch). They verify its
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

- `release-app` publishes only after Android, Windows, web, and the relay image succeed.
- Client builds pin **Flutter 3.44.7** (`FLUTTER_VERSION` in `release-app.yml`);
  change it there to move the toolchain.
- **Native builds and Flutter tests are CI-only on this development host** due to
  its resource constraints. See `AGENTS.md` for the full limits.
- Release builds derive their displayed version and Android version code from the
  git tag; `app/pubspec.yaml` is only the local-development fallback.

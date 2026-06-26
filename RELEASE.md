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

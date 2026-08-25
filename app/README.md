# Hearth App

Flutter client for Hearth. It provides the user interface, persistent Hive
storage, WebRTC data/media meshes, platform key storage, notifications, and
native update integration on top of the pure-Dart `core` package.

Run commands from the repository root:

```bash
flutter analyze app
cd app && flutter run
```

Native builds and the full Flutter test suite run in GitHub Actions because the
development host is resource constrained. Read [`../AGENTS.md`](../AGENTS.md)
before running build or test commands locally.

The primary release targets are Android, Windows, and web. iOS, macOS, and Linux
currently have Flutter scaffolding but are not release-gated for feature parity.

See the repository [`README.md`](../README.md) and
[`IMPLEMENTATION_PLAN.md`](../IMPLEMENTATION_PLAN.md) for architecture and
feature status.

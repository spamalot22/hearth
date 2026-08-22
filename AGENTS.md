# Hearth Development Instructions

## Resource-constrained environment

This repository is often opened on a remote machine with limited shared CPU,
memory, and disk. Resource-intensive local commands have previously made that
machine unresponsive or caused it to crash.

Do **not** run resource-intensive builds or full native test suites locally.
In particular, do not run:

- `flutter build ...`
- any `flutter test` command: this package's native hook compiles `fllama` and
  llama.cpp even when only one Dart test file is selected
- `./gradlew assemble...` or other Android release/debug builds
- Docker image builds
- clean/rebuild operations for native dependencies
- multiple test/build jobs in parallel

Use the GitHub Actions workflows in `.github/workflows/` for build, native test,
packaging, and release verification. Dispatch the appropriate workflow, monitor
it to completion, and inspect any failed job logs there. Do not tag or publish a
release until its required GitHub checks have succeeded.

Local work must be limited to lightweight inspection, formatting, static
analysis, and tests outside the Flutter package that are known not to invoke
native or Gradle compilation. Run all Flutter tests in GitHub Actions. Before
running a command whose resource cost is uncertain, treat it as
resource-intensive and use GitHub Actions instead.

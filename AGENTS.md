# Hearth Development Instructions

## Resource-constrained environment

This repository is often opened on a remote machine with limited shared CPU,
memory, and disk. Resource-intensive local commands have previously made that
machine unresponsive or caused it to crash.

Do **not** run resource-intensive builds or full native test suites locally.
In particular, do not run:

- `flutter build ...`
- full `flutter test` runs that compile `fllama`, llama.cpp, Gradle, or other
  native dependencies
- `./gradlew assemble...` or other Android release/debug builds
- Docker image builds
- clean/rebuild operations for native dependencies
- multiple test/build jobs in parallel

Use the GitHub Actions workflows in `.github/workflows/` for build, native test,
packaging, and release verification. Dispatch the appropriate workflow, monitor
it to completion, and inspect any failed job logs there. Do not tag or publish a
release until its required GitHub checks have succeeded.

Local work must be limited to lightweight inspection, formatting, static
analysis, and narrowly targeted tests that are known not to invoke native or
Gradle compilation. Before running a command whose resource cost is uncertain,
treat it as resource-intensive and use GitHub Actions instead.

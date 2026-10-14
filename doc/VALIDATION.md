# Local validation

Environment: macOS, Flutter 3.47.5 stable, Dart 3.13.4.

## Package API and release preparation (2026-10-14)

- `flutter test --coverage`: **55 passing tests**, covering 1,617 of 1,897
  instrumented Dart lines (**85.2%**). New regressions exercise bounded discovery,
  scan cancellation/concurrency/errors, disposal failures, field-stream cleanup,
  malformed native events and three-client reply/forward routing.
- Strict `flutter analyze`: no issues. Formatting checks passed for `lib`,
  `test`, `example/lib` and `tool`. Final `git diff --check`: passed.
- Chrome: 2 passing tests for explicit unsupported Flutter Web behavior.
  Node: 1 passing standalone browser protocol-client test.
- The updated Web example built successfully, including the SDK's Wasm dry run.
  This verifies compilation and does not enable native BLE roles in Flutter Web.
- `dart run tool/protocol_smoke.dart`: passed without a Flutter runtime.
- Standalone dartdoc 9.0.11 generated all 8 public libraries with **0 warnings
  and 0 errors**. The SDK-bundled documentation command failed locally; the
  standalone invocation with an explicit Dart SDK path is documented in
  CONTRIBUTING.md and used in CI.
- The updated Android debug, unsigned iOS debug and macOS debug examples built
  successfully. Both Apple examples built with CocoaPods in this checkout.
- Both iOS and macOS examples also built with Swift Package Manager in an
  isolated copy named `universal_ble_server`. A local package-identity mismatch
  was observed in the differently named checkout. The bundled example defaults
  to CocoaPods; CI has a separate package-named checkout for SwiftPM. Obsolete
  direct Swift package references were removed from the iOS example project.
- MIT license installed following the owner's selection. No third-party BLE
  dependency was added; native adapters remain responsible for Bluetooth I/O.
- Pana 0.23.19 predicts **150/160 points**: conventions 20/30, documentation
  20/20, platform compatibility 20/20, analysis 50/50, dependencies 40/40.
  The missing 10 points are the repository check: the public repository's
  `pubspec.yaml` lacks the repository/homepage metadata present in this working
  copy. Recheck after the changes are committed and pushed. A local score does
  not guarantee a hosted pub.dev score; its platform points do not establish
  working BLE roles on every platform.
- The publication dry run produced a 389 KB archive but exited with two Git
  warnings about modified and deleted tracked files in the uncommitted working
  tree. Nothing was published. Repeat the dry run from the final committed tree.
- CI now includes the declared minimum SDK, native build matrix, and both Apple
  dependency managers. These CI jobs have **not** been dispatched. Pana's lower
  dependency-bound analysis passed on the current SDK; this is not a minimum
  Flutter SDK execution test.
- Windows and Linux compilation remain unverified on this macOS host. Linux
  server and Flutter Web client/server roles remain explicitly unsupported.
- No physical devices were used. Coverage measures Dart lines, not native code
  or radio behavior. Permissions, simultaneous roles, subscriptions, disconnects,
  throughput and interoperability still require [hardware acceptance](HARDWARE_TESTING.md).
- Android tooling reports upcoming Gradle/Kotlin migration requirements. The
  current configuration preserves the declared Flutter 3.32/Dart 3.8 baseline;
  newer-toolchain migration must be checked separately before changing it.

Earlier sections below are historical validation records.

## Native clients and optional session layer (2026-09-29)

- `flutter test`: 47 passing tests. Added native channel contracts, multi-client
  framing and targeted delivery, typed field watches, metadata checks,
  authentication/admission/projection, session resumption, bounded retries and
  deduplication, authorization deadlines, concurrent connection rejection,
  cancellation and reconnection coverage.
- `flutter analyze`: no issues.
- `flutter test --platform chrome test/web`: 2 passing tests covering explicit
  unsupported client and server behavior.
- `node --test test/browser_client_test.cjs`: 1 passing protocol-client test.
- Android, unsigned iOS and macOS debug examples: compiled with the direct native
  client implementations and combined client/server example. Builds do not
  establish Bluetooth interoperability or permission behavior.
- No third-party BLE package is present in either package dependency graph.
  Native implementations use Android BluetoothGatt, Apple CoreBluetooth,
  Windows WinRT and Linux BlueZ D-Bus via the system GIO API.
- Web example: built successfully (including the SDK Wasm dry run); native BLE
  roles still report unsupported at runtime.
- `git diff --check`: passed.
- Native Windows and Linux code has not been compiled on this macOS host. The
  existing CI jobs cover those builds but have not been dispatched in this task.
- No physical devices were used. Multi-client and session tests use the simulated
  transport and validate Dart protocol behavior, not radio or OS behavior.
- The earlier coverage percentage and package dry run below are historical; they
  do not measure the expanded client/session implementation.

## API naming update (2026-09-28)

- `flutter test`: 29 passing tests, including new compatibility checks and
  coverage of storage versus notification behavior and callback naming conflicts.
- `flutter analyze`: no issues after updating the example to the new names.
- Native adapters and wire protocol were not changed in this update. Native
  builds, browser tests and coverage figures below refer to the preceding
  implementation validation, not a new hardware or native validation run.

## Preceding BLE implementation validation

- `flutter analyze`: no issues.
- `flutter test --coverage`: 26 passing tests; 524/658 instrumented Dart lines
  covered (79.6%). This is Dart coverage, not native or radio coverage.
- `flutter test --platform chrome test/web`: 1 passing test.
- `node --test test/browser_client_test.cjs`: 1 passing protocol-client test.
- Android debug example: built successfully.
- iOS debug example with `--no-codesign`: built successfully; not installed.
- macOS debug example: built successfully.
- Podspec Ruby syntax checks and `git diff --check`: passed.
- Package dry run: produced a 323 KB archive, with warnings about uncommitted
  changes/deleted tracked files. Nothing was published. License selection remains
  pending; the release workflow rejects the placeholder LICENSE.

Windows and Linux builds were not executed on this macOS host. CI build jobs are
provided but have not been dispatched by this task. No physical BLE exchange,
permission-prompt interaction, radio-off scenario or pairing was exercised.
See HARDWARE_TESTING.md before treating a platform as validated for production.

At that time, the SDK reported upcoming Android build-tool compatibility changes
and future Swift Package Manager adoption requirements. Those builds used
CocoaPods; see the latest entry above for the subsequent SwiftPM validation.

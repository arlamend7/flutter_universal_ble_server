## 0.2.0

### Added

* Flutter Web clients using direct Web Bluetooth interop, with no new dependency.
  `selectDevice()` opens the browser chooser from a user gesture; existing
  messaging and typed-field APIs handle reads, writes and notifications.
* Linux BlueZ GATT hosting with configurable advertising names, Dart read/write
  authorization, private and broadcast notifications, MTU checks and bounded
  notification backpressure. Oversized advertisements can retry without the name;
  `requireAdvertisedName` keeps strict name requirements explicit.
* Independent Linux client instances for connections to multiple peripherals.
  Each owns its discovery, notifications and cleanup; duplicate ownership of the
  same remote device is rejected. Existing client constructors remain unchanged.
* A Linux peripheral-hub example, browser chat support, platform guides and
  opt-in physical acceptance tests with a results template.
* Native BlueZ D-Bus tests, browser JavaScript/Wasm transport tests and regression
  coverage for maximum-size messages, private routing, interrupted transfers,
  reconnects, independent clients and disposal races. CI includes these checks.

### Fixed

* Stop discovery with a typed error when Bluetooth becomes unavailable.
* Preserve typed errors and release native client ownership when disposal fails.
* Cancel stale Linux capability checks and release sessions created during disposal.
* Restore Flutter 3.32 example compatibility by selecting Apple dependency
  managers through Flutter CLI settings instead of `flutter.config` in pubspec.
  Correct CI workflow parsing for the Swift Package Manager setup step.

### Compatibility and validation

* Existing public messaging and field APIs remain compatible. Browser clients
  use `selectDevice()` instead of native scanning. Flutter Web cannot host BLE.
* Multiple independent native client connections are implemented on Linux;
  Android, iOS, macOS and Windows retain one client connection per Flutter engine.
* BLE only: no Bluetooth Classic transport or additional BLE plugin dependency.
  The Dart/Flutter minimum versions are unchanged.
* Linux notifications require BlueZ's per-device `AcquireNotify` support.
  Linux/Pi builds and physical interoperability still require validation. Earlier
  macOS native-test runs intermittently hit a GLib socket-cleanup warning whose
  cause remains unresolved. See `doc/VALIDATION.md` for evidence and limits.

## 0.1.0

* Simplify common flows with bounded `discover`, `startWithPermissions`, direct
  field extensions, sender-specific replies and forwarding. Existing APIs remain.
* Add optional `excludeClientId` to message sends with recipient snapshots.
* Serialize scan startup/cleanup and cancel discovery on disposal; share disposal
  futures and close message streams when native cleanup fails.
* Enable strict type analysis and lifecycle lints; add discovery, routing and
  failure-cleanup regression tests and a simple runnable chat example.
* Add the MIT license, API documentation and package-quality release guidance.
* Add Swift Package Manager manifests and privacy resources while retaining
  CocoaPods support. Add a pure Dart `ble_protocol.dart` entry point.

* Add native central adapters using Android BluetoothGatt, Apple CoreBluetooth,
  Windows WinRT and Linux BlueZ D-Bus, without a third-party BLE dependency.
* Add shared field definitions, matching typed/message clients, reference-counted
  multi-field watches, bounded reconnection, readiness and structured errors.
* Compose custom fields with the message service; add protocol metadata and JSON
  helpers while preserving the original message frame format and legacy API.
* Add optional RPC/session wrappers with configurable admission, authorization,
  request/reply, acknowledgements, bounded retry/deduplication, session resumption,
  per-session revisioned snapshots and diagnostics. No application encryption or
  persistence is implied. Rename assembly limit with compatibility alias.
* Add combined client/server demo and integration, cancellation and retry tests.
* Windows/Linux client builds and all physical-device tests remain required.

* Combine stored-value updates and notifications in `updateStoredValue`, with
  an optional `notify: true` flag (defaults to false).

* Clarify public API categories: stored values, raw notifications, complete
  messages, client events and request callbacks. Add descriptive names while
  preserving existing calls; update examples and include a naming migration guide.

* Add BleMessageServer with configurable names, RX/TX/NAME characteristics,
  complete-message streams, targeted sends and bounded framing/reassembly.
* Add typed client readiness events, explicit Android adapter-name consent,
  Apple local-name advertising and Windows name limitations.
* Add complete messaging UI and an interoperable Web Bluetooth client example.

* Add typed, immutable profiles, multiple GATT services, UUID normalization,
  byte/UTF-8/uint16 codecs and custom validation.
* Add capabilities, Android permission requests, server states, dynamic reads,
  pre-commit write authorization, typed value updates and per-client events.
* Implement Android advertising, CCCD subscriptions, MTU checks, queued
  notifications, request deadlines and lifecycle cleanup.
* Correct Apple startup sequencing, dynamic characteristic values, offset reads,
  atomic rejection of unsupported write batches and notification backpressure.
* Implement WinRT characteristic creation, request bridging, subscriptions and
  notifications. Windows compilation/hardware acceptance must pass before release.
* Add OS-enforced encrypted read/write permissions; remove the unsupported AES
  messaging claim. Notification encryption is not guaranteed by that option.
* Add simulated backend, optional bounded message framing and contract tests.
* Web and Linux fail explicitly when peripheral operations are requested.
* Update example, platform setup, CI builds and hardware acceptance documentation.
* Breaking: notify no longer updates stored values; invalid configuration fails;
  platform adapters must adopt the new interface. See README migration notes.

## 0.0.1

* Initial BLE peripheral prototype.

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

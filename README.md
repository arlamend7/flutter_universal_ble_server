# universal_ble_server

Native Bluetooth Low Energy clients and servers with a small Dart API.
Host a named server, discover it from another device, and exchange text, bytes or
JSON. Add typed fields or admitted sessions only when your application needs them.
No third-party BLE plugin or state-management framework is required.

## Quick start

Import the package in both Flutter applications:

```dart
import 'package:universal_ble_server/universal_ble_server.dart';
```

On the **host**, subscribe before starting and reply to the sender:

```dart
final server = BleMessageServer(name: 'My BLE device');
final errors = server.errors.listen((error) => print(error));
final messages = server.receivedMessages.listen((message) async {
  try {
    await server.replyText(message, 'Received: ${message.text}');
  } catch (error) {
    print('Reply failed: $error');
  }
});
await server.startWithPermissions();
```

On the **client**, discover nearby servers and connect to the user's selection:

```dart
final client = BleMessageClient();
final errors = client.errors.listen((error) => print(error));
final messages = client.receivedText.listen(print, onError: print);
final devices = await client.discover(); // Permission + three-second scan.
// Display devices in your UI; selectedDevice is the user's choice.
await client.connect(selectedDevice.id);
await client.sendText('Hello!');
```

`discover()` returns an immutable list, retains the latest result per device and
stops scanning. An empty list means no matching server was found. Use
`startScan()` / `discoveredServers` for live scan UI, or `requestPermissions: false`
when your application already handles consent. Wrap awaited calls in your UI's
error handling; the `errors` stream also reports asynchronous failures.

Cancel subscriptions and dispose the owned endpoint when leaving the feature:

```dart
await messages.cancel();
await errors.cancel();
await client.dispose(); // On the host, dispose server instead.
```

Run the complete [example](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/example/README.md) on two physical devices and choose
**Simple chat**. It includes discovery/selection, name configuration, error UI,
one-to-one sends, broadcasts, optional forwarding, and cleanup.

## Choose the smallest API you need

| Need | Use |
| --- | --- |
| Send text, bytes or JSON | `BleMessageServer` / `BleMessageClient` |
| Reply to one incoming message | `server.replyText(message, text)` (also bytes/JSON) |
| Send to one client | `server.sendText(text, clientId: id)` |
| Send to all current subscribers | `server.sendText(text)` |
| Forward to everyone except the sender | `server.forward(message)` |
| Forward to a selected recipient | `server.forward(message, clientId: id)` |
| Store and observe configuration values | Shared `BleFieldDefinition<T>` and typed field methods |
| Application requests, identity, retries, shared state | Optional `BleSessionServer` / `BleSessionClient` |
| Implement an external device's custom GATT protocol | `UniversalBleClient` / `UniversalBleServer` |
| Pure Dart protocol tools/custom transports | `package:universal_ble_server/ble_protocol.dart` |

A message server and client also expose typed field operations directly through
extensions, so common code does not need nested `.gatt` or `.client` access:

```dart
await server.updateStoredValue(scoreField, 10, notify: true);
final initial = await client.readValue(scoreDefinition);
final updates = await client.watchValue(scoreDefinition);
final subscription = updates.listen((score) => print(score));
// Later: await subscription.cancel();
```

Fields and notifications are different: storage is readable later; notifications
send a new value to current subscribers. See the [field guide](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/doc/CLIENT_SERVER.md).
For game hosts, apply local moves to the same application logic that handles
remote requests; a host does not need to connect to itself.

## Install and configure

This source includes unreleased changes. To try the current implementation, use
a local path dependency (or a Git dependency pinned to a commit containing these
changes). Do not assume an older published version exposes this API.

```yaml
dependencies:
  universal_ble_server:
    path: ../flutter_universal_ble_server
```

- **Android:** permissions are declared by the plugin; request consent through
  `startWithPermissions()` / `discover()` or the explicit permission APIs.
- **iOS/macOS:** add Bluetooth usage descriptions; macOS sandbox apps also need
  the Bluetooth entitlement. Both Swift Package Manager and CocoaPods layouts
  are provided. The example includes the required configuration.
- **Windows/Linux:** see the [platform setup](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/doc/CLIENT_SERVER.md#permissions-and-manual-acceptance).

The library uses native OS APIs. Runtime capability checks and device testing are
necessary; Flutter does not make every adapter support every BLE role.

## Platform status

| Platform | Server | Client | Validation |
| --- | --- | --- | --- |
| Android | Native GATT server/advertiser | Native BluetoothGatt | Local example build; hardware tests pending |
| iOS/macOS | Native CoreBluetooth | Native CoreBluetooth | Local example builds; hardware tests pending |
| Windows | Native WinRT | Native WinRT | Windows compilation and hardware tests pending |
| Linux | Unsupported | Native BlueZ D-Bus/GIO | Linux compilation and hardware tests pending |
| Flutter Web | Unsupported | Unsupported | Fails explicitly; separate HTML client available |

API compatibility with a platform is not a physical BLE certification. Native
adapters currently own one server and one remote client connection per Flutter
engine; construct ordinary instances and dispose them. No application singleton
is required. Inject a transport/platform for tests or custom integrations.

## Defaults and delivery semantics

- The default wire format splits messages into 20-byte frames, supporting complete
  messages up to 65,535 bytes. Both peers must share the protocol configuration.
- Queues, partial-message assembly and optional session caches are bounded.
- Server sends snapshot their recipients. No eligible subscriber is an error.
  `excludeClientId` can omit a sender from a broadcast without an application loop.
- A completed send is not an application acknowledgement. Use session requests
  or `sendAcknowledged` when you need a handler's response. Retries are opt-in.
- Native IDs are connection-local, not authenticated user identities. Configure
  your application's access rules; session hooks do not protect raw fields.
- Data and sessions are in memory. Persistence, application encryption, background
  execution guarantees and host migration are not supplied.

## Guides

Guide sources are included in `doc/` and `example/`. Hosted links refer to the
repository and become available there when these unreleased changes are pushed.

- [Detailed server setup, permissions and migration](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/doc/SERVER.md)
- [Full client/server API and sessions](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/doc/CLIENT_SERVER.md)
- [Use-case recipes and lifecycle ownership](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/doc/RECIPES.md)
- [Names, storage, notifications and migration](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/doc/API_GUIDE.md)
- [Wire protocol and browser client](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/doc/PROTOCOL.md)
- [Runnable example](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/example/README.md)
- [Local validation](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/doc/VALIDATION.md) and [hardware acceptance](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/doc/HARDWARE_TESTING.md)
- [Contributing and release checks](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/CONTRIBUTING.md)


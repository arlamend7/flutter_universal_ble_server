# universal_ble_server

Bluetooth Low Energy clients and servers with a small Dart API.
Host a named server, discover it from another device, and exchange text, bytes or
JSON. Add typed fields or admitted sessions only when your application needs them.
No third-party BLE plugin or state-management framework is required.
Flutter Web clients connect through Web Bluetooth in supported browsers.

## New in 0.2.0

- Connect from Flutter Web using `selectDevice()` and the existing messaging API.
- Host a BLE server on Linux through native BlueZ, including named advertising,
  authorized reads/writes, private replies and broadcasts.
- Connect a Linux host to multiple peripherals with one client instance per
  device. The new hub example demonstrates independent sends and disconnects.

Existing messaging and field APIs remain compatible. This package supports BLE;
Bluetooth Classic is outside its scope. Linux/Pi hardware validation is pending,
and a macOS native-test cleanup warning remains unresolved. See the
[0.2.0 changelog](CHANGELOG.md#020) and [validation record](doc/VALIDATION.md).

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

On **Flutter Web**, replace discovery with a browser chooser, called directly
from a button callback:

```dart
final device = await client.selectDevice();
if (device != null) {
  await client.connect(device.id);
  await client.sendText('Hello from the browser!');
}
```

The messaging API is unchanged. Web requires HTTPS or localhost and a compatible
browser; BLE hosting remains native. See the [web guide](doc/WEB.md) for custom
service permissions, browser limits and a runnable example.

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
| Connect a Linux hub to multiple peripherals | One `BleMessageClient` or `UniversalBleClient` per device |
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

Requires Dart 3.8.1 or newer and Flutter 3.32.0 or newer. For version 0.2.0:

```yaml
dependencies:
  universal_ble_server: ^0.2.0
```

Until 0.2.0 is published, use a local path dependency or a Git dependency pinned
to a commit containing these changes. The bundled example uses a local path.
When upgrading from 0.1.x, explicitly update the constraint to `^0.2.0`.

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
| Windows | Native WinRT | Native WinRT | Earlier CI example build passed; hardware tests pending |
| Linux | Native BlueZ GATT/advertiser | Independent BlueZ clients | Native D-Bus tests; Linux build and hardware validation pending |
| Flutter Web | Unsupported | Direct Web Bluetooth | Chrome tests with simulated GATT; physical tests pending |

API compatibility with a platform is not a physical BLE certification. Native
adapters own one server per Flutter engine. Linux supports multiple independently
owned client instances; other native backends retain one remote connection per
engine; construct ordinary instances and dispose them. No application singleton
is required. Inject a transport/platform for tests or custom integrations.

See [Linux/Raspberry Pi hosting and multiple peripherals](doc/LINUX.md) for
requirements, examples and backend-specific limits.

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

Guide sources are included in `doc/` and `example/`; repository links follow the
main branch and may describe changes newer than an installed release.

- [Flutter Web setup and browser limitations](doc/WEB.md)
- [Linux/Raspberry Pi hosting and multiple peripherals](doc/LINUX.md)
- [Detailed server setup, permissions and migration](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/doc/SERVER.md)
- [Full client/server API and sessions](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/doc/CLIENT_SERVER.md)
- [Use-case recipes and lifecycle ownership](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/doc/RECIPES.md)
- [Names, storage, notifications and migration](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/doc/API_GUIDE.md)
- [Wire protocol and browser client](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/doc/PROTOCOL.md)
- [Runnable example](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/example/README.md)
- [Local validation](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/doc/VALIDATION.md) and [hardware acceptance](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/doc/HARDWARE_TESTING.md)
- [Contributing and release checks](https://github.com/arlamend7/flutter_universal_ble_server/blob/main/CONTRIBUTING.md)


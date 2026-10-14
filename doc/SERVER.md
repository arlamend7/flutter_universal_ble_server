# Server reference

## Choose the API by task

Use **`BleMessageServer`** to exchange complete text or byte messages. Use
**`UniversalBleServer` + `BleProfile`** to expose individual configuration values
or a custom GATT protocol. A `BleField<T>` describes one characteristic; a
`BleService` groups fields, and a `BleProfile` groups services.

| Category | API | Purpose |
| --- | --- | --- |
| Setup (both servers) | `checkSupport()`, `requestPermissions()` | Check capabilities/readiness and request OS permission |
| Lifecycle (both) | `start()`, `stop()`, `dispose()` | Start advertising, stop for reuse, or release permanently |
| Monitoring (both) | `state`, `stateChanges`, `errors` | Current status, future status changes, asynchronous errors |
| Messaging | `sendText(text)`, `sendBytes(bytes)` | Send a complete message, splitting it into frames automatically |
| Messaging | `receivedMessages` | Listen for complete incoming messages |
| Clients (message server) | `clientEvents`, `subscribedClientIds` | Observe client changes and find clients ready to receive |
| Stored values (custom GATT) | `readStoredValue(field)` | Read the local stored value without a Bluetooth request |
| Stored values (custom GATT) | `updateStoredValue(field, value)` | Replace storage without sending anything |
| Stored values + transmission | `updateStoredValue(field, value, notify: true)` | Replace storage, then notify the field's subscribers |
| Raw transmission (custom GATT) | `sendNotification(uuid, bytes)` | Send one raw GATT payload without changing storage |
| Client activity (custom GATT) | `clientReads`, `clientWrites` | Observe successful reads and accepted writes |
| Field callbacks | `readValue`, `authorizeWrite` | Compute read responses or approve writes before they commit |
| Advanced diagnostics (both) | `events` | Raw platform events, including advertising warnings |

Both message send methods and `sendNotification` accept `clientId` to select one
subscriber; omit it to target all current subscribers. Raw notifications do not
fragment data. Message sends require at least one subscribed recipient.

### What did `setValue` mean?

It changes a characteristic's **stored value on this server**. For example,
changing an interval from 30 to 60 lets a client read 60 later (if the field allows
reads and no dynamic callback overrides its response). It does not configure a
remote device or send an immediate message by default.

```dart
await server.updateStoredValue(interval, 60); // Store only.
print(server.readStoredValue(interval)); // Local snapshot: 60.
await server.updateStoredValue(interval, 90, notify: true); // Store and announce 90.
```

`setValue(interval, 60)` still works as before. The explicit names above are
preferred in new code. See [API naming and migration](API_GUIDE.md) for old
names, callback semantics and examples of storage versus transmission.

## Bidirectional messages

```dart
import 'package:universal_ble_server/universal_ble_server.dart';

final server = BleMessageServer(
  name: 'Meu servidor BLE',
  // Android only: explicit consent to temporarily change the system BT name.
  allowAndroidAdapterNameChange: true,
);
final received = server.receivedMessages.listen((message) {
  print('${message.clientId}: ${message.text}');
});
final clients = server.clientEvents.listen((event) {
  print('${event.kind.name}: ${event.clientId}');
});
final errors = server.errors.listen(print);
final support = await server.requestPermissions();
support.requireCompatible();
await server.start();

// After a compatible client subscribes to TX:
await server.sendText('Olá!');
// await server.sendBytes([1, 2, 3], clientId: selectedClientId);

await server.stop();
await received.cancel();
await clients.cancel();
await errors.cancel();
await server.dispose();
```

This API provides RX writes, TX notifications, a readable logical name, typed
client events and automatic framing/reassembly up to 65535 bytes. Messages use
20-byte frames by default. Both peers must implement the documented protocol;
raw text writes are not valid frames. See [wire protocol and compatible browser
client](PROTOCOL.md). The example app configures the name, starts/stops the
server, selects recipients, sends text and displays received messages and errors.

### Configurable name

`BleMessageServer(name: ...)` and `BleProfile(name: ...)` accept 1..29 UTF-8 bytes.
The message service always exposes the logical name through its NAME characteristic.

- **iOS/macOS:** uses CoreBluetooth local-name advertising. The OS can shorten it;
  iOS suppresses local names in background.
- **Android:** the public advertiser uses the system Bluetooth adapter name.
  `allowAndroidAdapterNameChange: true` permits changing it while running and
  restoring it on stop if it has not been changed again externally. This affects
  the device-wide name. Crashes or lost permissions may prevent restoration.
  Without opt-in, a different requested name is omitted and a warning event is
  emitted; no global setting is changed. Names go in the scan response.
- **Windows:** a custom local name cannot be set using the supported WinRT GATT
  advertising API. The logical name is readable after connecting, and a warning
  event explains that it is not advertised.

Set `requireAdvertisedName: true` to fail if the backend cannot honor a custom
name request instead of continuing with service-UUID discovery. This checks API
support, not whether an OS preserves the full name in every advertisement.
`checkSupport()` also reports `nameSupport` and `connectionEvents`.

## Custom typed GATT profiles

```dart
import 'package:universal_ble_server/universal_ble_server.dart';

final interval = BleField<int>(
  uuid: '0000abce-0000-1000-8000-00805f9b34fb',
  codec: BleCodecs.uint16LittleEndian,
  initialValue: 30,
  access: {BleProperty.read, BleProperty.write, BleProperty.notify},
  validate: (value) => value >= 1 && value <= 3600,
);

final server = UniversalBleServer(
  profile: BleProfile(services: [
    BleService(uuid: '0000abcd-0000-1000-8000-00805f9b34fb', fields: [interval]),
  ]),
);

final support = await server.requestPermissions(); // Call from a user action.
support.requireCompatible();
await server.start();
await server.updateStoredValue(interval, 60, notify: true);
print(server.readStoredValue(interval)); // 60

// Cancel your subscriptions and release the adapter when finished.
await server.dispose();
```

`BleCodecs.bytes`, `utf8String` and `uint16LittleEndian` are included. Implement
`BleCodec<T>` for your own binary/JSON protocol. The peer must use the same format.
Use assigned SIG UUIDs only for the corresponding standard services; use your own
128-bit UUIDs for custom production protocols. The UUIDs above are examples.

## API semantics

- `BleProfile` exposes one or more services. UUIDs are canonicalized and
  characteristic UUIDs must be unique across the profile.
- Only `advertisedServiceUuid` (the first service by default) is discoverable in
  advertisements. All services are accessible through GATT after connection.
  Manufacturer data, transmit power and background persistence are not portable
  configuration options in this release. Name behavior is documented above.
- `start()` completes after native registration and advertising startup. A
  second start requires `stop()` first. One server owns each adapter.
- `updateStoredValue(field, value)` updates storage without sending.
  `updateStoredValue(field, value, notify: true)` also sends to subscribed clients.
  If sending fails, the stored value remains updated.
- `sendNotification(uuid, bytes, clientId: id)` can target one subscriber. Omitting the ID
  sends to all subscribers. It sends without changing stored
  values. With no subscribers it completes without transmitting. Completion
  means native acceptance/transmission, not application-level acknowledgement.
- Operations are serialized. Values are limited to 512 bytes; notifications are
  additionally checked against each subscriber's negotiated payload limit.
  Oversized notifications fail instead of being silently truncated.
- `stateChanges`, `events`, `errors`, `clientReads` and `clientWrites` are broadcast streams.
  Subscribe before starting. Errors from requests also appear in `errors`.
  `clientWrites` reports accepted writes, not rejected attempts.
- Android exposes connection and subscription events. Apple/Windows expose
  subscription events; these do not represent every physical connection.
  Client identifiers are opaque, platform-local and are not authentication.
- `stop()` releases native resources; `dispose()` also closes Dart streams.
  Retain and cancel subscriptions in your widget's `dispose` method.

## Dynamic reads and write authorization

```dart
final command = BleField<String>(
  uuid: 'f7cdac41-3a39-4dc5-bc42-a90d1d3a2210',
  codec: BleCodecs.utf8String,
  initialValue: 'idle',
  access: {BleProperty.read, BleProperty.write},
  readValue: (request) => currentStatus(),
  authorizeWrite: (request, proposedValue) async {
    return await isAllowed(request.clientId, proposedValue);
  },
);
```

The helper functions above belong to your application. `authorizeWrite` authorizes the
value before it is committed. Perform effects from accepted-write events and use
an application acknowledgement/idempotency protocol for important commands.
A client ID alone does not prove identity. Hooks must finish within
`requestTimeout` (default/max 5 seconds); native requests also have a 6-second
fallback. Timed-out futures cannot be cancelled: keep hooks free from irreversible
side effects. Late completions cannot commit through the server.

Read callbacks return the whole value; the backend applies the requested offset.
The portable write contract replaces a complete value at offset zero. Android
prepared/reliable writes and Apple multi-request batches are explicitly rejected.
Do not use this API for transactional long writes without implementing a protocol
above individual writes. Writes use the GATT write-with-response property.

## Security

The library does **not** implement AES-encrypted application messages. Base64 is
only the Flutter/native transport encoding. To require link encryption for reads
and writes, configure `security: BleSecurity.encryptedReadWrite` on a field.
The OS manages pairing/encryption. This option does not authenticate your
application peer, provide replay protection, or promise encrypted notifications.
For sensitive notifications use a reviewed application protocol with authenticated
encryption and key provisioning on both peers; do not invent a crypto scheme.

## Optional larger messages

`BleMessageFramer.encode` and `BleMessageAssembler` provide a bounded, versioned,
ordered framing format (see their Dart documentation). Both peers must opt in.
Frames have a seven-byte header; select `maxFrameBytes` within the negotiated
notification/write limit (20 bytes is the baseline ATT payload). Send each frame
with `BleCodecs.bytes`, no automatic resend, and use one assembler per client.
Reset on disconnect; handle missing/duplicate frames as errors. Framing does not
supply encryption, delivery acknowledgement or replay protection. Normal GATT
values are never automatically fragmented.

## Platform setup

### Android

The library declares legacy Bluetooth permissions, `BLUETOOTH_CONNECT`,
`BLUETOOTH_ADVERTISE`, `BLUETOOTH_SCAN`, and fine location through Android 11. `requestPermissions()` needs a foreground Flutter Activity
on Android 12+. The server requests its own role permissions; the client requests scan/connect
(or location on older Android versions). The user must enable Bluetooth. Background foreground-service
support is outside this version's contract.

### iOS

Add `NSBluetoothAlwaysUsageDescription` and (for iOS 12)
`NSBluetoothPeripheralUsageDescription` to the app's `Info.plist`, with a truthful
usage explanation. CoreBluetooth controls the consent prompt; initializing it
through `checkSupport()` may also show that prompt. If your application
requires background peripheral behavior, configure `UIBackgroundModes` with
`bluetooth-peripheral` and separately test Apple's background restrictions.
This plugin does not guarantee background availability or state restoration.

### macOS

Add `NSBluetoothAlwaysUsageDescription` to the app's `Info.plist` and
`com.apple.security.device.bluetooth = true` to both DebugProfile and Release
entitlements. The example includes these entries.

### Windows

Use Visual Studio with Desktop development with C++, C++20 and a Windows 10 SDK
1903 or newer. The build links `windowsapp`. A packaged application should declare
the `bluetooth` device capability in its package manifest. Peripheral support is
adapter/driver-dependent. Verify the Windows CI job and real hardware before
publishing a Windows release.

## Compatibility with 0.0.1

`startServer(serviceUuid: ..., characteristics: ...)`, `stopServer()`, `notify`,
`BleCharacteristic` and read/write event models remain available. Empty/invalid
configuration now throws instead of silently succeeding. `notify` no longer
implicitly updates readable storage; use `updateStoredValue` (optionally with `notify: true`). Internal native
channels and the platform interface changed in 0.1.0; custom adapters must adopt
`startProfile`, `events`, `setRequestHandler`, `checkSupport` and `setValue`.

## Tests

```sh
flutter pub get
flutter analyze
flutter test
flutter test --platform chrome test/web
node --test test/browser_client_test.cjs
cd example
flutter build apk --debug
```

Import `package:universal_ble_server/testing.dart` and inject a
`SimulatedBlePlatform` into the server to simulate reads/writes without hardware.
`ble_profile.dart` exposes models, codecs and framing without importing Flutter.
The fake does not simulate OS permissions, pairing or radio behavior. CI compiles
native targets; the manual hardware matrix verifies actual interoperability.

## Release requirements

The package is MIT licensed. Pass all CI builds and complete the hardware
acceptance matrix before publishing. No publication or device testing is implied
by generating this implementation. The publishing workflow checks version/tag
consistency and refuses the placeholder license.

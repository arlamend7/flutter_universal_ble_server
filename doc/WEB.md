# Flutter Web client

Flutter Web uses the browser's Web Bluetooth API directly through Dart JS
interop. No additional runtime dependency or BLE plugin is required. Native
clients retain their existing API. Browsers cannot advertise or host a BLE GATT
server with this API: run the host on a supported native platform.

## Connect and exchange messages

Create the client once, subscribe to incoming messages, and call `selectDevice()`
directly from a button callback. Do not await permissions, network calls, or other
work before opening the chooser: the browser requires transient user activation.

```dart
final client = BleMessageClient();
final errors = client.errors.listen(print);
final messages = client.receivedText.listen(print, onError: print);

Future<void> onConnectPressed() async {
  try {
    final device = await client.selectDevice();
    if (device == null) return; // Cancelled or no device chosen.
    await client.connect(device.id);
    await client.sendText('Hello from Flutter Web!');
  } catch (error) {
    print(error);
  }
}

// When the screen is closed:
// await messages.cancel();
// await errors.cancel();
// await client.dispose();
```

The host uses `BleMessageServer` with the same `BleMessageConfiguration`. Its
`receivedMessages` stream receives the browser's messages; `replyText`, targeted
sends and broadcasts work as usual. Text, bytes, JSON and optional session/RPC
layers share the same transport. The logical server name is read after connecting;
the chooser may display the OS's advertising name instead.

## Device selection and custom fields

`BleMessageClient.selectDevice(optionalServiceUuids: [...])` filters by the
configured message service. List additional services containing custom fields in
`optionalServiceUuids`; browsers grant access only to services requested at
selection time. Existing `readValue`, `writeValue`, `watchValue`, `watchValues`,
`disconnect` and message methods are unchanged.

For other GATT protocols, use
`UniversalBleClient.selectDevice(serviceUuids: [...], optionalServiceUuids: [...])`.
Every service in `serviceUuids` must be advertised by a matching device. An empty
filter opens an all-devices chooser; still list services you need to access in
`optionalServiceUuids`. UUIDs are normalized and duplicates removed.

Selection grants permission and returns a device; it does not connect. One
selected device and one connection are retained per client instance. Reconnecting
to that device in the same instance does not require another chooser. Arbitrary
IDs from native platforms or a previous page load cannot bypass selection.
Disconnect before selecting another device. Browser choosers cannot be dismissed
programmatically; disposal invalidates any eventual selection.

Native `discover()` / `startScan()` remain unchanged. On web they report
`BleErrorCode.unsupported`; use the chooser instead. Conversely, the default
native transport reports unsupported for `selectDevice()` and continues to use
application-owned discovery UI. Existing custom transports need no changes;
they can implement the optional `BleDeviceSelector` interface.

## Requirements and limitations

- HTTPS or localhost and a browser/OS combination implementing Web Bluetooth.
  Browser support is not universal. See the browser vendor's
  [Web Bluetooth guide](https://developer.chrome.com/docs/capabilities/bluetooth).
- The user chooses and authorizes a device in the browser. Embedded pages may
  also need the embedding site's `bluetooth` Permissions Policy authorization.
  `requestPermissions()` checks availability only; it does not open a chooser.
- `checkSupport()` reports unsupported when the API or secure context is absent.
  When `getAvailability()` returns false, state is `unknown`: privacy, policy,
  missing hardware and a disabled radio cannot reliably be distinguished.
  Browser availability and disconnect events update the existing streams.
- Chooser cancellation returns null. Security/permission errors become
  `permissionDenied`; GATT network/invalid-state failures become `disconnected`.
  Observe returned futures and the existing asynchronous `errors` streams.
- Browsers do not expose negotiated ATT MTU. Writes use a conservative **20-byte
  limit** with responses. Complete messages use the existing fragmentation
  protocol (default 20-byte frames, up to 65,535 message bytes). Both peers must
  use compatible configuration; a configuration requiring larger frames fails.
  Raw field writes over 20 bytes fail rather than silently fragmenting a value.
- Reads respect the returned DataView's byte offset and length. Notifications
  and indications use `startNotifications()`; the browser manages the CCCD.
- No background scanning, RSSI, peripheral advertising, MTU negotiation or
  guaranteed background operation. Keep the page and native host in foreground.
  A browser may revoke access or suspend the page independently of the library.

## Runnable example and validation

Run `flutter run -d chrome` inside `example`, then open **Simple chat**. On a
physical native device open the same screen and **Host chat**. In Chrome choose
**Choose BLE device**, select that host, then **Connect**. Send in both directions;
the host may also relay to another native or browser client. The chat uses
`protocol: 'chat-demo'` on both ends. The standalone HTML example continues to
pair with the separate original message-server screen.

`flutter test --platform chrome test/web` exercises the default production web
transport with simulated JavaScript Bluetooth objects, promises and browser
events, backed by the actual Dart server/protocol. It covers chooser timing,
permissions, fields, fragmented messages, reconnection and cleanup. It does not
validate the browser's real device picker, radio, OS permissions or physical
interoperability. Build and test success are not hardware certification.

For physical acceptance record browser/OS versions and device models. Test
chooser cancellation and denial, bidirectional text/binary messages, custom-field
permissions and notifications, host disconnect/reconnect, Bluetooth off/on, page
reload and a browser plus native client connected to one host. Use the results
record in [HARDWARE_TESTING.md](HARDWARE_TESTING.md); mark unrun cases explicitly.

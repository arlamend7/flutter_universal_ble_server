# Practical recipes

Import `package:universal_ble_server/universal_ble_server.dart` for the Flutter
API. Ordinary instances own their lifecycles; no provider, global singleton or
state-management package is required. Prefer constructor injection in application
services. The default native adapter allows one server per engine. Linux supports
independent clients for multiple peripherals; other native platforms currently
allow one client per engine. See [Linux hosting and hubs](LINUX.md).

## Chat and routing

Start a `BleMessageServer`, discover it with `BleMessageClient.discover`, connect
to the user's selected device and listen before sending. The runnable
[chat screen](../example/lib/chat_demo.dart) includes the complete flow.

```dart
await server.replyText(incoming, 'Accepted'); // Original sender only.
await server.forward(incoming); // Everyone except the original sender.
await server.forward(incoming, clientId: recipientId); // One recipient.
await server.sendJson({'event': 'roundStarted'}); // Everyone subscribed.
```

`forward` copies unchanged payload bytes. It does not add a sender or timestamp.
Define an application envelope when recipients need identity, message type or a
sequence number. The server knows the actual source as `incoming.clientId`;
never trust a client-supplied `from` field. Recipient IDs must come from the host's
current roster and pass application authorization. Forwarding is never automatic.
No eligible recipient is an error, including forwarding when only the sender is
connected. If no-op behavior is desired, check `subscribedClientIds` first and
still catch a disconnect between checking and sending.

Use awaited operations inside a `try/catch`. `Stream.listen` does not await an
async callback or automatically report errors from its returned future. For
ordered application processing, use `await for` or an application-owned queue.
The library serializes outgoing message frames but does not serialize your game
rules or business transactions.

## Device configuration

Define a field once and share the definition between host and client:

```dart
final interval = BleFieldDefinition<int>(
  serviceUuid: '947db030-83c5-4a59-8ab1-831637027ca0',
  uuid: '947db030-83c5-4a59-8ab1-831637027ca1',
  codec: BleCodecs.uint16LittleEndian,
  access: {BleProperty.read, BleProperty.write, BleProperty.notify},
);
final intervalField = interval.bind(
  initialValue: 30,
  validate: (seconds) => seconds >= 1 && seconds <= 3600,
);
final server = BleMessageServer(
  name: 'Controller',
  additionalServices: [
    BleService(uuid: interval.serviceUuid, fields: [intervalField]),
  ],
);
```

The connected client can `readValue(interval)`, `writeValue(interval, 60)` and
`watchValue(interval)`. The server can inspect `readStoredValue(intervalField)`
and call `updateStoredValue(intervalField, 90, notify: true)`. An accepted remote
write updates storage but does not automatically notify every client; subscribe
to `server.gatt.clientWrites` if your application needs to redistribute it.
Notifications and raw writes must fit the peer payload size. Use messages for
large configurations, and validate their application schema before applying them.

For a pre-existing external device, use its documented service IDs, codecs and
access flags with `UniversalBleClient`. It need not implement this package's
message framing. A `BleMessageClient` does require matching metadata and framing.

## A multiplayer turn-based game

Use `BleSessionServer` on the host and `BleSessionClient` for each remote player.
Both sides agree on the application protocol/version. A request handler receives
the admitted session, method and payload, validates the current turn, applies a
move, and returns its result. Broadcast revisioned snapshots using
`updateSharedState`; use `projectState` for private hands or inventories.

Keep game validation in a plain Dart function/service. The host player calls it
locally; remote session handlers call the same logic. The host does not need a
BLE connection to itself. Serialize state mutations in the application when they
can overlap. A successful response confirms handler completion, not persistence.

Authentication is opt-in; configure `authenticate` and `authorize` to match the
application. Sessions are retained in memory for a bounded resume window. If a
request result is uncertain, use an explicit unique `requestId` and the same
method/payload when retrying within the deduplication window. Process restarts
and expired cache entries invalidate that guarantee. See the
[session guide](CLIENT_SERVER.md#5-optional-sessions-and-requests).

## Ownership, errors and cancellation

| Resource | Owner / cleanup |
| --- | --- |
| Message client | Owns its supplied `UniversalBleClient`; dispose the message wrapper |
| Raw client | Owns its supplied `BleClientTransport`; dispose the client |
| Message server | Owns its internal GATT server; stop/dispose through the wrapper |
| Session wrapper | Owns subscriptions; dispose it before its message endpoint |
| `watchValue` result | Listen to the returned stream and cancel the subscription |
| `watchValues` result | Cancelling its subscription cancels every field watch |
| `discover` | Stops itself; `stopScan` ends early; disposal cancels pending work |

Handle awaited calls and asynchronous `errors`. New client errors carry a
`BleErrorCode`; older server errors retain their existing types for compatibility.
Do not blindly retry permissions, invalid data or protocol mismatches. Reconnection
is opt-in; pending application commands are not automatically replayed.

Flutter `State.dispose` is synchronous. Start cleanup with `unawaited`, observe
its errors, and guard callbacks with `mounted`. Use an explicit awaited Stop
button for operations whose completion matters to the next screen. The chat
example demonstrates both patterns.

## Tests and framework independence

Import `package:universal_ble_server/testing.dart` for `SimulatedBlePlatform` and
`SimulatedBleClientTransport`. Inject them into the real public classes; tests
exercise framing, field access and session logic without touching a radio.
The simulation is not a replacement for physical-device acceptance.

Import `package:universal_ble_server/ble_protocol.dart` in Dart-only tools for
profiles, codecs, framing and `BleRpcChannel`. It imports no Flutter services and
does not acquire a native adapter. The Flutter plugin entry point remains
necessary for operating a physical Bluetooth radio.

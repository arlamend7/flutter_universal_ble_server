# API guide: configuration values and messages

## 1. Pick the right server

- **BleMessageServer** exchanges complete text/binary messages with clients using
  this library's framing protocol. Start here for chat, commands or JSON messages.
- **UniversalBleServer** exposes a custom GATT profile. Start here for individual
  configuration values, standard services or an existing device protocol.

These are two API levels over the same native backend. Do not start both on the
same adapter at the same time. To combine fields and messages, pass custom
services to `BleMessageServer(additionalServices: ...)` and use `server.gatt`
for their updates. Both server and client roles are available. Reading local server storage
does not contact another device; `UniversalBleClient.readValue` performs a remote
read. See [client/server guide](CLIENT_SERVER.md) for connection and subscriptions.

## 2. Storage is different from transmission

A GATT characteristic is a value identified by a UUID. Its access properties
control whether clients can read it, write it or subscribe to notifications.
Suppose `interval` is a `BleField<int>` using `BleCodecs.uint16LittleEndian`, with
initial value 30 and read/write/notify access in a running custom server:

```dart
// Change what the server stores; no notification is sent.
await server.updateStoredValue(interval, 60);
print(server.readStoredValue(interval)); // 60, read from local memory.

// Send a raw notification containing 90, without changing stored 60.
await server.sendNotification(interval.uuid, interval.codec.encode(90));
print(server.readStoredValue(interval)); // Still 60.

// Store 120, then notify all subscribers with its encoded value.
await server.updateStoredValue(interval, 120, notify: true);
```

All storage operations require the active profile's field instance. Values use
that field's codec/validation and must fit 512 bytes. Notifications must also fit
the recipient's negotiated payload size. Raw notifications do not split data;
use `BleMessageServer` when both peers support the message framing protocol.

`updateStoredValue(..., notify: true)` checks notification access before changing storage.
If storing succeeds but transmission fails, the stored value remains changed.
A successful notification does not guarantee the client's application processed
it. With no subscribers, raw notification calls send nothing.

## 3. Callbacks decide; event streams report

Configure these callbacks on a `BleField`:

- `readValue: (request) => ...` computes the value returned for a client read.
  It overrides stored data for that response without changing local storage.
- `authorizeWrite: (request, proposedValue) => ...` returns true to allow a client
  write, or false to reject it. Validation also applies. Avoid irreversible side
  effects: callbacks have deadlines, and a timed-out future cannot be cancelled.

Listen to these streams on `UniversalBleServer`:

- `clientReads` reports successful reads.
- `clientWrites` reports accepted writes after storage updates, not rejected
  attempts. Use it to react to an accepted command or configuration change.

A server-side storage update does not emit a client-write event.
`readStoredValue` never calls the dynamic `readValue` callback.

## 4. Complete messages and client readiness

With a running `BleMessageServer` and a compatible subscribed client:

```dart
final incoming = server.receivedMessages.listen((message) {
  print('${message.clientId}: ${message.data}');
  // message.text decodes UTF-8; only use it if the peer sent valid UTF-8.
});
final clients = server.clientEvents.listen((event) {
  print('${event.kind}: ${event.clientId}');
});
await server.sendText('Hello');
await server.sendBytes([1, 2, 3]);
// Add clientId: selectedId to either method for a specific recipient.
```

`subscribedClientIds` is a snapshot of clients ready to receive outgoing messages,
not a list of every physical Bluetooth connection. Apple/Windows report
subscriptions rather than every physical connection. Sending with no subscribed
target throws. Messages are fragmented/reassembled automatically; raw external
writes must still follow [the protocol](PROTOCOL.md).

Subscribe before `start()` to observe early events. Keep the subscriptions and
cancel them when finished. `stop()` permits restarting; `dispose()` permanently
releases resources and closes streams.

## 5. Compatible name mapping

Old names remain callable with the same behavior; no migration is mandatory.
Examples and documentation use the preferred names. Native channel method names
and the platform adapter interface are unchanged by this naming update.

| API | Previous name | Preferred name |
| --- | --- | --- |
| Custom GATT | `setValue(field, value)` | `updateStoredValue(field, value)` |
| Custom GATT | `setValue(field, value, notify: true)` | `updateStoredValue(field, value, notify: true)` |
| Custom GATT | `valueOf(field)` | `readStoredValue(field)` |
| Custom GATT | `notify(uuid, bytes)` | `sendNotification(uuid, bytes)` |
| Custom GATT | `stopServer()` | `stop()` |
| Custom GATT | `onRead`, `onWrite` streams | `clientReads`, `clientWrites` |
| Both servers | `states` | `stateChanges` |
| Message server | `send(bytes)` | `sendBytes(bytes)` |
| Message server | `received`, `clients` | `receivedMessages`, `clientEvents` |
| Message server | `readyClients` | `subscribedClientIds` |
| Field callbacks | `onRead`, `onWrite` | `readValue`, `authorizeWrite` |
| Protocol UUIDs | `service`, `receive`, `transmit`, `name` | `serviceUuid`, `clientToServerUuid`, `serverToClientUuid`, `serverNameUuid` |

For a field callback, pass either the old name or the new name. Supplying both
throws an argument error so that neither callback is silently ignored.
`startServer(serviceUuid: ..., characteristics: ...)` remains the legacy
single-service entry point; new custom servers accept a constructor `profile`
and use `start()`.

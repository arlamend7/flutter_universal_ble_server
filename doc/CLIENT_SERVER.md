# Native client/server communication

The library now implements both roles without a third-party BLE package:
Android uses BluetoothGatt, Apple uses CoreBluetooth, Windows uses WinRT, and
Linux clients use BlueZ over the system D-Bus through GIO.

The following are separate, composable layers:

| Layer | Server | Client |
| --- | --- | --- |
| Typed GATT fields | `UniversalBleServer` | `UniversalBleClient` |
| Complete messages | `BleMessageServer` | `BleMessageClient` |
| Optional admitted sessions, requests and shared state | `BleSessionServer` | `BleSessionClient` |

`BleRpcChannel` is the reusable request/reply layer used by sessions. It also works
with a custom complete-message transport. These classes provide communication,
not game rules, persistence, or automatic application identity verification.

## Platform implementation and validation

| Platform | Client backend | Server backend | Validation requirement |
| --- | --- | --- | --- |
| Android | Direct BluetoothGatt | Direct BluetoothGattServer | Example compiled; physical exchange still required |
| iOS/macOS | Direct CBCentralManager | Direct CBPeripheralManager | Examples compiled; physical exchange still required |
| Windows | Direct WinRT central | Direct WinRT GATT server | Source implemented; Windows compilation and device tests required |
| Linux | Direct BlueZ D-Bus central | Explicitly unsupported | Linux compilation and device tests required |
| Flutter Web | Explicitly unsupported | Explicitly unsupported | The standalone HTML browser client remains available |

One native central connection is owned per Flutter engine. Multiple clients on
separate devices can connect to one server, within radio/OS limits. This is not a
claim of unlimited connections or support on every adapter. Linux uses a
conservative 20-byte write limit. Windows reports state on capability checks and
device disconnection; it does not currently continuously observe radio state.

## 1. Define fields once

Put shared definitions in a Dart file imported by both applications:

```dart
import 'package:universal_ble_server/universal_ble_server.dart';

final temperature = BleFieldDefinition<int>(
  serviceUuid: '947db030-83c5-4a59-8ab1-831637027ca0',
  uuid: '947db030-83c5-4a59-8ab1-831637027ca1',
  codec: BleCodecs.uint16LittleEndian,
  access: {BleProperty.read, BleProperty.notify},
);
final protocol = BleMessageConfiguration(protocol: 'my-app', version: 1);
```

The shared definition has no server storage or authorization callbacks. Bind it
on the server to create those:

```dart
final temperatureField = temperature.bind(initialValue: 25);
final server = BleMessageServer(
  name: 'My device',
  configuration: protocol,
  additionalServices: [
    BleService(uuid: temperature.serviceUuid, fields: [temperatureField]),
  ],
);
(await server.requestPermissions()).requireCompatible();
await server.start();
await server.updateStoredValue(temperatureField, 30, notify: true);
```

`server.gatt` operates custom fields under the same native server. Use the
message wrapper's start/stop/dispose methods for lifecycle. A custom GATT-only
application can still use `UniversalBleServer` directly.

`BleJsonCodec<T>` supports custom JSON field types with `toJson` and `fromJson`
functions. GATT values remain limited to 512 bytes, and individual notifications
and writes must fit the peer's payload limit. Use framed messages for larger data.

## 2. Discover and connect

For a finite scan with automatic permission requests and cleanup:

```dart
final devices = await client.discover();
// Present the results, then: await client.connect(selectedDevice.id);
```

The default duration is three seconds and at most 256 unique devices are kept.
Duplicate advertisements update their existing entry. Set `maxResults` up to
1024, `duration`, or `requestPermissions: false` if needed. `stopScan()` completes
the pending discovery early; disposal cancels it. Concurrent `discover()` calls
on one client fail with `BleErrorCode.busy`.

For live results, keep the explicit scan API below:


On a different device:

```dart
final client = BleMessageClient(configuration: protocol);
final scanSubscription = client.discoveredServers.listen((device) {
  print('${device.id}: ${device.name}');
  // Show results and let the user select a device.
});
requireClientReady(await client.requestPermissions());
await client.startScan(); // Stops automatically after ten seconds by default.
```

Pass the selected result's `id` to `await client.connect(id)`. No Bluetooth
settings pairing step substitutes for application connection and discovery.
Discovery uses the service UUID; the advertised name may be absent or shortened.
The logical server name is available as `client.serverName` after setup.

`connect()` finishes after GATT discovery, protocol verification and message
subscription. `stateChanges` exposes disconnected, connecting, discovering,
subscribing, ready, reconnecting and disposed. Subscribe before connecting.
Raw `UniversalBleClient` reaches ready after discovery and any restored watches.

The message metadata characteristic (default UUID ending `e4`) contains framing
version, application protocol/version, frame size, and maximum message size.
Clients require an exact shared configuration before readiness. An older server
without this characteristic needs upgrading to use the new Dart message client;
the original HTML client and frame format remain compatible with new servers.
Metadata is a contract check, not an authentication mechanism or a full schema
for discovering arbitrary Dart types.

## 3. Read, write and watch

With the connected message client, exported convenience extensions provide typed GATT directly. The existing `client` accessor remains available:

```dart
final updates = await client.watchValue(temperature);
final temperatureSubscription = updates.listen((value) => print(value));
final initial = await client.readValue(temperature);
print(initial);
```

For a field declaring write access, use `writeValue(definition, value)`.
`watchValues([definitionA, definitionB])` combines changes into one stream of
`BleFieldUpdate`, carrying the field definition and decoded value. Native
subscriptions are reference-counted; cancelling the last listener disables the
subscription. Always listen to the stream returned by `watchValue` and cancel it
when done. Notifications arriving during native subscription setup are buffered
for that returned stream. Reads and notifications are not a transactional
snapshot: use the revisioned shared-state layer when ordering matters.

## 4. Exchange complete messages

Server:

```dart
final incoming = server.receivedMessages.listen((message) {
  print('${message.clientId}: ${message.text}');
});
await server.sendText('Hello everyone');
// Add clientId: selectedClientId to target one subscriber.
```

Client:

```dart
final messages = client.receivedText.listen(print);
await client.sendText('Hello server');
await client.sendJson({'type': 'ready', 'value': true});
```

`sendBytes`, `receivedMessages` and JSON helpers cover binary/text/JSON data.
Only decode text or JSON when the sender used that format. JSON parse failures
are delivered as stream errors. Both sides automatically fragment and reassemble
complete messages. No subscriber is an error. A completed send is transport
completion, not proof the application processed the data.

Custom configuration controls UUIDs, frame size and message size. The
`configuration` argument is authoritative when supplied; otherwise legacy server
`frameBytes`/`maxMessageBytes` arguments create the configuration. Start with
20-byte frames. Size settings are validated, not automatically negotiated upward.
`maxIncomingAssemblies` bounds concurrent partial messages; the old `maxClients`
name remains an alias for this limit, not a connection limit.

## 5. Optional sessions and requests

Create session wrappers before connecting clients. Use them instead of sending
arbitrary raw messages on that same message channel: the payload is now a JSON
RPC envelope, and both peers must use the session protocol.

Server:

```dart
final sessions = BleSessionServer(
  server: server,
  applicationProtocol: 'my-session-app',
  maxSessions: 2,
  handlers: {
    'echo': (session, method, payload) => {
      'sessionId': session.id,
      'received': payload,
    },
  },
  onAcknowledgedMessage: (session, payload) => {'received': payload},
);
```

Client, after constructing the message client and before calling `connect`:

```dart
final session = BleSessionClient(
  client: client,
  applicationProtocol: 'my-session-app',
);
```

After `connect`, await `session.open()` before application requests:

```dart
final reply = await session.request('echo', {'hello': 'world'});
final receipt = await session.sendAcknowledged({'ready': true});
```

The server can call `requestClient(sessionId, method, payload)` when the client
provides a `handler`. `requestTyped` maps the reply into an application type.
`sendAcknowledged` resolves only when the remote `$message` handler completes.
It does not promise disk persistence or any effect outside that handler.

`requestTimeout`, `handlerTimeout`, and `maxPendingRequests` are configurable.
Timeouts do not cancel application futures; keep irreversible effects under your
own transaction/idempotency rules. Disconnecting fails outstanding requests.

Retries default to zero. `retries: 1` retries a timeout using the same command ID.
In-progress duplicates share one execution; completed duplicates receive the
cached result, and conflicting payloads with the same ID are rejected. For an
uncertain result across reconnects, explicitly reuse `requestId: 'command-42'`
with the exact same method and payload. Do not reuse IDs for different actions.
Commands are not automatically replayed after reconnecting.

Deduplication is bounded, in-memory and scoped to a session. Server settings
`requestCacheCapacity` (default 256) and `requestCacheRetention` (five minutes)
control its window. A full unexpired cache rejects new commands instead of
silently weakening deduplication. After expiry, restart or explicit session
removal, the library cannot prevent an old command from executing again.

## 6. Admission, authorization and resumption

- `authenticate(credentials)` returns a stable application principal, or null to
  reject the session. Without it, sessions are anonymous.
- `authorize(session, method, payload)` gates initial request execution and
  snapshot access. Duplicate replies use the result of the original execution;
  revoke a session to invalidate its active channel.
- `sessionForClient(clientId)` lets field authorization hooks consult admission.
  Raw fields and raw message listeners are NOT automatically protected by the
  session layer; configure their hooks separately if exposed.
- `maxSessions` bounds retained admitted sessions, including disconnected sessions
  reserved for resumption. `maxPendingConnections` allows a bounded number of
  additional unauthenticated protocol channels. Neither changes OS link limits.
- `removeSession(id)` revokes a logical session, not necessarily the physical link.
  A new admission still requires authentication; removal is not a permanent ban.
- Resume tokens survive reconnects in the `BleSessionClient` object. New client
  objects may be given a saved token. Authentication runs again, and the principal
  must match. Tokens expire after `sessionRetention` offline (five minutes).
- An expired or invalid token fails explicitly. Clear it only when intentionally
  creating a new session. No automatic identity reset is performed.

Tokens are bearer secrets. This library does not encrypt the application channel
or persist credentials. Do not log tokens. Configure an appropriate authenticated
transport/application protocol before sending secrets. OS encrypted read/write
field permissions remain available, but are not a promise of encrypted message
notifications. The demo intentionally uses anonymous test sessions.

## 7. Reconnection and shared state

Opt into bounded reconnects through the underlying client:

```dart
final client = BleMessageClient(
  configuration: protocol,
  client: UniversalBleClient(
    reconnect: BleReconnectPolicy(attempts: 3, delay: Duration(seconds: 2)),
  ),
);
```

Watches are restored after rediscovery; message metadata is rechecked. Manual
disconnection or disposal cancels retries. This only runs while the app/isolate
can execute; no background service, background guarantee, or persistent host
migration is supplied.

`BleSessionClient` reopens its session after message readiness and requests a
fresh snapshot. The server retains state with:

```dart
await sessions.updateSharedState({'phase': 'waiting', 'players': 2});
```

The client observes `session.sharedState`, inspects `session.currentState`, or
calls `refreshState()` explicitly. Snapshots carry a revision; older snapshots
cannot overwrite newer ones. Each event carries the full snapshot, so an
intermediate lost update does not corrupt later snapshots. Losing the final event
still requires refresh/reconnect: there is no automatic periodic polling.

Use `projectState(session, state)` for per-session views and `authorize` for
snapshot access. State is retained even if sending fails; delivery failures go
to `errors`. Projection/authorization callbacks have bounded waits. State and
sessions are in-memory; persistence and application mutations remain app-owned.

## 8. Diagnostics and cleanup

`BleMessageServer.peers` / `peerChanges` report current subscription information
and the last known notification payload limit where the native backend reports
it. Physical connection state is nullable on platforms without those events.
`subscribedClientIds` specifically identifies message recipients.

Client/message/session `diagnostics` report operation counters, frames and queue
sizes without automatically recording payloads. User-provided exception objects
may contain application data: control what you log. `errors` streams are separate
from futures returned by calls; handle both. New client/session errors use
`BleException`/`BleErrorCode`; legacy server errors retain their existing types.

Cancel your subscriptions. Dispose the session wrapper before its message
client/server; session wrappers do not own the underlying transport lifecycle.
`stop()` on a server permits restarting; `dispose()` permanently closes it.
All native operations require explicit error handling even after support checks.

## Permissions and manual acceptance

Android clients need SCAN and CONNECT on Android 12+, and fine location on older
versions (declared by the plugin). The scanning permission declares
`neverForLocation`; use this library for BLE communication rather than location
inference. Older Android devices may require location services enabled to scan.
Server-only permission requests still request only their own role's permissions.

Apple clients use the example's Bluetooth usage descriptions and macOS Bluetooth
sandbox entitlement. Windows packaged apps need the Bluetooth capability. Linux
needs BlueZ running, a powered adapter, and system D-Bus/PolicyKit authorization;
`requestPermissions()` cannot grant OS policy or run privileged commands.

Run the example on two or three physical devices, choose “Client + server,” host
on one and scan/connect on the others. Test initial reads, broadcasts, private
replies, two concurrent requests, disconnect/reconnect, denied permission,
Bluetooth off, metadata mismatch and oversized transfers. See
[HARDWARE_TESTING.md](HARDWARE_TESTING.md). Mock tests do not validate radios.

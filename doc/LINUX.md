# Linux and Raspberry Pi BLE hosting

The Linux backend uses BlueZ's system D-Bus API through GLib/GIO directly. It
implements a GATT peripheral/server and independently owned central/client
sessions. No third-party BLE plugin or command-line Bluetooth wrapper is used.

## Requirements

- A Linux system running BlueZ, with an enabled BLE adapter exposing both
  `org.bluez.GattManager1` and `org.bluez.LEAdvertisingManager1` for hosting.
- A Flutter Linux runner supported by your CPU architecture and OS. A Raspberry
  Pi needs a compatible Linux Flutter environment and BLE controller; this does
  not promise support on every Pi model, OS image or USB adapter. The supplied
  desktop example uses GTK and needs a graphical session.
- Build dependencies: a C++17 compiler, CMake/Ninja, GTK development headers,
  `pkg-config`, and GLib/GIO including `gio-unix-2.0`. On Debian/Ubuntu these are
  supplied by `build-essential cmake ninja-build libgtk-3-dev libglib2.0-dev
  pkg-config`. Runtime BlueZ and the system D-Bus service must be available.
- The application user must be permitted by the distribution's D-Bus/BlueZ
  policy to register applications and advertisements and connect to devices.
  `requestPermissions()` checks availability; Linux does not provide the mobile
  permission dialog. The library does not change system policy or enable radios.

## Host using the existing API

```dart
final server = BleMessageServer(name: 'Pi hub');
final errors = server.errors.listen(print);
final incoming = server.receivedMessages.listen((message) async {
  try {
    await server.replyText(message, 'Received: ${message.text}');
  } catch (error) {
    print(error);
  }
});
await server.startWithPermissions();

// Broadcast: await server.sendText('Round starts now');
// Target one subscriber: await server.sendText('Your turn', clientId: id);
// Shutdown: cancel incoming/errors, then await server.dispose().
```

Typed fields, dynamic read hooks, write authorization, framed messages and session
layers use the existing Dart implementation. Remote reads/writes include the
BlueZ device path as their connection-local client ID. Encrypted read/write
fields map to BlueZ's encryption flags; pairing is still managed by BlueZ.

Names are advertised through `LocalName`. If BlueZ rejects the advertisement's
size, the default retries without the name. Set `requireAdvertisedName: true` to
fail instead. Message clients can still read the full logical server name from
GATT. The backend selects a compatible powered adapter automatically; explicit
adapter selection is not exposed in this version.

## Connect to multiple peripherals

Use one server with several subscribed clients for a game lobby or a shared
chat. Use several client instances when one host needs to connect to separate
devices, such as a Pi collecting readings from multiple sensors. These are
different roles; adding a group wrapper alone cannot add native connections.

Each client owns one remote connection. Keeping this ownership explicit makes
disconnects, errors, subscriptions and retries independent. A send-to-all action
can compose these clients and report failures per device, as the hub example
does. It does not provide an atomic broadcast across peripherals.

Create one client per remote device. Existing constructors and methods remain
unchanged. Each Linux instance owns separate native channels, a private D-Bus
connection, operation state, discovery filters and notification subscriptions.

```dart
final first = BleMessageClient();
final second = BleMessageClient();

await Future.wait([
  first.connect(firstDevice.id),
  second.connect(secondDevice.id),
]);
await first.sendText('Only device one');
await second.sendText('Only device two');

await first.dispose(); // Device two remains usable.
await second.sendText('Still connected');
await second.dispose();
```

Discover/select the devices first and subscribe to each client's messages/errors
before connecting. Use `UniversalBleClient` instead for other devices' custom
GATT profiles; `BleMessageClient` requires matching library protocol metadata.

A physical device is reserved to one client instance in this Flutter engine
until that instance disconnects/disposes; a second owner receives `busy`. This
prevents one session's cleanup from disconnecting another session to that device.
The factory bounds allocated client sessions to 16 (including scan-only clients).
That is a software resource limit, **not a guarantee of 16 radio connections**.
Controllers and BlueZ can impose smaller limits. Dispose clients when finished.
Linux central writes retain the conservative 20-byte limit; complete messages
handle fragmentation automatically.

This expansion applies to **Linux**. The other native backends still allow one
remote client connection per Flutter engine. Web clients already own individual
browser transports, subject to browser/device restrictions. No Bluetooth Classic
transport is introduced.

## Private notifications and lifecycle

The server uses BlueZ's optional `AcquireNotify` method with a separate packet
socket per device. This is necessary because ordinary `StartNotify()` does not
identify the subscriber. Targeted messages never fall back to broadcasts.
A BlueZ implementation supporting server `AcquireNotify` and per-device options
is required for notifications; the backend explicitly rejects the anonymous
notification path. See the [BlueZ characteristic API](https://github.com/bluez/bluez/blob/master/doc/org.bluez.GattCharacteristic.rst).

- Socket writes preserve packet boundaries and enforce each peer's MTU.
- Full sockets wait for writability, with a five-second deadline and a bounded
  queue. Disconnect, unsubscribe, stop and timeout fail pending sends.
- Writes/reads call the Dart request handler with a native five-second deadline.
  Prepared/reliable writes are rejected; whole-value writes remain the contract.
- Failed registration rolls back exported objects and the private bus owner.
  Stopping closes its registration, subscriptions, sockets and pending requests.
- Only the BlueZ service owner can invoke exported GATT methods. Adapter power
  loss or BlueZ service disappearance emits a server error and releases resources.
- Server client events describe subscriptions, not a complete inventory of
  physical links. `connectionEvents` remains false for this backend.
- Server profiles are bounded to 64 services/256 fields and notifications to
  16 subscribers per field. Incoming Dart request/notification queues are bounded
  to 128 entries. These limits do not alter hardware capacity.

## Run the examples and tests

On Linux run `flutter run -d linux` inside `example`:

1. **Simple chat** demonstrates Linux hosting, private messages and broadcast.
2. **Linux hub: connect to multiple hosts** connects to two or more other devices
   running **Simple chat → Host chat**. Send to one, send to all, then disconnect
   one and verify that the others remain usable.

Native protocol tests: `test/linux/run_tests.sh` (requires GLib/GIO, `pkg-config`,
C++17 and `dbus-daemon`). They compile the production backend against a small
Flutter-channel test adapter and run it against a fake BlueZ service on a real
private D-Bus daemon. Linux CI also builds the real Flutter plugin.

The tests can run on macOS using `brew install glib dbus pkgconf`. macOS lacks
Unix `SOCK_SEQPACKET`, so that test configuration uses datagram sockets, maps
buffer-full errors and invokes peer-removal explicitly instead of claiming to
validate Linux HUP behavior. Linux CI uses the production packet socket and
actual HUP watcher. Neither configuration tests a Bluetooth controller.

Local macOS runs have also encountered an intermittent GLib `gdbus` worker
socket-poll warning during cleanup; the cause remains unresolved despite a
subsequent passing run. See the [validation record](VALIDATION.md). A successful
macOS run is not a substitute for the Linux CI build and hardware acceptance.

Physical acceptance remains required on your chosen Pi/Linux hardware. Record
BlueZ/kernel versions, controller/firmware, Flutter runner and OS architecture.
Run the existing [hardware acceptance](HARDWARE_TESTING.md) with the Linux host,
then test the hub with two physical peripherals: concurrent traffic, independent
subscription cancellation, disconnect/reconnect, disposing one client, full-size
messages, radio off/on, BlueZ restart, oversized advertising names and prolonged
operation. Keep unrun cases marked **NOT RUN**.

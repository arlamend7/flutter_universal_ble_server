# Bidirectional BLE message protocol v1

This is a custom GATT protocol, not Bluetooth Classic, a serial-port profile, or
an implementation of Nordic UART. A compatible central must use these UUIDs and
this frame format. The lower-level UniversalBleServer API remains available for
other protocols.

## GATT layout

| Item | UUID | Client operation |
| --- | --- | --- |
| Service | `d973f2e0-b19e-11ee-a506-0242ac120002` | Scan for this service |
| RX | `d973f2e1-b19e-11ee-a506-0242ac120002` | Write **with response**, offset zero |
| TX | `d973f2e2-b19e-11ee-a506-0242ac120002` | Subscribe to notifications |
| NAME | `d973f2e3-b19e-11ee-a506-0242ac120002` | Read UTF-8 logical server name |
| METADATA | `d973f2e4-b19e-11ee-a506-0242ac120002` | Read JSON protocol/version/frame-size/message-limit contract |

The Dart client connects, discovers the service, verifies METADATA, reads NAME
and subscribes to TX. METADATA is additive: the original browser client may ignore
it, but new Dart message clients require it. Custom UUIDs and shared settings are
supported through `BleMessageConfiguration`. See [client/server guide](CLIENT_SERVER.md).
The optional session/RPC layer is described there; ordinary text clients must not
send raw text to an application expecting RPC envelopes.
It can then write frames to RX and receive frames on TX. Notifications are
sufficient for this transport; indications are not exposed in this release.

NAME is authoritative for the application name. Advertisement names may be
omitted, shortened or cached by the client/OS. Scan by service UUID, not just name.
On Windows, an application-specific local advertisement name is unavailable.
On Android, opt into temporary system adapter renaming to advertise a custom
name; restoration after process death or permission loss cannot be guaranteed.

## Frame layout

All multi-byte integers use little-endian byte order. Default maximum frame
length is **20 bytes**, including the header. Application payload is 13 bytes per
frame at this default, even if the OS negotiates a larger MTU.

| Offset | Length | Meaning |
| --- | --- | --- |
| 0 | 1 | Version, exactly `01` |
| 1 | 2 | Message ID, unsigned 16-bit, wraps after 65535 |
| 3 | 2 | Fragment index, zero-based |
| 5 | 2 | Total fragment count, at least 1 |
| 7 | remaining | Payload bytes |

For example, UTF-8 `Oi` with message ID 1 is one frame:

```text
01 01 00 00 00 01 00 4f 69
```

A 30-byte message uses three default frames: payload lengths 13, 13 and 4; indices
0, 1 and 2; the same message ID and count 3 in each header. Empty messages use
one seven-byte frame. Empty fragments in a multi-fragment message are invalid.
The application payload can be binary; text helpers use UTF-8.

Only one message is assembled per client at a time. Fragments must arrive in
order without duplicates and messages must not interleave. Maximum assembled
size defaults to **65535 bytes**. Default assembly deadline is **10 seconds**
from the first fragment. Incomplete messages expire and release their memory.
The server bounds concurrent incoming assemblies (16 by default). Increase the
deadline when transferring large messages over slow links; 65535 bytes is a
storage limit, not a promise that this size transfers within ten seconds.

`frameBytes` can be configured from 8 to 512, but both peers must agree and the
value must fit every target's actual notification/write payload limit. The server
checks native notification limits; it does not silently truncate or auto-negotiate
an application frame size. Use 20 unless you control both ends.

## Delivery and errors

- `receivedMessages` emits **only complete messages**, identifying the client.
- `sendBytes`/`sendText` serialize complete messages, so concurrent calls cannot
  interleave their fragments. Passing `clientId` targets one TX subscriber;
  omitting it snapshots all current TX subscribers.
- A client joining mid-message does not receive a suffix. Disconnecting,
  unsubscribing or stopping interrupts a send. Some frames may already have
  reached other clients when an error occurs; broadcast is not atomic.
- A native Android notification timeout closes the server generation; restart
  the server before sending again. This prevents late callbacks from completing
  the wrong message.
- No subscribed clients produces an error in the message API. The low-level
  `sendNotification` API retains no-op behavior when its broadcast has no subscribers.
- Native receipt of an RX frame is acknowledged by ATT. It is **not** an
  acknowledgement that the whole application message was assembled/processed.
  Invalid sequences report an error and discard the incomplete message.
- TX uses notifications, which do not provide application delivery confirmation.
  Raw message sends have no automatic retries. The optional RPC/session layer
  adds bounded acknowledgements, deduplication and explicit retry settings; it
  does not change the underlying notification delivery guarantees.
- Message IDs only identify fragments; they do not authenticate a sender or
  prevent replay. This protocol supplies no application encryption.
- Actual connection/disconnection events are exposed on Android. On Apple and
  Windows, the portable message API uses subscription/unsubscription events to
  describe readiness. Do not interpret unsubscribe as proof of radio disconnect.

## Compatible browser client

`example/ble_client.html` is a working client using Web Bluetooth. Serve the
example directory on localhost, then open it in a Web-Bluetooth-capable desktop
Chrome or Edge browser:

```sh
cd example
python3 -m http.server 8000
```

Open `http://localhost:8000/ble_client.html`. Run the Flutter server on a **different
physical device**, start it, click Connect in the browser, and choose it. The
browser reads NAME, subscribes to TX, receives complete messages and sends framed
UTF-8 messages to RX. It deliberately uses the baseline 20-byte frame size.
Browser/hardware support varies; localhost is a secure context, whereas a plain
HTTP LAN address is not. A page acting as a client does not make Web a supported
server platform.

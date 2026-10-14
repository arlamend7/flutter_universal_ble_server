# Hardware acceptance matrix

Status: pending execution on physical devices. Do not mark a platform validated
solely because Dart tests or a native build passes.

For each supported Android/iOS/macOS/Windows server, test with both an Android and
an iOS central where possible. Record OS version, device/adapter, driver, app build
and results. Use a BLE inspector or your own central implementing the same UUIDs.

1. Start with Bluetooth off, deny permission, grant permission, start successfully.
   Verify clear failures and that a subsequent retry works.
2. Verify configured-name discovery on Apple foreground and Android (opt in to
   adapter renaming, then verify restoration on stop). Verify Windows warns and
   NAME remains readable. Test strict-name rejection where unsupported.
   Discover the advertised service. In a custom two-service profile, connect and
   enumerate both services and their characteristics. Verify unrelated services are not advertised by the plugin.
3. Read NAME and verify the configured UTF-8 name. Send the protocol frame
   `01 01 00 00 00 01 00 4f 69` to RX with response; verify the example displays
   `Oi` with the originating client ID. A two-byte raw write must be rejected.
4. Subscribe to TX, send text through the example UI, reassemble frames and
   verify the complete UTF-8 payload. Unsubscribe and verify sends to that client
   fail. Repeat with a message longer than 20 bytes and a multibyte emoji.
5. Connect two centrals; subscribe only one, then both. Check routing, notification
   ordering, individual MTU limits and disconnect cleanup.
6. Read values larger than the negotiated ATT payload using offset reads; verify
   no duplicated prefixes or truncated data. Invalid offsets must fail.
7. Send prepared writes, nonzero-offset writes and multi-write batches where the
   OS exposes them; verify explicit rejection and unchanged data.
8. Reject a write in a Dart hook; throw from a hook; delay a hook beyond five
   seconds. Verify an ATT error, no commit and recovery for the next request.
9. Stop while starting, while receiving a request and while sending. Toggle
   Bluetooth off while active. Restart repeatedly and verify no stale events,
   duplicate advertisements, leaked connections or completed old writes.
10. Test encrypted-read/write fields with an unpaired and paired central. Verify
    pairing/encryption enforcement. Do not infer notification security from this.
11. Exercise maximum-length and oversized notifications. If framing is used,
    verify missing, duplicate, reordered, oversized and expired fragments.
12. Test release builds as well as debug. Separately test foreground/background
    transitions and process termination; background persistence is not guaranteed.

| Server | Build | Physical radio / centrals | Result |
| --- | --- | --- | --- |
| Android | Debug example build passed locally | Not yet tested | Pending |
| iOS | Unsigned debug example build passed locally | Not yet tested | Pending |
| macOS | Debug example build passed locally | Not yet tested | Pending |
| Windows | Windows CI required | Not yet tested | Pending |

Web and Linux intentionally report unsupported peripheral capability.

## Native clients and optional sessions

Run the combined client/server example on one host and two separate clients.
Test each Android, iOS, macOS, Windows and Linux client against a supported server.
Windows/Linux client compilation must pass before conducting acceptance tests.
The Linux role is client only. Flutter Web uses the separate HTML client and
cannot run the native client/session demo.

1. Scan by service UUID, choose a device, connect and wait for message readiness.
   Verify the logical server name even when the advertised name is absent.
   Reject mismatched protocol metadata before accepting application messages.
2. Read the counter, watch it on both clients, request an increment from one and
   verify the field update, shared-state revision and private request reply.
   Cancel one field watcher and ensure the other still receives updates.
3. Send a private server request to each client and verify only its recipient
   responds. Exercise concurrent requests, UTF-8 text, binary values and messages
   larger than the default 20-byte ATT payload. Test the configured maximum.
4. Abruptly disconnect one client during a request. Restore connectivity; verify
   bounded retries, restored field/message subscriptions, session resumption and
   snapshot refresh. An intentional Stop / reset must cancel automatic retries.
5. With a test harness, discard a response after executing its handler. Retry the
   same request ID within cache retention and confirm no duplicate side effect.
   Reuse the ID with different content and verify rejection. Repeat after resume.
   Test cache capacity/expiry; this does not establish durable exactly-once work.
6. Configure authentication/authorization hooks: reject invalid credentials,
   excess admissions and another principal's resume token. Verify per-session
   projected state does not expose private fields. A slow authorization callback
   must not invoke the application handler after its deadline.
7. Deny/revoke permission, disable Bluetooth during scanning and sending, remove
   the adapter where supported, then retry. Confirm errors and bounded waits.
   On Windows, explicitly re-check adapter state; there is no continuous radio
   state stream. On Linux, test both denied and allowed system D-Bus policies.
8. Repeat disconnect, stop, dispose and restart cycles. Check that old callbacks,
   subscriptions and queued writes cannot affect a later connection. Include
   simultaneous connection attempts and disposal during discovery.

| Native client | Local compile result | Physical acceptance |
| --- | --- | --- |
| Android | Debug example passed | Pending |
| iOS | Unsigned debug example passed | Pending |
| macOS | Debug example passed | Pending |
| Windows | Requires Windows runner | Pending |
| Linux | Requires Linux runner | Pending |

Record device/OS/driver, client and server versions, configuration, observed MTU,
foreground/background state and each result. These checks are not yet executed.

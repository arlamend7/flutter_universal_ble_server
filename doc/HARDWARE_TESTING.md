# Hardware acceptance matrix

Status: pending execution on physical devices. Do not mark a platform validated
solely because Dart tests or a native build passes.

## Run the prepared device tests

The native host and test runner use the real platform adapters. They are separate
from the simulated regression tests. Start with **two physical devices**: this
Mac can be the host and an Android phone or iPhone can be the client. An iOS
simulator cannot substitute for the second BLE radio. Keep both apps unlocked
and in the foreground, and grant Bluetooth permission when prompted.

From `example/`, list device IDs with `flutter devices`, then start the host:

For Apple hosts/clients, first select the dependency manager as described in
[the example setup](../example/README.md#apple-dependency-managers). This checkout
has been tested with CocoaPods; SwiftPM needs the package-named checkout described
there.

```sh
flutter run -d macos -t lib/acceptance_host.dart --dart-define=BLE_TEST_RUN=local
```

Press **Start host** and wait for **READY**. In another terminal, from `example/`,
run the client suite (replace `PHONE_ID` with the physical device ID):

```sh
flutter test integration_test/ble_acceptance_test.dart -d PHONE_ID \
  --dart-define=BLE_RUN_HARDWARE=true --dart-define=BLE_TEST_RUN=local
```

iOS devices require your development signing configuration. Both devices must
use the same source revision and `BLE_TEST_RUN`. The isolated test service avoids
connecting to the normal chat demo. If multiple test hosts are discovered, the
test fails rather than choosing arbitrarily; use the printed ID with
`--dart-define=BLE_TEST_PEER=SERVER_ID` to select one. Only use trusted devices:
the test host intentionally allows field writes, echoes and broadcasts.

The runner checks:

- Discovery, matching protocol metadata and the logical configured server name.
- Exact UTF-8 and binary round trips, including 32-, 512- and 4,096-byte messages.
- Rejection of 65,536-byte messages and successful communication afterward.
- Private replies, broadcasts, typed reads/writes, notifications and watch cancellation.
- Three intentional disconnect/reconnect cycles with restored message delivery.
- Unexpected asynchronous errors and private responses delivered to the wrong client.

All hardware tests are skipped unless `BLE_RUN_HARDWARE=true` is provided. A skip
is **not** a pass. The test run has a 15-minute deadline; individual message
exchanges have a three-minute deadline. A failure is useful evidence, not a
reason to bypass the assertion. Host errors appear as **FAIL** in its log.

### One host and two clients

Run the client command on **two separate physical client devices**, adding these
options to both commands:

```sh
--dart-define=BLE_TEST_CLIENTS=2 --dart-define=BLE_TEST_FIELDS=false
```

The clients wait at a start barrier until both arrive. Each client checks its own
private replies and receives the other client's broadcast before either starts
disconnecting. Random per-run client tokens expose accidental private-message
delivery to the wrong client. Shared-field writes are disabled in this mode to
avoid two independent test scripts racing over the same value; validate fields
with the single-client suite first. Start both runners within three minutes.
Use separate copies of the same revision for concurrent native builds so their
generated build files do not collide. Both client runs must pass.

### Largest payload and slower devices

Add `--dart-define=BLE_TEST_MAX_BYTES=65535` to the client command to exercise the
full configured message limit. The default 20-byte frames leave 13 payload bytes
per frame, so this is over 5,000 frames **in each direction**. Maximum length is
not a guarantee of delivery within the default ten-second assembly deadline.

First test the defaults. If a slower device requires a longer deadline, repeat
with `--dart-define=BLE_ASSEMBLY_SECONDS=180` on **both** host and client, and
record this configuration separately. Do not report that result as a pass with
the defaults. Increasing an assembly deadline does not increase the wire limit.

### Denied permission and Bluetooth off

These checks do not need a running host. Run the client command with one of:

```sh
--dart-define=BLE_EXPECT_STATE=unauthorized
--dart-define=BLE_EXPECT_STATE=poweredOff
```

For `unauthorized`, deny the permission prompt or revoke the app's Bluetooth
permission in system settings first. For `poweredOff`, grant permission and
disable Bluetooth in system settings first. The test verifies the reported state
and the typed discovery error. Restore permission/power and rerun the normal
suite to check recovery. The tests do not change system settings for you.

Abrupt radio loss **during** a connection, OS permission revocation while active,
pairing, background behavior and long-duration stability still require the
manual checks below. Intentional reconnect tests do not establish automatic
recovery after radio loss. Simulated fault tests cover Dart behavior only.

### Record results and API review

Copy [the results template](ACCEPTANCE_RESULTS.md) for each device combination.
Keep the client output and host log. Record failures and skipped scenarios as
such, including the exact configuration, rather than marking the platform passed
from one happy-path run.

Before declaring the API stable, integrate the ordinary chat and session-counter
examples into a separate application using only public imports. Review creation,
permissions, selection, send/receive, fields and disposal with an application
developer. Record any naming or lifecycle changes needed. Automated tests cannot
establish usability, nor promise that future API changes will never be needed.

## Manual acceptance

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
| Windows | CI debug build passed for d537b80 | Not yet tested | Pending |

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
| Windows | CI debug build passed for d537b80 | Pending |
| Linux | CI debug build passed for d537b80 | Pending |

Record device/OS/driver, client and server versions, configuration, observed MTU,
foreground/background state and each result. These checks are not yet executed.

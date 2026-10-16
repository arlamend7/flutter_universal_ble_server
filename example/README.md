# BLE client and server example

Run `flutter run` from this directory on two or three physical devices.

For automated tests against a physical peer, use the separate
[acceptance host and device runner](../doc/HARDWARE_TESTING.md#run-the-prepared-device-tests).
It covers message integrity, routing, fields and reconnection; it is opt-in and
does not run as part of the ordinary example.

## Start here: simple chat

Choose **Simple chat: host, connect and send** on each device. Choose **Host chat**
on one device; on the others choose **Discover chats**, then select **Connect**.
The host can send to everyone or one selected client. Client messages can be
forwarded to the other clients using the host's relay switch. **Stop / reset**
releases resources. The implementation is in [chat_demo.dart](lib/chat_demo.dart).

To join from Flutter Web, run `flutter run -d chrome`, open **Simple chat**, and
press **Choose BLE device**, then **Connect**. Host on a native device running the
same chat screen. The browser must support Web Bluetooth on HTTPS or localhost.
Web hosting is disabled. See [the web guide](../doc/WEB.md).

The scan is finite, handles permission requests and returns an empty list when no
host is found. Names may be absent in advertisements; the full logical name is
read after connecting. Errors are shown in the log. Keep the apps in foreground.

## Linux / Raspberry Pi hub

On a compatible Linux Flutter runner, **Simple chat** can host through BlueZ.
**Linux hub: connect to multiple hosts** connects independently to other devices
running Simple chat hosts. It includes per-host send, send-to-all and independent
disconnect controls. See [Linux requirements and tests](../doc/LINUX.md).

## Fields, requests and sessions

1. Open **Client + server: fields, messages and sessions** on each device.
2. On one device, enter a name and choose **Host server**. Accept Bluetooth
   permission and enable Bluetooth if needed.
3. On the others, choose **Scan for servers**, grant permission, and **Connect**
   to the selected result. Advertising names may differ; the logical server name
   is read after connecting.
4. **Request increment** sends a request to the host. The host changes its typed
   counter, notifies field subscribers, updates shared state and replies.
5. **Send and wait for reply** exchanges an acknowledged application message.
   On the host, it sends an individual request to each admitted client.
6. Interrupt a client connection and restore it to test the bounded reconnect
   policy. The session resumes and fetches a fresh snapshot. Use **Stop / reset**
   to intentionally disconnect and release resources.

The demo admits two anonymous sessions, has no application authentication or
encryption, and keeps data only in memory. Use trusted test devices. It does not
promise background operation. A disconnected session temporarily retains its
slot for resumption. The app is an integration example, not a game engine.

The home screen also retains **Original message server / browser client**. Use
that screen with `ble_client.html`; the browser example speaks raw messages,
whereas the shared-counter screen uses session/RPC envelopes.

For setup, API examples and limitations see [the guide](../doc/CLIENT_SERVER.md).
Windows/Linux builds and physical radio acceptance remain separate validation.
The shared-counter screen retains its native discovery UI; use Simple chat for
Flutter Web. The standalone HTML client still pairs with the original
message-server screen and uses a different protocol from Simple chat.

## Apple dependency managers

The example inherits your Flutter SDK's dependency-manager setting. Its pubspec
does not use `flutter.config`, which Flutter 3.32 does not recognize. CI selects
CocoaPods and Swift Package Manager explicitly in separate jobs.

For CocoaPods, run `flutter config --no-enable-swift-package-manager` before
building or running this example on Apple platforms. This changes Flutter's
global setting; restore it with `flutter config --enable-swift-package-manager`
when finished if it was previously enabled.

For SwiftPM, use a checkout directory named `universal_ble_server`, run
`flutter config --enable-swift-package-manager`, and rebuild. Flutter 3.47.5's
local-path integration encountered a package-identity mismatch in a checkout
named `flutter_universal_ble_server`. Both managers use the same plugin source
files. Do not edit Flutter-generated manifests.

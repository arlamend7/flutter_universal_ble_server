# BLE client and server example

Run `flutter run` from this directory on two or three physical devices.

## Start here: simple chat

Choose **Simple chat: host, connect and send** on each device. Choose **Host chat**
on one device; on the others choose **Discover chats**, then select **Connect**.
The host can send to everyone or one selected client. Client messages can be
forwarded to the other clients using the host's relay switch. **Stop / reset**
releases resources. The implementation is in [chat_demo.dart](lib/chat_demo.dart).

The scan is finite, handles permission requests and returns an empty list when no
host is found. Names may be absent in advertisements; the full logical name is
read after connecting. Errors are shown in the log. Keep the apps in foreground.

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
Flutter Web does not implement the native client; use the standalone HTML client
in a compatible browser to test the original message-server screen.

## Apple dependency managers

This example explicitly uses CocoaPods so it works when the checkout directory
is named `flutter_universal_ble_server`. Flutter 3.47.5's SwiftPM local-path
integration encountered a package-identity mismatch with that directory name.
The plugin also supplies SwiftPM manifests and the same source files for both
managers. To exercise SwiftPM, use a checkout directory named
`universal_ble_server`, set `flutter.config.enable-swift-package-manager: true`
in this example's pubspec, and rebuild. Do not edit Flutter-generated manifests.

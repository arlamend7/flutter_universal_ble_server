# Universal BLE Server

A Flutter plugin that exposes a cross-platform Bluetooth Low Energy (BLE) GATT
server with AES encrypted communication. The plugin supports Android, iOS,
macOS, Windows and provides a stub implementation for the web where peripheral
mode is not available.

## Features

* Start and stop a GATT server with a dynamic service and characteristics.
* Receive read and write requests via streams.
* Send notifications to connected centrals.
* All characteristic values are encrypted using AES before transport.

See the [example](example/lib/main.dart) for a simple chat-style application
that sends encrypted messages between devices.

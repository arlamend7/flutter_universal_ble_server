/// Framework-independent BLE definitions, framing and JSON request/reply.
///
/// Import this library from Dart protocol tools or custom transports. It does
/// not initialize Flutter channels, request permissions or own a radio.
library;

export 'ble_profile.dart';
export 'src/rpc.dart'
    show
        BleRpcChannel,
        BleRpcHandler,
        BleRpcEvent,
        BleRpcReply,
        BleRequestCache;

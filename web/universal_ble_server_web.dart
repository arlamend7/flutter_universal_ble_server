import 'package:universal_ble_server/universal_ble_server.dart';

/// Web stub implementation. Peripheral mode is not supported on the web.
class UniversalBleServerWeb {
  static void registerWith() {
    // Nothing to do. Intentionally left blank.
  }

  Future<void> startServer({
    required String serviceUuid,
    required List<BleCharacteristic> characteristics,
  }) async {
    throw UnsupportedError('BLE peripheral is not supported on the web');
  }

  Future<void> stopServer() async {
    throw UnsupportedError('BLE peripheral is not supported on the web');
  }

  Future<void> notify(String characteristicUuid, List<int> value) async {
    throw UnsupportedError('BLE peripheral is not supported on the web');
  }

  Stream<BleWriteEvent> get onWrite => const Stream.empty();
  Stream<BleReadEvent> get onRead => const Stream.empty();
}

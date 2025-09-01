import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'src/models.dart';
import 'universal_ble_server_platform_interface.dart';

/// Web stub that indicates BLE peripheral mode is unsupported.
class UniversalBleServerWeb extends UniversalBleServerPlatform {
  static void registerWith(Registrar registrar) {
    UniversalBleServerPlatform.instance = UniversalBleServerWeb();
  }

  @override
  Stream<BleWriteEvent> get onWrite => const Stream.empty();

  @override
  Stream<BleReadEvent> get onRead => const Stream.empty();

  UnsupportedError _err() => UnsupportedError('BLE peripheral is not supported on the web');

  @override
  Future<void> startServer({required String serviceUuid, required List<BleCharacteristic> characteristics}) =>
      Future.error(_err());

  @override
  Future<void> stopServer() => Future.error(_err());

  @override
  Future<void> notify(String characteristicUuid, List<int> value) => Future.error(_err());
}

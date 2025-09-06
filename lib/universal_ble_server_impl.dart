import 'src/models.dart';
import 'universal_ble_server_platform_interface.dart';

/// High level API for the universal BLE server.
class UniversalBleServer {
  /// Stream of write events from connected centrals.
  Stream<BleWriteEvent> get onWrite => UniversalBleServerPlatform.instance.onWrite.map(
        (BleWriteEvent e) => BleWriteEvent(characteristicUuid: e.characteristicUuid, value: e.value),
      );

  /// Stream of read events from connected centrals.
  Stream<BleReadEvent> get onRead => UniversalBleServerPlatform.instance.onRead;

  /// Starts the BLE server if [serviceUuid] and [characteristics] are valid.
  Future<void> startServer({required String serviceUuid, required List<BleCharacteristic> characteristics}) async {
    if (serviceUuid.isEmpty || characteristics.isEmpty) {
      return;
    }
    await UniversalBleServerPlatform.instance
        .startServer(serviceUuid: serviceUuid, characteristics: characteristics);
  }

  /// Stops the BLE server.
  Future<void> stopServer() => UniversalBleServerPlatform.instance.stopServer();

  /// Notifies subscribed centrals of a characteristic value change.
  Future<void> notify(String characteristicUuid, List<int> value) async {
    if (characteristicUuid.isEmpty) {
      return;
    }
    await UniversalBleServerPlatform.instance.notify(characteristicUuid, value);
  }
}

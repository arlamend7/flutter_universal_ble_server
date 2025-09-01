import 'src/models.dart';
import 'universal_ble_server_platform_interface.dart';

/// High level API for the universal BLE server.
class UniversalBleServer {
  Stream<BleWriteEvent> get onWrite => UniversalBleServerPlatform.instance.onWrite.map(
    (e) => BleWriteEvent(characteristicUuid: e.characteristicUuid, value: e.value),
  );

  Stream<BleReadEvent> get onRead => UniversalBleServerPlatform.instance.onRead;

  Future<void> startServer({required String serviceUuid, required List<BleCharacteristic> characteristics}) async {
    final bleCharacteristic = characteristics
        .map((c) => BleCharacteristic(uuid: c.uuid, properties: c.properties, initialValue: c.initialValue))
        .toList();
    await UniversalBleServerPlatform.instance.startServer(serviceUuid: serviceUuid, characteristics: bleCharacteristic);
  }

  Future<void> stopServer() => UniversalBleServerPlatform.instance.stopServer();

  Future<void> notify(String characteristicUuid, List<int> value) async {
    await UniversalBleServerPlatform.instance.notify(characteristicUuid, value);
  }
}

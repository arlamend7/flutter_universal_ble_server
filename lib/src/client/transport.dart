import '../communication.dart';
import '../models.dart';
import '../profile.dart';

enum BleAdapterState {
  unknown,
  unsupported,
  unauthorized,
  poweredOff,
  poweredOn,
}

enum BleConnectionState {
  disconnected,
  connecting,
  discovering,
  subscribing,
  ready,
  reconnecting,
  disposed,
}

class BleDiscoveredServer {
  const BleDiscoveredServer(this.id, {this.name, this.rssi});
  final String id;
  final String? name;
  final int? rssi;
}

class BleRemoteCharacteristic {
  BleRemoteCharacteristic(
    String serviceUuid,
    String uuid,
    Set<BleProperty> access,
  ) : serviceUuid = normalizeBleUuid(serviceUuid),
      uuid = normalizeBleUuid(uuid),
      access = Set.unmodifiable(access);
  final String serviceUuid, uuid;
  final Set<BleProperty> access;
  String get key => '$serviceUuid/$uuid';
}

class BleRawNotification {
  BleRawNotification(this.key, List<int> bytes)
    : bytes = List.unmodifiable(bytes);
  final String key;
  final List<int> bytes;
}

/// One peripheral connection per transport. Implementations own their resources.
abstract class BleClientTransport {
  Stream<BleAdapterState> get adapterStates;
  Stream<BleDiscoveredServer> get discovered;
  Stream<void> get disconnected;
  Stream<BleRawNotification> get notifications;
  Future<BleAdapterState> checkSupport();
  Future<BleAdapterState> requestPermissions();
  Future<void> startScan(List<String> serviceUuids);
  Future<void> stopScan();
  Future<void> connect(String id);
  Future<List<BleRemoteCharacteristic>> discover();
  Future<int> maximumWriteBytes();
  Future<List<int>> read(String key);
  Future<void> write(String key, List<int> bytes);
  Future<void> subscribe(String key, bool enabled);
  Future<void> disconnect();
  Future<void> dispose();
}

void requireClientReady(BleAdapterState state) {
  switch (state) {
    case BleAdapterState.poweredOn:
      return;
    case BleAdapterState.unauthorized:
      throw const BleException(
        BleErrorCode.permissionDenied,
        'Bluetooth permission is required',
      );
    case BleAdapterState.poweredOff:
      throw const BleException(BleErrorCode.bluetoothOff, 'Enable Bluetooth');
    case BleAdapterState.unsupported:
      throw const BleException(
        BleErrorCode.unsupported,
        'BLE central is unavailable',
      );
    case BleAdapterState.unknown:
      throw const BleException(
        BleErrorCode.busy,
        'Bluetooth adapter is initializing',
      );
  }
}

import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'src/profile.dart';
import 'src/models.dart';
import 'universal_ble_server_method_channel.dart';

typedef BleRequestHandler =
    Future<Map<String, Object>> Function(Map<String, Object?> request);

abstract class UniversalBleServerPlatform extends PlatformInterface {
  UniversalBleServerPlatform() : super(token: _token);
  static final Object _token = Object();
  static UniversalBleServerPlatform _instance =
      MethodChannelUniversalBleServer();
  static UniversalBleServerPlatform get instance => _instance;
  static set instance(UniversalBleServerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Adapters that share native channels must share this ownership identity.
  Object get ownershipKey => this;
  Stream<Map<String, Object?>> get events;
  Stream<BleWriteEvent> get onWrite =>
      events.where((e) => e['type'] == 'write').map(BleWriteEvent.fromMap);
  Stream<BleReadEvent> get onRead =>
      events.where((e) => e['type'] == 'read').map(BleReadEvent.fromMap);
  void setRequestHandler(BleRequestHandler? handler);
  Future<BleCapabilities> checkSupport();

  /// On Android, requires a foreground Activity. On Apple, system-managed.
  Future<BleCapabilities> requestPermissions();
  Future<void> startProfile(BleProfile profile);
  Future<void> startServer({
    required String serviceUuid,
    required List<BleCharacteristic> characteristics,
  }) => startProfile(
    BleProfile(
      services: [
        BleService(
          uuid: serviceUuid,
          fields: characteristics
              .map(
                (c) => BleField<List<int>>(
                  uuid: c.uuid,
                  codec: BleCodecs.bytes,
                  initialValue: c.initialValue,
                  access: c.properties.toSet(),
                ),
              )
              .toList(),
        ),
      ],
    ),
  );
  Future<void> stopServer();
  Future<void> setValue(String characteristicUuid, List<int> value);
  Future<void> notify(String characteristicUuid, List<int> value);
  Future<void> notifyClient(
    String characteristicUuid,
    List<int> value,
    String clientId,
  ) => Future.error(
    UnsupportedError('This adapter does not support targeted notifications'),
  );
}

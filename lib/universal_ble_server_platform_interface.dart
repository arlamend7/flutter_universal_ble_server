import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'src/models.dart';
import 'universal_ble_server_method_channel.dart';

/// Platform interface for [UniversalBleServer].
abstract class UniversalBleServerPlatform extends PlatformInterface {
  UniversalBleServerPlatform() : super(token: _token);

  static final Object _token = Object();

  static UniversalBleServerPlatform _instance = MethodChannelUniversalBleServer();

  /// The default instance of [UniversalBleServerPlatform] to use.
  static UniversalBleServerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [UniversalBleServerPlatform] when
  /// they register themselves.
  static set instance(UniversalBleServerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Stream of write events from connected centrals.
  Stream<BleWriteEvent> get onWrite;

  /// Stream of read events from connected centrals.
  Stream<BleReadEvent> get onRead;

  Future<void> startServer({required String serviceUuid, required List<BleCharacteristic> characteristics});

  Future<void> stopServer();

  Future<void> notify(String characteristicUuid, List<int> value);
}

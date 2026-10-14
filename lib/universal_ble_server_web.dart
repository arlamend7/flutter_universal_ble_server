import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'src/profile.dart';
import 'universal_ble_server_platform_interface.dart';

/// Browser APIs do not provide the peripheral role required by this plugin.
class UniversalBleServerWeb extends UniversalBleServerPlatform {
  static void registerWith(Registrar registrar) {
    UniversalBleServerPlatform.instance = UniversalBleServerWeb();
  }

  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  void setRequestHandler(BleRequestHandler? handler) {}
  @override
  Future<BleCapabilities> checkSupport() async => const BleCapabilities(
    peripheral: false,
    poweredOn: false,
    authorized: false,
    platform: 'web',
    reason: 'Web Bluetooth does not expose a BLE peripheral server.',
  );
  @override
  Future<BleCapabilities> requestPermissions() => checkSupport();
  @override
  Future<void> startProfile(BleProfile profile) async =>
      throw UnsupportedError('BLE peripheral is unavailable on Web');
  @override
  Future<void> stopServer() async {}
  @override
  Future<void> setValue(String characteristicUuid, List<int> value) async =>
      throw UnsupportedError('BLE peripheral is unavailable on Web');
  @override
  Future<void> notify(String characteristicUuid, List<int> value) async =>
      throw UnsupportedError('BLE peripheral is unavailable on Web');
}

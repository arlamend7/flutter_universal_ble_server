import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble_server/universal_ble_server.dart';
import 'package:universal_ble_server/universal_ble_server_platform_interface.dart';
import 'package:universal_ble_server/universal_ble_server_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockUniversalBleServerPlatform with MockPlatformInterfaceMixin implements UniversalBleServerPlatform {
  @override
  Future<void> notify(String characteristicUuid, List<int> value) {
    // TODO: implement notify
    throw UnimplementedError();
  }

  @override
  // TODO: implement onRead
  Stream<BleReadEvent> get onRead => throw UnimplementedError();

  @override
  // TODO: implement onWrite
  Stream<BleWriteEvent> get onWrite => throw UnimplementedError();

  @override
  Future<void> startServer({required String serviceUuid, required List<BleCharacteristic> characteristics}) {
    // TODO: implement startServer
    throw UnimplementedError();
  }

  @override
  Future<void> stopServer() {
    // TODO: implement stopServer
    throw UnimplementedError();
  }
}

void main() {
  final UniversalBleServerPlatform initialPlatform = UniversalBleServerPlatform.instance;

  test('$MethodChannelUniversalBleServer is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelUniversalBleServer>());
  });

  test('getPlatformVersion', () async {
    UniversalBleServer flutterUniversalBleServerPlugin = UniversalBleServer();
    MockUniversalBleServerPlatform fakePlatform = MockUniversalBleServerPlatform();
    UniversalBleServerPlatform.instance = fakePlatform;
  });
}

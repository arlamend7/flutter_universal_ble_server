import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_universal_ble_server/flutter_universal_ble_server.dart';
import 'package:flutter_universal_ble_server/flutter_universal_ble_server_platform_interface.dart';
import 'package:flutter_universal_ble_server/flutter_universal_ble_server_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlutterUniversalBleServerPlatform
    with MockPlatformInterfaceMixin
    implements FlutterUniversalBleServerPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FlutterUniversalBleServerPlatform initialPlatform = FlutterUniversalBleServerPlatform.instance;

  test('$MethodChannelFlutterUniversalBleServer is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFlutterUniversalBleServer>());
  });

  test('getPlatformVersion', () async {
    FlutterUniversalBleServer flutterUniversalBleServerPlugin = FlutterUniversalBleServer();
    MockFlutterUniversalBleServerPlatform fakePlatform = MockFlutterUniversalBleServerPlatform();
    FlutterUniversalBleServerPlatform.instance = fakePlatform;

    expect(await flutterUniversalBleServerPlugin.getPlatformVersion(), '42');
  });
}

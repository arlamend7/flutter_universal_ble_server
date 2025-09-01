
import 'flutter_universal_ble_server_platform_interface.dart';

class FlutterUniversalBleServer {
  Future<String?> getPlatformVersion() {
    return FlutterUniversalBleServerPlatform.instance.getPlatformVersion();
  }
}

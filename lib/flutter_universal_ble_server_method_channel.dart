import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_universal_ble_server_platform_interface.dart';

/// An implementation of [FlutterUniversalBleServerPlatform] that uses method channels.
class MethodChannelFlutterUniversalBleServer extends FlutterUniversalBleServerPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_universal_ble_server');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}

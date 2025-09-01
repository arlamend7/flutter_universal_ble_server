import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_universal_ble_server_method_channel.dart';

abstract class FlutterUniversalBleServerPlatform extends PlatformInterface {
  /// Constructs a FlutterUniversalBleServerPlatform.
  FlutterUniversalBleServerPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterUniversalBleServerPlatform _instance = MethodChannelFlutterUniversalBleServer();

  /// The default instance of [FlutterUniversalBleServerPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterUniversalBleServer].
  static FlutterUniversalBleServerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterUniversalBleServerPlatform] when
  /// they register themselves.
  static set instance(FlutterUniversalBleServerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}

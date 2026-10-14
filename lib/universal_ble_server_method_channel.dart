import 'dart:convert';
import 'package:flutter/services.dart';
import 'src/profile.dart';
import 'universal_ble_server_platform_interface.dart';

class MethodChannelUniversalBleServer extends UniversalBleServerPlatform {
  static final Object _ownershipKey = Object();
  @override
  Object get ownershipKey => _ownershipKey;
  static const _channel = MethodChannel('universal_ble_server/methods');
  static const _events = EventChannel('universal_ble_server/events');
  late final Stream<Map<String, Object?>> _stream = _events
      .receiveBroadcastStream()
      .map((event) => Map<String, Object?>.from(event as Map));
  @override
  Stream<Map<String, Object?>> get events => _stream;
  @override
  void setRequestHandler(BleRequestHandler? handler) {
    _channel.setMethodCallHandler(
      handler == null
          ? null
          : (call) async {
              if (call.method != 'request') throw MissingPluginException();
              return handler(Map<String, Object?>.from(call.arguments as Map));
            },
    );
  }

  @override
  Future<BleCapabilities> checkSupport() async => BleCapabilities.fromMap(
    await _channel.invokeMapMethod<Object?, Object?>('checkSupport') ?? {},
  );
  @override
  Future<BleCapabilities> requestPermissions() async => BleCapabilities.fromMap(
    await _channel.invokeMapMethod<Object?, Object?>('requestPermissions') ??
        {},
  );
  @override
  Future<void> startProfile(BleProfile profile) =>
      _channel.invokeMethod('startServer', profile.toMap());
  @override
  Future<void> stopServer() => _channel.invokeMethod('stopServer');
  Map<String, Object> _value(String uuid, List<int> bytes) => {
    'characteristicUuid': normalizeBleUuid(uuid),
    'value': base64Encode(bleBytes(bytes)),
  };
  @override
  Future<void> setValue(String characteristicUuid, List<int> value) =>
      _channel.invokeMethod('setValue', _value(characteristicUuid, value));
  @override
  Future<void> notify(String characteristicUuid, List<int> value) =>
      _channel.invokeMethod('notify', _value(characteristicUuid, value));
  @override
  Future<void> notifyClient(
    String characteristicUuid,
    List<int> value,
    String clientId,
  ) => _channel.invokeMethod('notify', {
    ..._value(characteristicUuid, value),
    'clientId': clientId,
  });
}

import 'dart:convert';

import 'package:flutter/services.dart';

import 'src/models.dart';
import 'universal_ble_server_platform_interface.dart';

/// Method-channel implementation of [UniversalBleServerPlatform].
class MethodChannelUniversalBleServer extends UniversalBleServerPlatform {
  static const MethodChannel _channel = MethodChannel('universal_ble_server/methods');
  static const EventChannel _writeChannel = EventChannel('universal_ble_server/onWrite');
  static const EventChannel _readChannel = EventChannel('universal_ble_server/onRead');

  @override
  Stream<BleWriteEvent> get onWrite => _writeChannel.receiveBroadcastStream().map(
        (Object? event) => BleWriteEvent.fromMap((event as Map<Object?, Object?>).cast<String, Object?>()),
      );

  @override
  Stream<BleReadEvent> get onRead => _readChannel.receiveBroadcastStream().map(
        (Object? event) => BleReadEvent.fromMap((event as Map<Object?, Object?>).cast<String, Object?>()),
      );

  @override
  Future<void> startServer({required String serviceUuid, required List<BleCharacteristic> characteristics}) async {
    if (serviceUuid.isEmpty || characteristics.isEmpty) {
      return;
    }
    await _channel.invokeMethod('startServer', <String, Object>{
      'serviceUuid': serviceUuid,
      'characteristics': characteristics.map((BleCharacteristic c) => c.toMap()).toList(),
    });
  }

  @override
  Future<void> stopServer() => _channel.invokeMethod('stopServer');

  @override
  Future<void> notify(String characteristicUuid, List<int> value) async {
    if (characteristicUuid.isEmpty) {
      return;
    }
    await _channel.invokeMethod('notify', <String, Object>{
      'characteristicUuid': characteristicUuid,
      'value': base64Encode(value),
    });
  }
}

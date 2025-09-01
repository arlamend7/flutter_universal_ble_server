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
  Stream<BleWriteEvent> get onWrite => _writeChannel
      .receiveBroadcastStream()
      .map((event) => BleWriteEvent.fromMap(Map<String, dynamic>.from(event as Map)));

  @override
  Stream<BleReadEvent> get onRead => _readChannel
      .receiveBroadcastStream()
      .map((event) => BleReadEvent.fromMap(Map<String, dynamic>.from(event as Map)));

  @override
  Future<void> startServer({required String serviceUuid, required List<BleCharacteristic> characteristics}) async {
    await _channel.invokeMethod('startServer', {
      'serviceUuid': serviceUuid,
      'characteristics': characteristics.map((c) => c.toMap()).toList(),
    });
  }

  @override
  Future<void> stopServer() => _channel.invokeMethod('stopServer');

  @override
  Future<void> notify(String characteristicUuid, List<int> value) async {
    await _channel.invokeMethod('notify', {
      'characteristicUuid': characteristicUuid,
      'value': base64Encode(value),
    });
  }
}

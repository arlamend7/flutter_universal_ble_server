import 'dart:async';
import 'package:flutter/services.dart';

import 'models.dart';

/// Main entry point for the Universal BLE Server plugin.
class UniversalBleServer {
  UniversalBleServer();

  final MethodChannel _channel =
      const MethodChannel('universal_ble_server/methods');
  final EventChannel _writeChannel =
      const EventChannel('universal_ble_server/on_write');
  final EventChannel _readChannel =
      const EventChannel('universal_ble_server/on_read');

  Stream<BleWriteEvent>? _onWrite;
  Stream<BleReadEvent>? _onRead;

  /// Starts the GATT server with the specified [serviceUuid] and [characteristics].
  Future<void> startServer({
    required String serviceUuid,
    required List<BleCharacteristic> characteristics,
  }) async {
    final characteristicMaps = characteristics.map((c) {
      return {
        'uuid': c.uuid,
        'properties': c.properties.map((e) => e.name).toList(),
        'value': c.value!,
      };
    }).toList();
    await _channel.invokeMethod('startServer', {
      'serviceUuid': serviceUuid,
      'characteristics': characteristicMaps,
    });
  }

  /// Stops the running GATT server.
  Future<void> stopServer() => _channel.invokeMethod('stopServer');

  /// Sends a notification with the encrypted [value] for [characteristicUuid].
  Future<void> notify(String characteristicUuid, List<int> value) async {
    await _channel.invokeMethod('notify', {
      'characteristicUuid': characteristicUuid,
      'value': value,
    });
  }

  /// Stream of decrypted write requests from connected centrals.
  Stream<BleWriteEvent> get onWrite =>
      _onWrite ??= _writeChannel.receiveBroadcastStream().map((event) {
        final map = Map<dynamic, dynamic>.from(event as Map);
        final uuid = map['characteristicUuid'] as String;
        return BleWriteEvent(characteristicUuid: uuid, value: map['value']);
      });

  /// Stream of read requests from connected centrals.
  Stream<BleReadEvent> get onRead =>
      _onRead ??= _readChannel.receiveBroadcastStream().map((event) {
        final map = Map<dynamic, dynamic>.from(event as Map);
        final uuid = map['characteristicUuid'] as String;
        return BleReadEvent(characteristicUuid: uuid);
      });
}

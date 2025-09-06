import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble_server/universal_ble_server.dart';

void main() {
  group('BleCharacteristic', () {
    test('fromMap ignores unknown properties', () {
      final map = <String, Object?>{
        'uuid': '123',
        'properties': <String>['read', 'bogus'],
        'value': base64Encode(const <int>[1, 2, 3]),
      };
      final characteristic = BleCharacteristic.fromMap(map);
      expect(characteristic.uuid, '123');
      expect(characteristic.properties, <BleProperty>[BleProperty.read]);
      expect(characteristic.initialValue, <int>[1, 2, 3]);
    });
  });

  group('BleWriteEvent', () {
    test('fromMap handles missing value', () {
      final event = BleWriteEvent.fromMap(<String, Object?>{'uuid': 'a'});
      expect(event.characteristicUuid, 'a');
      expect(event.value, isEmpty);
    });
  });

  group('BleReadEvent', () {
    test('fromMap handles missing uuid', () {
      final event = BleReadEvent.fromMap(<String, Object?>{});
      expect(event.characteristicUuid, '');
    });
  });
}

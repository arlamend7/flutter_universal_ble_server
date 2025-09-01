import 'dart:convert';

/// BLE characteristic properties.
enum BleProperty { read, write, notify }

/// Describes a BLE characteristic exposed by the server.
class BleCharacteristic {
  BleCharacteristic({required this.uuid, required this.properties, this.initialValue = const []});

  final String uuid;
  final List<BleProperty> properties;
  final List<int> initialValue;

  Map<String, dynamic> toMap() => {
        'uuid': uuid,
        'properties': properties.map((p) => p.name).toList(),
        'value': base64Encode(initialValue),
      };

  static BleCharacteristic fromMap(Map<String, dynamic> map) => BleCharacteristic(
        uuid: map['uuid'] as String,
        properties: (map['properties'] as List<dynamic>).map((e) => BleProperty.values.firstWhere((p) => p.name == e)).toList(),
        initialValue: base64Decode(map['value'] as String),
      );
}

/// Event emitted when a central writes to a characteristic.
class BleWriteEvent {
  BleWriteEvent({required this.characteristicUuid, required this.value});

  final String characteristicUuid;
  final List<int> value;

  factory BleWriteEvent.fromMap(Map<String, dynamic> map) => BleWriteEvent(
        characteristicUuid: map['uuid'] as String,
        value: base64Decode(map['value'] as String),
      );

  Map<String, dynamic> toMap() => {
        'uuid': characteristicUuid,
        'value': base64Encode(value),
      };
}

/// Event emitted when a central reads a characteristic.
class BleReadEvent {
  BleReadEvent({required this.characteristicUuid});

  final String characteristicUuid;

  factory BleReadEvent.fromMap(Map<String, dynamic> map) => BleReadEvent(
        characteristicUuid: map['uuid'] as String,
      );

  Map<String, dynamic> toMap() => {'uuid': characteristicUuid};
}

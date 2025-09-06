import 'dart:convert';

/// Keys used for serialising BLE-related models.
const String _uuidKey = 'uuid';
const String _propertiesKey = 'properties';
const String _valueKey = 'value';

/// BLE characteristic properties.
enum BleProperty { read, write, notify }

BleProperty? _parseBleProperty(String? name) {
  if (name == null) return null;
  for (final BleProperty value in BleProperty.values) {
    if (value.name == name) return value;
  }
  return null;
}

/// Describes a BLE characteristic exposed by the server.
class BleCharacteristic {
  /// Creates a [BleCharacteristic].
  BleCharacteristic({required this.uuid, required this.properties, this.initialValue = const []});

  /// Characteristic identifier.
  final String uuid;

  /// Permitted operations for the characteristic.
  final List<BleProperty> properties;

  /// Initial characteristic value.
  final List<int> initialValue;

  /// Converts this object to a serialisable map.
  Map<String, Object> toMap() => {
        _uuidKey: uuid,
        _propertiesKey: properties.map((BleProperty p) => p.name).toList(),
        _valueKey: base64Encode(initialValue),
      };

  /// Creates a [BleCharacteristic] from [map]. Unknown properties are ignored.
  static BleCharacteristic fromMap(Map<String, Object?> map) {
    final String id = (map[_uuidKey] as String?) ?? '';
    final List<Object?> propertyNames = (map[_propertiesKey] as List<Object?>?) ?? const [];
    final List<BleProperty> props = <BleProperty>[];
    for (final Object? name in propertyNames) {
      final BleProperty? property = _parseBleProperty(name as String?);
      if (property != null) {
        props.add(property);
      }
    }
    final String? encoded = map[_valueKey] as String?;
    final List<int> value = encoded == null ? <int>[] : base64Decode(encoded);
    return BleCharacteristic(uuid: id, properties: props, initialValue: value);
  }
}

/// Event emitted when a central writes to a characteristic.
class BleWriteEvent {
  /// Creates a [BleWriteEvent].
  BleWriteEvent({required this.characteristicUuid, required this.value});

  /// Identifier of the characteristic that was written to.
  final String characteristicUuid;

  /// Written value.
  final List<int> value;

  /// Builds a [BleWriteEvent] from [map]. Missing fields yield empty values.
  factory BleWriteEvent.fromMap(Map<String, Object?> map) {
    final String id = (map[_uuidKey] as String?) ?? '';
    final String? encoded = map[_valueKey] as String?;
    final List<int> bytes = encoded == null ? <int>[] : base64Decode(encoded);
    return BleWriteEvent(characteristicUuid: id, value: bytes);
  }

  /// Converts this object to a serialisable map.
  Map<String, Object> toMap() => {
        _uuidKey: characteristicUuid,
        _valueKey: base64Encode(value),
      };
}

/// Event emitted when a central reads a characteristic.
class BleReadEvent {
  /// Creates a [BleReadEvent].
  BleReadEvent({required this.characteristicUuid});

  /// Identifier of the characteristic that was read.
  final String characteristicUuid;

  /// Builds a [BleReadEvent] from [map]. Missing UUID becomes an empty string.
  factory BleReadEvent.fromMap(Map<String, Object?> map) {
    final String id = (map[_uuidKey] as String?) ?? '';
    return BleReadEvent(characteristicUuid: id);
  }

  /// Converts this object to a serialisable map.
  Map<String, Object> toMap() => {_uuidKey: characteristicUuid};
}


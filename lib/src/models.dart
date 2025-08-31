/// Model classes for the Universal BLE Server plugin.

/// Supported characteristic properties.
enum BleProperty { read, write, notify }

/// Definition of a BLE characteristic to expose on the GATT server.
class BleCharacteristic {
  const BleCharacteristic({
    required this.uuid,
    required this.properties,
    this.value,
  });

  /// Characteristic UUID string.
  final String uuid;

  /// Properties supported by this characteristic.
  final List<BleProperty> properties;

  /// Optional initial value.
  final List<int>? value;
}

/// Event emitted when a central writes to a characteristic.
class BleWriteEvent {
  BleWriteEvent({required this.characteristicUuid, required this.value});

  /// Characteristic UUID written to.
  final String characteristicUuid;

  /// Decrypted value written by the central.
  final List<int> value;
}

/// Event emitted when a central reads a characteristic.
class BleReadEvent {
  BleReadEvent({required this.characteristicUuid});

  /// Characteristic UUID read by the central.
  final String characteristicUuid;
}

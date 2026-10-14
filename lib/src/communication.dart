import 'dart:async';
import 'dart:convert';
import 'models.dart';
import 'profile.dart';

/// Stable error categories shared by the new client and session layers.
enum BleErrorCode {
  unsupported,
  permissionDenied,
  bluetoothOff,
  disconnected,
  timeout,
  incompatibleProtocol,
  invalidData,
  tooLarge,
  busy,
  unauthorized,
  remote,
}

/// A categorized communication failure with an optional underlying cause.
class BleException implements Exception {
  /// Creates an error without discarding the native or application cause.
  const BleException(this.code, this.message, [this.cause]);

  /// Stable category suitable for application recovery decisions.
  final BleErrorCode code;

  /// Human-readable explanation; do not use for programmatic comparisons.
  final String message;

  /// Underlying failure, if available. May contain application data.
  final Object? cause;
  @override
  String toString() => 'BleException(${code.name}): $message';
}

/// Share this definition with the client; initial values and hooks stay on server.
class BleFieldDefinition<T> {
  /// Creates an immutable definition with normalized Bluetooth UUIDs.
  BleFieldDefinition({
    required String serviceUuid,
    required String uuid,
    required this.codec,
    required Set<BleProperty> access,
  }) : serviceUuid = normalizeBleUuid(serviceUuid),
       uuid = normalizeBleUuid(uuid),
       access = Set.unmodifiable(access);

  /// UUID of the service containing this characteristic.
  final String serviceUuid;

  /// Characteristic UUID in canonical 128-bit form.
  final String uuid;

  /// Converts values to and from the peer's agreed wire format.
  final BleCodec<T> codec;

  /// Immutable set of required field operations.
  final Set<BleProperty> access;

  /// Canonical service/characteristic key used by client transports.
  String get key => '$serviceUuid/$uuid';

  /// Creates server storage and hooks from this shared definition.
  BleField<T> bind({
    required T initialValue,
    bool Function(T)? validate,
    FutureOr<T> Function(BleRequestContext)? readValue,
    FutureOr<bool> Function(BleRequestContext, T)? authorizeWrite,
    BleSecurity security = BleSecurity.open,
  }) => BleField<T>(
    uuid: uuid,
    codec: codec,
    initialValue: initialValue,
    access: access,
    validate: validate,
    readValue: readValue,
    authorizeWrite: authorizeWrite,
    security: security,
  );
}

/// JSON characteristic codec; GATT values still have a 512-byte limit.
class BleJsonCodec<T> extends BleCodec<T> {
  /// Creates a typed JSON mapping without external serialization dependencies.
  const BleJsonCodec({required this.toJson, required this.fromJson});

  /// Converts a typed value to a JSON-serializable object.
  final Object? Function(T) toJson;

  /// Validates and decodes a parsed JSON value into the application type.
  final T Function(Object?) fromJson;
  @override
  List<int> encode(T value) => bleBytes(utf8.encode(jsonEncode(toJson(value))));
  @override
  T decode(List<int> bytes) =>
      fromJson(jsonDecode(utf8.decode(bleBytes(bytes))));
}

/// Both peers share this contract. Metadata is checked before client readiness.
class BleMessageConfiguration {
  /// Creates the default message service or an explicitly shared custom contract.
  BleMessageConfiguration({
    String serviceUuid = 'd973f2e0-b19e-11ee-a506-0242ac120002',
    String clientToServerUuid = 'd973f2e1-b19e-11ee-a506-0242ac120002',
    String serverToClientUuid = 'd973f2e2-b19e-11ee-a506-0242ac120002',
    String nameUuid = 'd973f2e3-b19e-11ee-a506-0242ac120002',
    String metadataUuid = 'd973f2e4-b19e-11ee-a506-0242ac120002',
    this.protocol = 'universal-ble',
    this.version = 1,
    this.frameBytes = 20,
    this.maxMessageBytes = 65535,
  }) : serviceUuid = normalizeBleUuid(serviceUuid),
       clientToServerUuid = normalizeBleUuid(clientToServerUuid),
       serverToClientUuid = normalizeBleUuid(serverToClientUuid),
       nameUuid = normalizeBleUuid(nameUuid),
       metadataUuid = normalizeBleUuid(metadataUuid) {
    if (protocol.isEmpty ||
        protocol.length > 64 ||
        version < 1 ||
        frameBytes < 8 ||
        frameBytes > 512 ||
        maxMessageBytes < 0 ||
        maxMessageBytes > 65535) {
      throw ArgumentError('Invalid message configuration');
    }
    if ({
          this.clientToServerUuid,
          this.serverToClientUuid,
          this.nameUuid,
          this.metadataUuid,
        }.length !=
        4) {
      throw ArgumentError('Message characteristic UUIDs must be distinct');
    }
    bleBytes(utf8.encode(jsonEncode(metadata)));
  }
  final String serviceUuid,
      clientToServerUuid,
      serverToClientUuid,
      nameUuid,
      metadataUuid;

  /// Application protocol identifier, matched exactly during client setup.
  final String protocol;

  /// Protocol version, maximum frame size and complete-message byte limit.
  final int version, frameBytes, maxMessageBytes;

  /// Serializable contract exposed through the readable metadata characteristic.
  Map<String, Object> get metadata => {
    'framing': 1,
    'protocol': protocol,
    'version': version,
    'frameBytes': frameBytes,
    'maxMessageBytes': maxMessageBytes,
  };

  /// Rejects incompatible framing, protocol versions or message limits.
  void verify(Object? metadata) {
    if (metadata is! Map ||
        this.metadata.entries.any((e) => metadata[e.key] != e.value)) {
      throw const BleException(
        BleErrorCode.incompatibleProtocol,
        'Message configuration differs from the server',
      );
    }
  }

  /// Creates a raw field definition within this message service.
  BleFieldDefinition<List<int>> field(String uuid, Set<BleProperty> access) =>
      BleFieldDefinition(
        serviceUuid: serviceUuid,
        uuid: uuid,
        codec: BleCodecs.bytes,
        access: access,
      );
}

/// Counters and operation names omit payloads and tokens. Application-supplied
/// errors may contain sensitive information; filter them before logging.
class BleDiagnostic {
  BleDiagnostic(this.operation, {this.bytes = 0, this.pending = 0, this.error});
  final String operation;
  final int bytes, pending;
  final Object? error;
  final DateTime time = DateTime.now();
}

/// Platform-local peer information. A null physical connection state means the
/// OS exposes subscription events rather than a complete connection inventory.
class BlePeerInfo {
  BlePeerInfo({
    required this.clientId,
    this.connected,
    Set<String> subscriptions = const {},
    this.maxNotificationBytes,
  }) : subscriptions = Set.unmodifiable(subscriptions);
  final String clientId;
  final bool? connected;
  final Set<String> subscriptions;

  /// Last reported payload limit; null if the backend has not reported one.
  final int? maxNotificationBytes;
}

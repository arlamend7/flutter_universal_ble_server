import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';

/// Canonicalizes Bluetooth SIG short UUIDs and full 128-bit UUIDs.
String normalizeBleUuid(String value) {
  final uuid = value.toLowerCase();
  if (RegExp(r'^[0-9a-f]{4}$').hasMatch(uuid)) {
    return '0000$uuid-0000-1000-8000-00805f9b34fb';
  }
  if (RegExp(r'^[0-9a-f]{8}$').hasMatch(uuid)) {
    return '$uuid-0000-1000-8000-00805f9b34fb';
  }
  if (!RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  ).hasMatch(uuid)) {
    throw ArgumentError.value(value, 'uuid', 'Expected a Bluetooth UUID');
  }
  return uuid;
}

/// Copies and validates a complete ATT attribute value (at most 512 bytes).
Uint8List bleBytes(List<int> value) {
  if (value.length > 512 || value.any((b) => b < 0 || b > 255)) {
    throw ArgumentError('BLE values must contain at most 512 bytes in 0..255');
  }
  return Uint8List.fromList(value);
}

/// Converts application values to the wire format understood by the peer.
abstract class BleCodec<T> {
  /// Base constructor for immutable application-specific codecs.
  const BleCodec();

  /// Encodes a value; characteristic codecs must stay within ATT limits.
  List<int> encode(T value);

  /// Validates and decodes bytes, throwing on an incompatible payload.
  T decode(List<int> bytes);
}

class _BytesCodec extends BleCodec<List<int>> {
  const _BytesCodec();
  @override
  List<int> encode(List<int> value) => bleBytes(value);
  @override
  List<int> decode(List<int> bytes) => bleBytes(bytes);
}

class _Utf8Codec extends BleCodec<String> {
  const _Utf8Codec();
  @override
  List<int> encode(String value) => bleBytes(utf8.encode(value));
  @override
  String decode(List<int> bytes) => utf8.decode(bytes);
}

class _Uint16Codec extends BleCodec<int> {
  const _Uint16Codec();
  @override
  List<int> encode(int value) {
    if (value < 0 || value > 65535) throw RangeError.range(value, 0, 65535);
    return (ByteData(
      2,
    )..setUint16(0, value, Endian.little)).buffer.asUint8List();
  }

  @override
  int decode(List<int> bytes) {
    if (bytes.length != 2) throw const FormatException('Expected two bytes');
    return ByteData.sublistView(bleBytes(bytes)).getUint16(0, Endian.little);
  }
}

/// Built-in codecs; custom protocols can implement [BleCodec].
abstract final class BleCodecs {
  /// Copies raw bytes with the 512-byte characteristic bound.
  static const BleCodec<List<int>> bytes = _BytesCodec();

  /// UTF-8 strings, with malformed input rejected during decoding.
  static const BleCodec<String> utf8String = _Utf8Codec();

  /// Unsigned 16-bit integers encoded least-significant byte first.
  static const BleCodec<int> uint16LittleEndian = _Uint16Codec();
}

/// Identity is opaque, platform-local and not an authentication credential.
class BleRequestContext {
  const BleRequestContext({
    required this.clientId,
    required this.characteristicUuid,
    this.offset = 0,
  });
  final String clientId;
  final String characteristicUuid;
  final int offset;
}

/// A protocol-level rejection sent to the requesting central.
class BleRequestException implements Exception {
  const BleRequestException(this.status, [this.message = 'Request rejected']);
  final BleAttStatus status;
  final String message;
  @override
  String toString() => 'BleRequestException(${status.name}): $message';
}

enum BleAttStatus {
  success(0),
  readNotPermitted(2),
  writeNotPermitted(3),
  insufficientAuthorization(8),
  invalidOffset(7),
  requestNotSupported(6),
  invalidValueLength(13),
  unlikelyError(14);

  const BleAttStatus(this.code);
  final int code;
}

/// Link-level protection for GATT reads and writes, enforced by the OS.
/// Does not provide application-layer encryption or peer identity verification.
enum BleSecurity { open, encryptedReadWrite }

/// Declarative characteristic with typed validation and optional request hooks.
/// [authorizeWrite] authorizes a proposed value before committing it; returning false
/// rejects the write. Avoid irreversible side effects in authorization hooks.
class BleField<T> {
  /// Creates a typed characteristic and validates its initial encoded value.
  BleField({
    required String uuid,
    required this.codec,
    required T initialValue,
    required Set<BleProperty> access,
    this.validate,
    FutureOr<T> Function(BleRequestContext context)? readValue,
    FutureOr<bool> Function(BleRequestContext context, T value)? authorizeWrite,
    FutureOr<T> Function(BleRequestContext context)? onRead,
    FutureOr<bool> Function(BleRequestContext context, T value)? onWrite,
    this.security = BleSecurity.open,
  }) : onRead = readValue ?? onRead,
       onWrite = authorizeWrite ?? onWrite,
       uuid = normalizeBleUuid(uuid),
       access = Set.unmodifiable(access),
       _initialBytes = bleBytes(codec.encode(initialValue)) {
    if (readValue != null && onRead != null) {
      throw ArgumentError('Use readValue or onRead, not both');
    }
    if (authorizeWrite != null && onWrite != null) {
      throw ArgumentError('Use authorizeWrite or onWrite, not both');
    }
    if (access.isEmpty) {
      throw ArgumentError('A field needs at least one property');
    }
    validateBytes(_initialBytes);
  }

  /// Canonical Bluetooth UUID identifying this characteristic or service.
  final String uuid;

  /// OS-enforced read/write security; does not encrypt application messages.
  final BleSecurity security;

  /// Wire encoder/decoder shared with compatible clients.
  final BleCodec<T> codec;

  /// Immutable set of allowed read, write and notification operations.
  final Set<BleProperty> access;

  /// Optional pure predicate applied to initial values and proposed updates.
  final bool Function(T value)? validate;

  /// Computes a client read response instead of using stored data.
  /// Does not change storage. Returns the complete typed value, before offsets.
  FutureOr<T> Function(BleRequestContext context)? get readValue => onRead;

  /// Accepts (true) or rejects (false) a proposed client write before commit.
  /// This is not an accepted-write event. Avoid irreversible side effects.
  FutureOr<bool> Function(BleRequestContext context, T value)?
  get authorizeWrite => onWrite;

  /// Compatibility alias for [readValue]. Supply only one constructor name.
  final FutureOr<T> Function(BleRequestContext context)? onRead;

  /// Compatibility alias for [authorizeWrite]. Supply only one constructor name.
  final FutureOr<bool> Function(BleRequestContext context, T value)? onWrite;
  final Uint8List _initialBytes;

  /// Immutable snapshot of the validated initial characteristic value.
  List<int> get initialBytes => List.unmodifiable(_initialBytes);

  /// Decodes and validates a proposed complete characteristic value.
  T validateBytes(List<int> bytes) {
    final value = codec.decode(bleBytes(bytes));
    if (validate != null && !validate!(value)) {
      throw const BleRequestException(
        BleAttStatus.insufficientAuthorization,
        'Value failed validation',
      );
    }
    return value;
  }

  /// Encodes and validates a value before storage or transmission.
  List<int> encode(T value) {
    final bytes = bleBytes(codec.encode(value));
    validateBytes(bytes);
    return bytes;
  }

  /// Computes the full read response before applying ATT offsets.
  Future<List<int>> read(BleRequestContext context, List<int> current) async =>
      onRead == null ? List.of(current) : encode(await onRead!(context));

  /// Validates bytes and evaluates the application write authorization hook.
  Future<bool> accept(BleRequestContext context, List<int> bytes) async {
    final value = validateBytes(bytes);
    return onWrite == null || await onWrite!(context, value);
  }

  Map<String, Object> toMap() => {
    'uuid': uuid,
    'security': security.name,
    'properties': access.map((p) => p.name).toList(),
    'value': base64Encode(_initialBytes),
  };
}

/// An immutable group of characteristics exposed under one service UUID.
class BleService {
  /// Creates a nonempty service with normalized UUID and immutable fields.
  BleService({required String uuid, required List<BleField<dynamic>> fields})
    : uuid = normalizeBleUuid(uuid),
      fields = List.unmodifiable(fields) {
    if (fields.isEmpty) {
      throw ArgumentError('A service needs at least one field');
    }
  }

  /// Canonical Bluetooth UUID identifying this characteristic or service.
  final String uuid;

  /// Immutable characteristic definitions belonging to this service.
  final List<BleField<dynamic>> fields;
  Map<String, Object> toMap() => {
    'uuid': uuid,
    'characteristics': fields.map((f) => f.toMap()).toList(),
  };
}

/// All services are exposed over GATT. Only [advertisedServiceUuid] is placed
/// in advertisements, keeping the default compatible with legacy BLE packets.
/// Name advertisement is best effort unless [requireAdvertisedName] is set.
class BleProfile {
  /// Validates services, unique UUIDs and platform-independent naming limits.
  BleProfile({
    required List<BleService> services,
    String? advertisedServiceUuid,
    this.name,
    this.requireAdvertisedName = false,
    this.allowAndroidAdapterNameChange = false,
  }) : services = List.unmodifiable(services),
       advertisedServiceUuid = advertisedServiceUuid == null
           ? (services.isEmpty ? '' : services.first.uuid)
           : normalizeBleUuid(advertisedServiceUuid) {
    if (name != null &&
        (name!.trim().isEmpty ||
            utf8.encode(name!).length > 29 ||
            name!.contains('\u0000'))) {
      throw ArgumentError('Name must contain 1..29 UTF-8 bytes without NUL');
    }
    if (requireAdvertisedName && name == null) {
      throw ArgumentError('A name is required');
    }
    if (services.isEmpty) {
      throw ArgumentError('A profile needs at least one service');
    }
    final serviceIds = <String>{};
    final fieldIds = <String>{};
    for (final service in services) {
      if (!serviceIds.add(service.uuid)) {
        throw ArgumentError('Duplicate service UUID');
      }
      for (final field in service.fields) {
        if (!fieldIds.add(field.uuid)) {
          throw ArgumentError(
            'Characteristic UUIDs must be unique across the profile',
          );
        }
      }
    }
    if (!serviceIds.contains(this.advertisedServiceUuid)) {
      throw ArgumentError('Advertised service must belong to the profile');
    }
  }

  /// Immutable list of services to expose to connected clients.
  final List<BleService> services;

  /// The single service UUID included in discovery advertisements.
  final String advertisedServiceUuid;

  /// Requested logical server name, limited to 29 UTF-8 bytes.
  final String? name;

  /// Fail rather than omit a requested name on an unsupported platform.
  /// The OS can still shorten or suppress names (e.g. iOS in background).
  final bool requireAdvertisedName;

  /// Android has no per-advertisement name setter. Explicitly permits changing
  /// the system adapter name while running. Restoration is best effort.
  final bool allowAndroidAdapterNameChange;

  /// All characteristic definitions across the profile's services.
  Iterable<BleField<dynamic>> get fields => services.expand((s) => s.fields);
  Map<String, Object> toMap() => {
    'services': services.map((s) => s.toMap()).toList(),
    'advertisedServiceUuid': advertisedServiceUuid,
    if (name != null) 'name': name!,
    'requireAdvertisedName': requireAdvertisedName,
    'allowAndroidAdapterNameChange': allowAndroidAdapterNameChange,
  };
}

/// Lifecycle state of a server instance.
enum BleServerState { stopped, starting, running, stopping, failed, disposed }

/// How the platform can expose a requested advertising name.
enum BleNameSupport { local, adapterName, unavailable }

/// Snapshot of peripheral support, consent and Bluetooth power state.
class BleCapabilities {
  const BleCapabilities({
    required this.peripheral,
    required this.poweredOn,
    required this.authorized,
    required this.platform,
    this.reason,
    this.nameSupport = BleNameSupport.unavailable,
    this.connectionEvents = false,
  });
  final bool peripheral;
  final bool poweredOn;
  final bool authorized;
  final String platform;
  final String? reason;
  final BleNameSupport nameSupport;
  final bool connectionEvents;

  /// Whether a server can currently attempt startup.
  bool get ready => peripheral && poweredOn && authorized;

  /// Throws a descriptive error when the peripheral is unavailable.
  void requireCompatible() {
    if (!ready) {
      throw StateError(reason ?? 'Bluetooth peripheral is unavailable');
    }
  }

  factory BleCapabilities.fromMap(Map<Object?, Object?> map) => BleCapabilities(
    peripheral: map['peripheral'] == true,
    poweredOn: map['poweredOn'] == true,
    authorized: map['authorized'] == true,
    platform: map['platform'] as String? ?? 'unknown',
    reason: map['reason'] as String?,
    nameSupport: BleNameSupport.values.firstWhere(
      (v) => v.name == map['nameSupport'],
      orElse: () => BleNameSupport.unavailable,
    ),
    connectionEvents: map['connectionEvents'] == true,
  );
}

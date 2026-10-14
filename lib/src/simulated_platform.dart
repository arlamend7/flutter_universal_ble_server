import 'dart:async';
import 'dart:convert';
import '../universal_ble_server_platform_interface.dart';
import 'profile.dart';

/// Deterministic in-memory peripheral for tests. Does not emulate radio timing,
/// OS permissions, pairing or controller-specific limits.
class SimulatedBlePlatform extends UniversalBleServerPlatform {
  final _notificationEvents = StreamController<Map<String, Object>>.broadcast(
    sync: true,
  );
  Stream<Map<String, Object>> get notificationEvents =>
      _notificationEvents.stream;
  final _events = StreamController<Map<String, Object?>>.broadcast(sync: true);
  BleRequestHandler? _handler;
  BleProfile? activeProfile;
  final Map<String, Set<String>> subscribers = {};
  final Map<String, List<int>> values = {};
  final List<Map<String, Object>> notifications = [];
  @override
  Stream<Map<String, Object?>> get events => _events.stream;
  @override
  void setRequestHandler(BleRequestHandler? handler) => _handler = handler;
  @override
  Future<BleCapabilities> checkSupport() async => const BleCapabilities(
    peripheral: true,
    poweredOn: true,
    authorized: true,
    platform: 'simulated',
    nameSupport: BleNameSupport.local,
    connectionEvents: true,
  );
  @override
  Future<BleCapabilities> requestPermissions() => checkSupport();
  @override
  Future<void> startProfile(BleProfile profile) async {
    if (activeProfile != null) throw StateError('Already running');
    activeProfile = profile;
    values.addEntries(
      profile.fields.map((f) => MapEntry(f.uuid, List.of(f.initialBytes))),
    );
  }

  @override
  Future<void> stopServer() async {
    activeProfile = null;
    values.clear();
    subscribers.clear();
  }

  @override
  Future<void> setValue(String characteristicUuid, List<int> value) async {
    if (!values.containsKey(characteristicUuid)) {
      throw StateError('Unknown characteristic');
    }
    values[characteristicUuid] = bleBytes(value);
  }

  @override
  Future<void> notify(String characteristicUuid, List<int> value) async {
    if (activeProfile == null) throw StateError('Not running');
    final event = <String, Object>{
      'uuid': characteristicUuid,
      'value': List<int>.of(value),
    };
    notifications.add(event);
    _notificationEvents.add(event);
  }

  @override
  Future<void> notifyClient(
    String characteristicUuid,
    List<int> value,
    String clientId,
  ) async {
    if (activeProfile == null ||
        subscribers[characteristicUuid]?.contains(clientId) != true) {
      throw StateError('Client is not subscribed');
    }
    final event = <String, Object>{
      'uuid': characteristicUuid,
      'value': List<int>.of(value),
      'clientId': clientId,
    };
    notifications.add(event);
    _notificationEvents.add(event);
  }

  void connect(String clientId) =>
      _events.add({'type': 'connected', 'clientId': clientId});
  void subscribe(String uuid, String clientId) {
    uuid = normalizeBleUuid(uuid);
    subscribers.putIfAbsent(uuid, () => {}).add(clientId);
    _events.add({'type': 'subscribed', 'uuid': uuid, 'clientId': clientId});
  }

  void unsubscribe(String uuid, String clientId) {
    uuid = normalizeBleUuid(uuid);
    subscribers[uuid]?.remove(clientId);
    _events.add({'type': 'unsubscribed', 'uuid': uuid, 'clientId': clientId});
  }

  void disconnect(String clientId) {
    for (final clients in subscribers.values) {
      clients.remove(clientId);
    }
    _events.add({'type': 'disconnected', 'clientId': clientId});
  }

  Future<Map<String, Object>> _request(Map<String, Object?> request) async {
    if (_handler == null || activeProfile == null) {
      throw StateError('Not running');
    }
    return _handler!(request);
  }

  Future<List<int>> read(
    String uuid, {
    String clientId = 'test-client',
    int offset = 0,
  }) async {
    uuid = normalizeBleUuid(uuid);
    final request = <String, Object?>{
      'type': 'read',
      'uuid': uuid,
      'clientId': clientId,
      'offset': offset,
    };
    final result = await _request(request);
    _check(result);
    _events.add(request);
    return base64Decode(result['value'] as String).sublist(offset);
  }

  Future<void> write(
    String uuid,
    List<int> value, {
    String clientId = 'test-client',
    int offset = 0,
  }) async {
    uuid = normalizeBleUuid(uuid);
    final request = <String, Object?>{
      'type': 'write',
      'uuid': uuid,
      'clientId': clientId,
      'offset': offset,
      'value': base64Encode(bleBytes(value)),
    };
    final result = await _request(request);
    _check(result);
    values[uuid] = base64Decode(result['value'] as String);
    _events.add(request);
  }

  void _check(Map<String, Object> result) {
    final status = result['status'] as int;
    if (status != 0) {
      throw BleRequestException(
        BleAttStatus.values.firstWhere(
          (s) => s.code == status,
          orElse: () => BleAttStatus.unlikelyError,
        ),
      );
    }
  }

  Future<void> dispose() async {
    await _events.close();
    await _notificationEvents.close();
  }
}

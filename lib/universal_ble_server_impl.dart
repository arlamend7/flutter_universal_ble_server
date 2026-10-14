import 'dart:async';
import 'dart:convert';

import 'src/models.dart';
import 'src/profile.dart';
import 'universal_ble_server_platform_interface.dart';

/// A custom GATT server whose [profile] describes client-readable/writable fields.
///
/// Use [start], [stop] and [dispose] for lifecycle; [readStoredValue] and
/// [updateStoredValue] for storage; [sendNotification] for outgoing raw bytes.
/// Use BleMessageServer instead when exchanging complete text/binary messages.
/// One active server per platform adapter. Native resources are process-local.
class UniversalBleServer {
  UniversalBleServer({
    this.profile,
    UniversalBleServerPlatform? platform,
    this.requestTimeout = const Duration(seconds: 5),
  }) : _platform = platform ?? UniversalBleServerPlatform.instance {
    if (requestTimeout <= Duration.zero ||
        requestTimeout > const Duration(seconds: 5)) {
      throw ArgumentError(
        'requestTimeout must be greater than zero and at most five seconds',
      );
    }
  }
  final BleProfile? profile;
  final Duration requestTimeout;
  final UniversalBleServerPlatform _platform;
  static final Map<Object, UniversalBleServer> _owners = {};
  final _states = StreamController<BleServerState>.broadcast();
  final _events = StreamController<Map<String, Object?>>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final Map<String, List<int>> _values = {};
  final Map<String, BleField<dynamic>> _fields = {};
  StreamSubscription<Map<String, Object?>>? _subscription;
  Future<void> _operations = Future.value();
  Future<void> _requests = Future.value();
  BleServerState _state = BleServerState.stopped;
  int _generation = 0;
  bool _disposing = false;

  BleServerState get state => _state;

  /// Changes to server lifecycle state. Subscribe before [start].
  Stream<BleServerState> get stateChanges => _states.stream;

  /// Compatibility alias for [stateChanges].
  Stream<BleServerState> get states => stateChanges;

  /// Read, write, subscribed, unsubscribed, connected, disconnected and error
  /// events. Connection events are available on Android; Apple reports
  /// subscriptions rather than physical connections.
  Stream<Map<String, Object?>> get events => _events.stream;
  Stream<Object> get errors => _errors.stream;

  /// Accepted client writes, emitted after storage has been updated.
  Stream<BleWriteEvent> get clientWrites =>
      events.where((e) => e['type'] == 'write').map(BleWriteEvent.fromMap);

  /// Successful client reads; these events do not provide the response value.
  Stream<BleReadEvent> get clientReads =>
      events.where((e) => e['type'] == 'read').map(BleReadEvent.fromMap);

  /// Compatibility alias for [clientWrites], not a write authorization hook.
  Stream<BleWriteEvent> get onWrite => clientWrites;

  /// Compatibility alias for [clientReads], not a dynamic read callback.
  Stream<BleReadEvent> get onRead => clientReads;

  void _transition(BleServerState value) {
    _state = value;
    if (!_states.isClosed) _states.add(value);
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    if (_disposing || _state == BleServerState.disposed) {
      return Future.error(StateError('Server disposed'));
    }
    final operation = _operations.then((_) => action());
    _operations = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  /// Checks adapter capabilities and readiness. Apple may prompt for consent.
  Future<BleCapabilities> checkSupport() => _platform.checkSupport();

  /// Requests OS permission and returns the resulting adapter readiness.
  Future<BleCapabilities> requestPermissions() =>
      _platform.requestPermissions();

  /// Registers [profile] and starts advertising. Requires a stopped server.
  Future<void> start() {
    if (profile == null) {
      return Future.error(StateError('Supply a BleProfile or use startServer'));
    }
    return _enqueue(() => _start(profile!));
  }

  /// Compatibility entry point for a single service configured at startup.
  /// Prefer a constructor [profile] followed by [start] for new code.
  Future<void> startServer({
    required String serviceUuid,
    required List<BleCharacteristic> characteristics,
    String? name,
    bool requireAdvertisedName = false,
    bool allowAndroidAdapterNameChange = false,
  }) => _enqueue(
    () => _start(
      BleProfile(
        name: name,
        requireAdvertisedName: requireAdvertisedName,
        allowAndroidAdapterNameChange: allowAndroidAdapterNameChange,
        services: [
          BleService(
            uuid: serviceUuid,
            fields: characteristics
                .map(
                  (c) => BleField<List<int>>(
                    uuid: c.uuid,
                    codec: BleCodecs.bytes,
                    initialValue: c.initialValue,
                    access: c.properties.toSet(),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    ),
  );

  Future<void> _start(BleProfile configuration) async {
    if (_state == BleServerState.running || _state == BleServerState.starting) {
      throw StateError('Server already started; stop before changing profiles');
    }
    final owner = _owners[_platform.ownershipKey];
    if (owner != null && owner != this) {
      throw StateError('Another server owns this adapter');
    }
    if (_state == BleServerState.failed && owner == this) await _cleanup();
    _owners[_platform.ownershipKey] = this;
    _transition(BleServerState.starting);
    _generation++;
    try {
      (await checkSupport()).requireCompatible();
      _fields.clear();
      _values.clear();
      for (final field in configuration.fields) {
        _fields[field.uuid] = field;
        _values[field.uuid] = field.initialBytes;
      }
      await _subscription?.cancel();
      _subscription = _platform.events.listen(
        (event) {
          if (event['type'] == 'write') {
            final uuid = normalizeBleUuid(event['uuid'] as String);
            if (_fields.containsKey(uuid)) {
              _values[uuid] = base64Decode(event['value'] as String);
            }
          }
          if (event['type'] == 'error') {
            _generation++;
            _transition(BleServerState.failed);
            _errors.add(
              StateError(
                event['message'] as String? ?? 'Bluetooth unavailable',
              ),
            );
          }
          _events.add(Map.unmodifiable(event));
        },
        onError: (Object error) {
          _generation++;
          _transition(BleServerState.failed);
          _errors.add(error);
        },
      );
      _platform.setRequestHandler(_handleRequest);
      await _platform.startProfile(configuration);
      if (_state != BleServerState.starting) {
        throw StateError('Bluetooth stopped while starting');
      }
      _transition(BleServerState.running);
    } catch (_) {
      await _cleanup();
      _transition(BleServerState.failed);
      rethrow;
    }
  }

  Future<Map<String, Object>> _handleRequest(Map<String, Object?> request) {
    final generation = _generation;
    final deadline = DateTime.now().add(requestTimeout);
    final result = _requests.then((_) async {
      try {
        if (DateTime.now().isAfter(deadline) ||
            generation != _generation ||
            _state != BleServerState.running) {
          return <String, Object>{'status': BleAttStatus.unlikelyError.code};
        }
        final uuid = normalizeBleUuid(request['uuid'] as String);
        final field = _fields[uuid];
        if (field == null) return <String, Object>{'status': 10};
        final offset = request['offset'] as int? ?? 0;
        final context = BleRequestContext(
          clientId: request['clientId'] as String? ?? '',
          characteristicUuid: uuid,
          offset: offset,
        );
        List<int> bytes;
        if (request['type'] == 'read') {
          if (!field.access.contains(BleProperty.read)) {
            throw const BleRequestException(BleAttStatus.readNotPermitted);
          }
          bytes = await field
              .read(context, _values[uuid]!)
              .timeout(requestTimeout);
          if (offset < 0 || offset > bytes.length) {
            throw const BleRequestException(BleAttStatus.invalidOffset);
          }
        } else if (request['type'] == 'write') {
          if (!field.access.contains(BleProperty.write)) {
            throw const BleRequestException(BleAttStatus.writeNotPermitted);
          }
          // Portable writes replace the whole value. Reliable/prepared writes
          // require transactional semantics and are explicitly rejected natively.
          if (offset != 0) {
            throw const BleRequestException(BleAttStatus.invalidOffset);
          }
          bytes = bleBytes(base64Decode(request['value'] as String));
          if (!await field.accept(context, bytes).timeout(requestTimeout)) {
            throw const BleRequestException(
              BleAttStatus.insufficientAuthorization,
            );
          }
        } else {
          throw const BleRequestException(BleAttStatus.requestNotSupported);
        }
        if (DateTime.now().isAfter(deadline) ||
            generation != _generation ||
            _state != BleServerState.running) {
          throw StateError('Server stopped');
        }
        return <String, Object>{'status': 0, 'value': base64Encode(bytes)};
      } on BleRequestException catch (error) {
        return <String, Object>{'status': error.status.code};
      } on FormatException {
        return <String, Object>{'status': BleAttStatus.invalidValueLength.code};
      } on ArgumentError {
        return <String, Object>{'status': BleAttStatus.invalidValueLength.code};
      } catch (error) {
        if (!_errors.isClosed) _errors.add(error);
        return <String, Object>{'status': BleAttStatus.unlikelyError.code};
      }
    });
    _requests = result.then<void>((_) {});
    // Includes time spent waiting behind another client. Native has an
    // independent deadline, so a paused Dart isolate never hangs ATT forever.
    return result.timeout(requestTimeout, onTimeout: () => {'status': 14});
  }

  BleField<dynamic> _field(String uuid) {
    if (_state != BleServerState.running) {
      throw StateError('Server is not running');
    }
    return _fields[normalizeBleUuid(uuid)] ??
        (throw ArgumentError('Unknown characteristic: $uuid'));
  }

  /// Returns the locally stored value, without making a Bluetooth request.
  /// A field's dynamic read callback may return a different value to clients.
  T readStoredValue<T>(BleField<T> field) {
    if (!identical(_field(field.uuid), field)) {
      throw ArgumentError('Field does not belong to the active profile');
    }
    return field.codec.decode(List.of(_values[field.uuid]!));
  }

  /// Compatibility alias for [readStoredValue].
  T valueOf<T>(BleField<T> field) => readStoredValue(field);

  /// Replaces a field's stored value. Set [notify] to also notify subscribers.
  /// Defaults to storing only. Clients can read storage when read access is
  /// enabled and no dynamic read hook overrides it. Applies the field's codec
  /// and validation; requires [start].
  ///
  /// Notifications require notification access and send one GATT value without
  /// fragmentation or application-level acknowledgement. If transmission fails,
  /// the stored value remains updated.
  Future<void> updateStoredValue<T>(
    BleField<T> field,
    T value, {
    bool notify = false,
  }) {
    final bytes = field.encode(value);
    return _enqueue(() async {
      if (!identical(_field(field.uuid), field)) {
        throw ArgumentError('Field does not belong to the active profile');
      }
      if (notify && !field.access.contains(BleProperty.notify)) {
        throw StateError('Field does not support notifications');
      }
      await _platform.setValue(field.uuid, bytes);
      _values[field.uuid] = List.of(bytes);
      if (notify) await _platform.notify(field.uuid, bytes);
    });
  }

  /// Compatibility alias for [updateStoredValue].
  Future<void> setValue<T>(BleField<T> field, T value, {bool notify = false}) =>
      updateStoredValue(field, value, notify: notify);

  /// Sends bytes to subscribers without changing the stored readable value.
  /// Omitting [clientId] targets all subscribers; with none, nothing is sent.
  /// Never automatically retries or fragments messages. Payload must fit the
  /// target's negotiated limit; completion is not an application-level receipt.
  Future<void> sendNotification(
    String characteristicUuid,
    List<int> value, {
    String? clientId,
  }) {
    final bytes = bleBytes(value);
    return _enqueue(() async {
      final field = _field(characteristicUuid);
      if (!field.access.contains(BleProperty.notify)) {
        throw StateError('Field does not support notifications');
      }
      field.validateBytes(bytes);
      if (clientId == null) {
        await _platform.notify(field.uuid, bytes);
      } else {
        await _platform.notifyClient(field.uuid, bytes, clientId);
      }
    });
  }

  /// Compatibility alias for [sendNotification].
  Future<void> notify(
    String characteristicUuid,
    List<int> value, {
    String? clientId,
  }) => sendNotification(characteristicUuid, value, clientId: clientId);

  /// Stops advertising and releases native resources. Can be started again.
  Future<void> stop() => _enqueue(() async {
    if (_state == BleServerState.stopped) return;
    _transition(BleServerState.stopping);
    await _cleanup();
    _transition(BleServerState.stopped);
  });

  /// Compatibility alias for [stop].
  Future<void> stopServer() => stop();

  Future<void> _cleanup() async {
    _generation++;
    if (_owners[_platform.ownershipKey] == this) {
      try {
        await _platform.stopServer();
      } finally {
        _platform.setRequestHandler(null);
        _owners.remove(_platform.ownershipKey);
        await _subscription?.cancel();
        _subscription = null;
        _values.clear();
        _fields.clear();
      }
    }
  }

  Future<void>? _disposeFuture;

  /// Stops the server and closes its streams permanently. Safe to call twice.
  Future<void> dispose() {
    if (_disposeFuture != null) return _disposeFuture!;
    _disposing = true;
    return _disposeFuture = _operations.then((_) async {
      try {
        await _cleanup();
      } finally {
        _transition(BleServerState.disposed);
        // Broadcast stream close futures can be held by paused consumers.
        unawaited(_states.close());
        unawaited(_events.close());
        unawaited(_errors.close());
      }
    });
  }
}

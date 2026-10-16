import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../communication.dart';
import '../models.dart';
import 'transport.dart';

/// Direct platform-channel adapter. No external Bluetooth plugin is used.
/// Linux uses an independent native session per instance. Other native backends
/// currently allow one client per Flutter engine.
class NativeBleClientTransport extends BleClientTransport {
  static const _factory = MethodChannel('universal_ble_server/client/methods');
  static int _nextSession = 0;
  final bool _isolated =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
  late final String _session =
      'dart_${DateTime.now().microsecondsSinceEpoch}_${++_nextSession}';
  late final MethodChannel _methods = _isolated
      ? MethodChannel('universal_ble_server/client/$_session/methods')
      : _factory;
  late final EventChannel _events = EventChannel(
    _isolated
        ? 'universal_ble_server/client/$_session/events'
        : 'universal_ble_server/client/events',
  );
  Future<void>? _initializing;
  bool _created = false;
  static NativeBleClientTransport? _owner;
  final _states = StreamController<BleAdapterState>.broadcast();
  final _discovered = StreamController<BleDiscoveredServer>.broadcast();
  final _disconnected = StreamController<void>.broadcast();
  final _notifications = StreamController<BleRawNotification>.broadcast();
  StreamSubscription<dynamic>? _subscription;
  bool _disposed = false;
  @override
  Stream<BleAdapterState> get adapterStates => _states.stream;
  @override
  Stream<BleDiscoveredServer> get discovered => _discovered.stream;
  @override
  Stream<void> get disconnected => _disconnected.stream;
  @override
  Stream<BleRawNotification> get notifications => _notifications.stream;
  Future<void> _initialize() async {
    if (_disposed) throw StateError('Client disposed');
    if (kIsWeb) {
      throw const BleException(
        BleErrorCode.unsupported,
        'Use the Web Bluetooth browser example',
      );
    }
    if (!_isolated && _owner != null && _owner != this) {
      throw const BleException(
        BleErrorCode.busy,
        'Another client owns the native adapter',
      );
    }
    if (_isolated) {
      await (_initializing ??= _createSession());
      if (_disposed) throw StateError('Client disposed');
    } else {
      _owner = this;
    }
    _subscription ??= _events.receiveBroadcastStream().listen(
      (raw) {
        try {
          final e = Map<String, Object?>.from(raw as Map<Object?, Object?>);
          switch (e['type']) {
            case 'state':
              _states.add(BleAdapterState.values.byName(e['state'] as String));
            case 'discovered':
              _discovered.add(
                BleDiscoveredServer(
                  e['id'] as String,
                  name: e['name'] as String?,
                  rssi: e['rssi'] as int?,
                ),
              );
            case 'disconnected':
              _disconnected.add(null);
            case 'notification':
              _notifications.add(
                BleRawNotification(
                  e['key'] as String,
                  base64Decode(e['value'] as String),
                ),
              );
          }
        } catch (error, stack) {
          _notifications.addError(
            BleException(
              BleErrorCode.invalidData,
              'Malformed native BLE event',
              error,
            ),
            stack,
          );
        }
      },
      onError: (Object e) {
        _notifications.addError(e is PlatformException ? _platformError(e) : e);
      },
    );
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      await _initialize();
      if (_disposed) throw StateError('Client disposed');
      return await _methods.invokeMethod<T>(method, args);
    } on MissingPluginException catch (e) {
      throw BleException(
        BleErrorCode.unsupported,
        'Native BLE client unavailable',
        e,
      );
    } on PlatformException catch (e) {
      throw _platformError(e);
    }
  }

  Future<void> _createSession() async {
    try {
      await _factory.invokeMethod<void>('createClient', {'session': _session});
      _created = true;
    } catch (_) {
      _initializing = null;
      rethrow;
    }
  }

  BleException _platformError(PlatformException error) => BleException(
    switch (error.code) {
      'permission_denied' => BleErrorCode.permissionDenied,
      'bluetooth_off' => BleErrorCode.bluetoothOff,
      'disconnected' => BleErrorCode.disconnected,
      'timeout' => BleErrorCode.timeout,
      'unsupported' => BleErrorCode.unsupported,
      'busy' => BleErrorCode.busy,
      _ => BleErrorCode.remote,
    },
    error.message ?? error.code,
    error,
  );

  @override
  Future<BleAdapterState> checkSupport() async => kIsWeb
      ? BleAdapterState.unsupported
      : BleAdapterState.values.byName((await _call<String>('checkSupport'))!);
  @override
  Future<BleAdapterState> requestPermissions() async => kIsWeb
      ? BleAdapterState.unsupported
      : BleAdapterState.values.byName(
          (await _call<String>('requestPermissions'))!,
        );
  @override
  Future<void> startScan(List<String> serviceUuids) =>
      _call<void>('startScan', {'services': serviceUuids});
  @override
  Future<void> stopScan() => _call<void>('stopScan');
  @override
  Future<void> connect(String id) => _call<void>('connect', {'id': id});
  @override
  Future<List<BleRemoteCharacteristic>> discover() async =>
      ((await _call<List<dynamic>>('discover'))!).map((raw) {
        final m = Map<String, dynamic>.from(raw as Map);
        return BleRemoteCharacteristic(
          m['service'] as String,
          m['uuid'] as String,
          (m['access'] as List)
              .map((p) => BleProperty.values.byName(p as String))
              .toSet(),
        );
      }).toList();
  @override
  Future<int> maximumWriteBytes() async =>
      (await _call<int>('maximumWriteBytes'))!;
  @override
  Future<List<int>> read(String key) async =>
      base64Decode((await _call<String>('read', {'key': key}))!);
  @override
  Future<void> write(String key, List<int> bytes) =>
      _call<void>('write', {'key': key, 'value': base64Encode(bytes)});
  @override
  Future<void> subscribe(String key, bool enabled) =>
      _call<void>('subscribe', {'key': key, 'enabled': enabled});
  @override
  Future<void> disconnect() => _call<void>('disconnect');
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      if (_isolated) {
        try {
          await _initializing;
        } catch (_) {
          /* No native session to release. */
        }
        await _subscription?.cancel();
        _subscription = null;
        if (_created) await _methods.invokeMethod<void>('dispose');
      } else if (_owner == this) {
        await _methods.invokeMethod<void>('dispose');
      }
    } on PlatformException catch (error) {
      throw _platformError(error);
    } finally {
      await _subscription?.cancel();
      if (_owner == this) _owner = null;
      unawaited(_states.close());
      unawaited(_discovered.close());
      unawaited(_disconnected.close());
      unawaited(_notifications.close());
    }
  }
}

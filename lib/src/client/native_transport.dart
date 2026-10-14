import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../communication.dart';
import '../models.dart';
import 'transport.dart';

/// Direct platform-channel adapter. No external Bluetooth plugin is used.
/// One native central connection per Flutter engine; each device runs its own.
class NativeBleClientTransport extends BleClientTransport {
  static const _methods = MethodChannel('universal_ble_server/client/methods');
  static const _events = EventChannel('universal_ble_server/client/events');
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
  void _initialize() {
    if (_disposed) throw StateError('Client disposed');
    if (kIsWeb) {
      throw const BleException(
        BleErrorCode.unsupported,
        'Use the Web Bluetooth browser example',
      );
    }
    if (_owner != null && _owner != this) {
      throw const BleException(
        BleErrorCode.busy,
        'Another client owns the native adapter',
      );
    }
    _owner = this;
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
    _initialize();
    try {
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
    try {
      if (_owner == this) await _call<void>('dispose');
    } finally {
      _disposed = true;
      await _subscription?.cancel();
      if (_owner == this) _owner = null;
      unawaited(_states.close());
      unawaited(_discovered.close());
      unawaited(_disconnected.close());
      unawaited(_notifications.close());
    }
  }
}

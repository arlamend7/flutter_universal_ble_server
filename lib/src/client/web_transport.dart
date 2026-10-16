import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../communication.dart';
import '../models.dart';
import '../profile.dart';
import 'transport.dart';
import 'web_bindings.dart';

BleClientTransport createDefaultBleClientTransport() =>
    _WebBleClientTransport();

class _WebBleClientTransport extends BleClientTransport
    implements BleDeviceSelector {
  final _states = StreamController<BleAdapterState>.broadcast();
  final _discovered = StreamController<BleDiscoveredServer>.broadcast();
  final _disconnected = StreamController<void>.broadcast();
  final _notifications = StreamController<BleRawNotification>.broadcast();
  final _fields = <String, BrowserCharacteristic>{};
  final _listeners = <String, JSFunction>{};
  BrowserBluetooth? _bluetooth;
  BrowserDevice? _selected;
  BrowserGatt? _gatt;
  JSFunction? _disconnectListener, _availabilityListener;
  bool _disposed = false, _selecting = false, _connecting = false;
  int _generation = 0;

  @override
  Stream<BleAdapterState> get adapterStates => _states.stream;
  @override
  Stream<BleDiscoveredServer> get discovered => _discovered.stream;
  @override
  Stream<void> get disconnected => _disconnected.stream;
  @override
  Stream<BleRawNotification> get notifications => _notifications.stream;

  void _alive() {
    if (_disposed) throw StateError('Client disposed');
  }

  BrowserBluetooth _api() {
    _alive();
    if (!browserIsSecureContext || browserBluetooth == null) {
      throw const BleException(
        BleErrorCode.unsupported,
        'Web Bluetooth requires a supported browser and HTTPS or localhost',
      );
    }
    if (_bluetooth == null) {
      final api = _bluetooth = browserBluetooth!;
      final listener = ((JSObject event) {
        if (_disposed) return;
        final available = event.getProperty<JSBoolean>('value'.toJS).toDart;
        _states.add(
          available ? BleAdapterState.poweredOn : BleAdapterState.unknown,
        );
        if (!available) _endConnection(emit: true);
      }).toJS;
      _availabilityListener = listener;
      api.addEventListener('availabilitychanged', listener);
    }
    return _bluetooth!;
  }

  @override
  Future<BleAdapterState> checkSupport() async {
    try {
      final api = _api();
      if (api.hasProperty('getAvailability'.toJS).toDart) {
        final available = await api.getAvailability().toDart;
        _alive();
        // A false result can reflect privacy/policy as well as the radio.
        if (!available.toDart) return BleAdapterState.unknown;
      }
      return BleAdapterState.poweredOn;
    } catch (error) {
      final mapped = _mapError(error);
      if (mapped.code == BleErrorCode.unsupported) {
        return BleAdapterState.unsupported;
      }
      if (mapped.code == BleErrorCode.permissionDenied) {
        return BleAdapterState.unauthorized;
      }
      throw mapped;
    }
  }

  // Browsers grant device access only through requestDevice, not a separate prompt.
  @override
  Future<BleAdapterState> requestPermissions() => checkSupport();

  @override
  Future<BleDiscoveredServer?> selectDevice({
    List<String> serviceUuids = const [],
    List<String> optionalServiceUuids = const [],
  }) async {
    _alive();
    if (_selecting || _connecting || _gatt != null) {
      throw const BleException(
        BleErrorCode.busy,
        'A chooser or connection is already active',
      );
    }
    final services = serviceUuids.map(normalizeBleUuid).toSet();
    final optional = optionalServiceUuids.map(normalizeBleUuid).toSet();
    final options = services.isEmpty
        ? BrowserRequestOptions(
            acceptAllDevices: true,
            optionalServices: optional.map((s) => s.toJS).toList().toJS,
          )
        : BrowserRequestOptions(
            filters: [
              BrowserServiceFilter(
                services: services.map((s) => s.toJS).toList().toJS,
              ),
            ].toJS,
            optionalServices: optional.map((s) => s.toJS).toList().toJS,
          );
    _selecting = true;
    final generation = _generation;
    try {
      // First browser call is synchronous, preserving the click's user activation.
      final device = await _api().requestDevice(options).toDart;
      if (_disposed || generation != _generation) {
        throw const BleException(
          BleErrorCode.disconnected,
          'Device selection cancelled',
        );
      }
      _selected = device;
      final result = BleDiscoveredServer(device.id, name: device.name);
      _discovered.add(result);
      return result;
    } catch (error) {
      if (!_disposed &&
          generation == _generation &&
          _errorName(error) == 'NotFoundError') {
        return null;
      }
      throw _mapError(error);
    } finally {
      _selecting = false;
    }
  }

  @override
  Future<void> startScan(
    List<String> serviceUuids,
  ) async => throw const BleException(
    BleErrorCode.unsupported,
    'Browser scanning is not implemented; call selectDevice() from a user gesture',
  );

  // There is no background scan to stop. The browser chooser cannot be dismissed by code.
  @override
  Future<void> stopScan() async => _alive();

  void _current(int generation) {
    if (_disposed || generation != _generation || _gatt?.connected != true) {
      throw const BleException(
        BleErrorCode.disconnected,
        'Browser GATT connection closed',
      );
    }
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      _alive();
      return await action();
    } catch (error) {
      throw _mapError(error);
    }
  }

  @override
  Future<void> connect(String id) => _guard(() async {
    if (_connecting || _selecting || _gatt != null) {
      throw const BleException(
        BleErrorCode.busy,
        'A browser connection or chooser is pending',
      );
    }
    final device = _selected;
    if (device == null || device.id != id) {
      throw const BleException(
        BleErrorCode.permissionDenied,
        'Select this device first; browser device IDs cannot be used without permission',
      );
    }
    final gatt = device.gatt;
    if (gatt == null) {
      throw const BleException(BleErrorCode.unsupported, 'GATT is unavailable');
    }
    final generation = ++_generation;
    _connecting = true;
    _gatt = gatt;
    final listener = ((JSAny? _) {
      if (!_disposed && generation == _generation) _endConnection(emit: true);
    }).toJS;
    _disconnectListener = listener;
    device.addEventListener('gattserverdisconnected', listener);
    try {
      await gatt.connect().toDart;
      if (_disposed || generation != _generation) {
        // New connections remain blocked until this pending attempt settles.
        gatt.disconnect();
      }
      _current(generation);
    } catch (_) {
      if (generation == _generation) _endConnection();
      rethrow;
    } finally {
      _connecting = false;
    }
  });

  @override
  Future<List<BleRemoteCharacteristic>> discover() => _guard(() async {
    final generation = _generation;
    _current(generation);
    final services = await _gatt!.getPrimaryServices().toDart;
    _current(generation);
    final result = <BleRemoteCharacteristic>[];
    for (final service in services.toDart) {
      final characteristics = await service.getCharacteristics().toDart;
      _current(generation);
      for (final characteristic in characteristics.toDart) {
        final p = characteristic.properties;
        final field =
            BleRemoteCharacteristic(service.uuid, characteristic.uuid, {
              if (p.read) BleProperty.read,
              if (p.write) BleProperty.write,
              if (p.notify || p.indicate) BleProperty.notify,
            });
        if (_fields.containsKey(field.key)) {
          throw const BleException(
            BleErrorCode.incompatibleProtocol,
            'Ambiguous browser characteristic',
          );
        }
        _fields[field.key] = characteristic;
        result.add(field);
      }
    }
    return result;
  });

  // Browsers do not expose the negotiated ATT MTU. Use the baseline payload.
  @override
  Future<int> maximumWriteBytes() async => 20;

  BrowserCharacteristic _field(String key) {
    _current(_generation);
    final field = _fields[key];
    if (field == null) {
      throw const BleException(
        BleErrorCode.incompatibleProtocol,
        'Unknown browser characteristic',
      );
    }
    return field;
  }

  List<int> _bytes(JSDataView value) {
    final view = value.toDart;
    return List<int>.of(
      view.buffer.asUint8List(view.offsetInBytes, view.lengthInBytes),
    );
  }

  @override
  Future<List<int>> read(String key) => _guard(() async {
    final generation = _generation;
    final value = await _field(key).readValue().toDart;
    _current(generation);
    return _bytes(value);
  });

  @override
  Future<void> write(String key, List<int> bytes) => _guard(() async {
    final generation = _generation;
    if (bytes.length > 20) {
      throw const BleException(
        BleErrorCode.tooLarge,
        'Use framed messages for browser writes over 20 bytes',
      );
    }
    await _field(
      key,
    ).writeValueWithResponse(Uint8List.fromList(bleBytes(bytes)).toJS).toDart;
    _current(generation);
  });

  @override
  Future<void> subscribe(String key, bool enabled) => _guard(() async {
    final generation = _generation;
    final characteristic = _field(key);
    final old = _listeners.remove(key);
    if (old != null) {
      characteristic.removeEventListener('characteristicvaluechanged', old);
    }
    if (!enabled) {
      await characteristic.stopNotifications().toDart;
      _current(generation);
      return;
    }
    final listener = ((JSAny? _) {
      if (_disposed || generation != _generation) return;
      try {
        final value = characteristic.value;
        if (value == null) {
          throw const FormatException('Notification has no value');
        }
        _notifications.add(BleRawNotification(key, _bytes(value)));
      } catch (error) {
        _notifications.addError(
          BleException(
            BleErrorCode.invalidData,
            'Invalid browser notification',
            error,
          ),
        );
      }
    }).toJS;
    _listeners[key] = listener;
    characteristic.addEventListener('characteristicvaluechanged', listener);
    try {
      await characteristic.startNotifications().toDart;
      _current(generation);
    } catch (_) {
      characteristic.removeEventListener(
        'characteristicvaluechanged',
        listener,
      );
      if (generation == _generation) _listeners.remove(key);
      rethrow;
    }
  });

  void _endConnection({bool emit = false}) {
    _generation++;
    for (final entry in _listeners.entries) {
      _fields[entry.key]?.removeEventListener(
        'characteristicvaluechanged',
        entry.value,
      );
    }
    _listeners.clear();
    _fields.clear();
    final listener = _disconnectListener;
    if (listener != null) {
      _selected?.removeEventListener('gattserverdisconnected', listener);
    }
    _disconnectListener = null;
    final gatt = _gatt;
    _gatt = null;
    gatt?.disconnect();
    if (emit && !_disposed) _disconnected.add(null);
  }

  @override
  Future<void> disconnect() async => _endConnection();

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      _endConnection();
    } finally {
      final listener = _availabilityListener;
      if (listener != null) {
        _bluetooth?.removeEventListener('availabilitychanged', listener);
      }
      _selected = null;
      _bluetooth = null;
      unawaited(_states.close());
      unawaited(_discovered.close());
      unawaited(_disconnected.close());
      unawaited(_notifications.close());
    }
  }
}

String? _errorName(Object error) {
  try {
    return (error as JSObject).getProperty<JSString?>('name'.toJS)?.toDart;
  } catch (_) {
    return null;
  }
}

BleException _mapError(Object error) {
  if (error is BleException) return error;
  final name = _errorName(error);
  final code = switch (name) {
    'SecurityError' || 'NotAllowedError' => BleErrorCode.permissionDenied,
    'NotSupportedError' => BleErrorCode.unsupported,
    'NotFoundError' => BleErrorCode.incompatibleProtocol,
    'NetworkError' || 'InvalidStateError' => BleErrorCode.disconnected,
    'InvalidModificationError' => BleErrorCode.tooLarge,
    'TimeoutError' => BleErrorCode.timeout,
    _ => BleErrorCode.remote,
  };
  return BleException(
    code,
    'Web Bluetooth operation failed${name == null ? '' : ' ($name)'}',
    error,
  );
}

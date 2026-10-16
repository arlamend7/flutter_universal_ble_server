import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:universal_ble_server/testing.dart';
import 'package:universal_ble_server/universal_ble_server.dart';

@JS('navigator')
external JSObject get _navigator;
@JS('Object.defineProperty')
external void _define(JSObject object, String key, JSObject descriptor);
@JS('Object.getOwnPropertyDescriptor')
external JSObject? _descriptor(JSObject object, String key);
@JS('Promise.reject')
external JSPromise<JSObject> _reject(JSAny error);
@JS('EventTarget')
extension type FakeTarget._(JSObject _) implements JSObject {
  external factory FakeTarget();
  external bool dispatchEvent(JSObject event);
}
@JS('Event')
extension type FakeEvent._(JSObject _) implements JSObject {
  external factory FakeEvent(String type);
}
@JS('DOMException')
extension type FakeError._(JSObject _) implements JSObject {
  external factory FakeError(String message, String name);
}

/// Real JS objects/promises/events at the Web Bluetooth boundary. The radio and
/// chooser are simulated; production transport and Dart protocol run unchanged.
class BrowserFixture {
  BrowserFixture(this.platform) {
    _previous = _descriptor(_navigator, 'bluetooth');
    bluetooth['getAvailability'] = (() => Future.value(
      available.toJS,
    ).toJS).toJS;
    bluetooth['requestDevice'] = ((JSObject options) {
      chooserCalls++;
      lastOptions = options.dartify()! as Map<Object?, Object?>;
      if (chooserError != null) {
        return _reject(FakeError('Chooser failed', chooserError!));
      }
      return _choose(options).toJS;
    }).toJS;
    device['id'] = id.toJS;
    device['name'] = 'Advertised name'.toJS;
    device['gatt'] = gatt;
    gatt['connected'] = false.toJS;
    gatt['connect'] = (() => _connect().toJS).toJS;
    gatt['disconnect'] = disconnect.toJS;
    gatt['getPrimaryServices'] = (() => Future.value(
      _services.entries
          .where((e) => _granted.contains(e.key))
          .map((e) => e.value)
          .toList()
          .toJS,
    ).toJS).toJS;
    for (final service in platform.activeProfile!.services) {
      final jsService = JSObject();
      jsService['uuid'] = service.uuid.toJS;
      final characteristics = <JSObject>[];
      for (final field in service.fields) {
        final characteristic = FakeTarget();
        _characteristics[field.uuid] = characteristic;
        characteristic['uuid'] = field.uuid.toJS;
        characteristic['properties'] = {
          'read': field.access.contains(BleProperty.read),
          'write': field.access.contains(BleProperty.write),
          'notify': field.access.contains(BleProperty.notify),
          'indicate': false,
        }.jsify();
        characteristic['readValue'] =
            (() => platform.read(field.uuid, clientId: id).then(_view).toJS)
                .toJS;
        characteristic['writeValueWithResponse'] = ((JSUint8Array value) {
          final bytes = List<int>.of(value.toDart);
          writes.add(bytes);
          return platform
              .write(field.uuid, bytes, clientId: id)
              .then<JSAny?>((_) => null)
              .toJS;
        }).toJS;
        characteristic['startNotifications'] = (() {
          if (subscriptionError != null) {
            return _reject(
              FakeError('Subscription failed', subscriptionError!),
            );
          }
          _subscribed.add(field.uuid);
          platform.subscribe(field.uuid, id);
          return Future<JSObject>.value(characteristic).toJS;
        }).toJS;
        characteristic['stopNotifications'] = (() {
          _subscribed.remove(field.uuid);
          platform.unsubscribe(field.uuid, id);
          return Future.value(characteristic).toJS;
        }).toJS;
        characteristics.add(characteristic);
      }
      jsService['getCharacteristics'] = (() => Future.value(
        characteristics.toJS,
      ).toJS).toJS;
      _services[service.uuid] = jsService;
    }
    _notifications = platform.notificationEvents.listen((event) {
      final uuid = event['uuid']! as String;
      if (!connected ||
          !_subscribed.contains(uuid) ||
          (event['clientId'] != null && event['clientId'] != id)) {
        return;
      }
      final characteristic = _characteristics[uuid]!;
      characteristic['value'] = _view(event['value']! as List<int>);
      characteristic.dispatchEvent(FakeEvent('characteristicvaluechanged'));
    });
    install();
  }

  static const id = 'browser-peer';
  final SimulatedBlePlatform platform;
  final bluetooth = FakeTarget(), device = FakeTarget();
  final gatt = JSObject();
  final _services = <String, JSObject>{};
  final _characteristics = <String, FakeTarget>{};
  final _subscribed = <String>{}, _granted = <String>{};
  final writes = <List<int>>[];
  late final StreamSubscription<Map<String, Object>> _notifications;
  JSObject? _previous;
  Map<Object?, Object?>? lastOptions;
  bool available = true;
  int chooserCalls = 0;
  String? chooserError, subscriptionError;
  Completer<void>? chooserGate, connectGate;
  final connectStarted = Completer<void>();
  bool get connected => gatt.getProperty<JSBoolean>('connected'.toJS).toDart;

  void install({bool supported = true}) => _define(
    _navigator,
    'bluetooth',
    {'configurable': true, 'value': supported ? bluetooth : null}.jsify()!
        as JSObject,
  );

  Future<JSObject> _choose(JSObject options) async {
    if (chooserGate != null) await chooserGate!.future;
    final filters = lastOptions!['filters'] as List<Object?>? ?? [];
    _granted.clear();
    for (final filter in filters.cast<Map<Object?, Object?>>()) {
      _granted.addAll((filter['services']! as List<Object?>).cast<String>());
    }
    _granted.addAll(
      (lastOptions!['optionalServices']! as List<Object?>).cast<String>(),
    );
    return device;
  }

  Future<JSObject> _connect() async {
    if (!connectStarted.isCompleted) connectStarted.complete();
    if (connectGate != null) await connectGate!.future;
    gatt['connected'] = true.toJS;
    platform.connect(id);
    return gatt;
  }

  void disconnect() {
    if (!connected) return;
    gatt['connected'] = false.toJS;
    _subscribed.clear();
    platform.disconnect(id);
    device.dispatchEvent(FakeEvent('gattserverdisconnected'));
  }

  void setAvailable(bool value) {
    available = value;
    final event = FakeEvent('availabilitychanged');
    event['value'] = value.toJS;
    bluetooth.dispatchEvent(event);
  }

  // Nonzero offsets catch accidental copies of the entire underlying buffer.
  JSDataView _view(List<int> bytes) {
    final padded = Uint8List.fromList([99, ...bytes, 98]);
    return ByteData.view(padded.buffer, 1, bytes.length).toJS;
  }

  Future<void> dispose() async {
    await _notifications.cancel();
    final previous = _previous;
    if (previous == null) {
      _navigator.delete('bluetooth'.toJS);
    } else {
      _define(_navigator, 'bluetooth', previous);
    }
  }
}

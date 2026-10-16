// Internal, typed browser bindings. No JavaScript evaluation or BLE dependency.
import 'dart:js_interop';

@JS('navigator.bluetooth')
external BrowserBluetooth? get browserBluetooth;
@JS('isSecureContext')
external bool get browserIsSecureContext;

extension type BrowserEventTarget(JSObject _) implements JSObject {
  external void addEventListener(String type, JSFunction listener);
  external void removeEventListener(String type, JSFunction listener);
}

extension type BrowserBluetooth(JSObject _) implements BrowserEventTarget {
  external JSPromise<JSBoolean> getAvailability();
  external JSPromise<BrowserDevice> requestDevice(
    BrowserRequestOptions options,
  );
}

extension type BrowserRequestOptions._(JSObject _) implements JSObject {
  external factory BrowserRequestOptions({
    JSArray<BrowserServiceFilter>? filters,
    bool? acceptAllDevices,
    JSArray<JSString>? optionalServices,
  });
}

extension type BrowserServiceFilter._(JSObject _) implements JSObject {
  external factory BrowserServiceFilter({required JSArray<JSString> services});
}

extension type BrowserDevice(JSObject _) implements BrowserEventTarget {
  external String get id;
  external String? get name;
  external BrowserGatt? get gatt;
}

extension type BrowserGatt(JSObject _) implements JSObject {
  external bool get connected;
  external JSPromise<BrowserGatt> connect();
  external void disconnect();
  external JSPromise<JSArray<BrowserService>> getPrimaryServices();
}

extension type BrowserService(JSObject _) implements JSObject {
  external String get uuid;
  external JSPromise<JSArray<BrowserCharacteristic>> getCharacteristics();
}

extension type BrowserCharacteristic(JSObject _) implements BrowserEventTarget {
  external String get uuid;
  external BrowserProperties get properties;
  external JSDataView? get value;
  external JSPromise<JSDataView> readValue();
  external JSPromise<JSAny?> writeValueWithResponse(JSUint8Array bytes);
  external JSPromise<BrowserCharacteristic> startNotifications();
  external JSPromise<BrowserCharacteristic> stopNotifications();
}

extension type BrowserProperties(JSObject _) implements JSObject {
  external bool get read;
  external bool get write;
  external bool get notify;
  external bool get indicate;
}

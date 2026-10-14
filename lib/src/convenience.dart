import 'client/client.dart';
import 'client/message_client.dart';
import 'client/transport.dart';
import 'communication.dart';
import 'message_server.dart';
import 'profile.dart';
import '../universal_ble_server_impl.dart';

/// Common message-server operations without exposing the underlying GATT server.
extension BleMessageServerConvenience on BleMessageServer {
  /// Requests OS permission, verifies readiness and begins advertising.
  Future<void> startWithPermissions() async {
    (await requestPermissions()).requireCompatible();
    await start();
  }

  /// Reads a custom field's local value without making a Bluetooth request.
  T readStoredValue<T>(BleField<T> field) => gatt.readStoredValue(field);

  /// Stores a value and optionally notifies subscribers. Notifications must fit
  /// each recipient's payload limit; use complete messages for larger data.
  Future<void> updateStoredValue<T>(
    BleField<T> field,
    T value, {
    bool notify = false,
  }) => gatt.updateStoredValue(field, value, notify: notify);

  /// Sends a complete byte reply only to the original sender.
  Future<void> replyBytes(BleReceivedMessage message, List<int> bytes) =>
      sendBytes(bytes, clientId: message.clientId);

  /// Sends a UTF-8 reply only to the original sender.
  Future<void> replyText(BleReceivedMessage message, String text) =>
      sendText(text, clientId: message.clientId);

  /// Sends a JSON reply only to the original sender.
  Future<void> replyJson(BleReceivedMessage message, Object? value) =>
      sendJson(value, clientId: message.clientId);

  /// Forwards unchanged bytes to [clientId], or to everyone except the sender.
  /// Throws if no recipient is subscribed. Does not retain sender identity in
  /// the payload: use an application envelope when recipients need that detail.
  /// IDs are connection-local; applications must authorize routing themselves.
  Future<void> forward(BleReceivedMessage message, {String? clientId}) =>
      sendBytes(
        message.data,
        clientId: clientId,
        excludeClientId: clientId == null ? message.clientId : null,
      );
}

/// Explicit permission-and-start helper for custom GATT servers.
extension UniversalBleServerConvenience on UniversalBleServer {
  /// Requests OS permission, verifies readiness and begins advertising.
  Future<void> startWithPermissions() async {
    (await requestPermissions()).requireCompatible();
    await start();
  }
}

/// Typed fields and finite discovery on the same connection as complete messages.
extension BleMessageClientConvenience on BleMessageClient {
  /// Scans for this message protocol and returns one latest result per device.
  /// No device is connected automatically. The scan stops after [duration].
  /// Set [requestPermissions] to false to manage permission prompts separately.
  Future<List<BleDiscoveredServer>> discover({
    Duration duration = const Duration(seconds: 3),
    bool requestPermissions = true,
    int maxResults = 256,
  }) => client.discover(
    serviceUuids: [configuration.serviceUuid],
    duration: duration,
    requestPermissions: requestPermissions,
    maxResults: maxResults,
  );

  /// Reads and decodes one custom field from the connected server.
  Future<T> readValue<T>(BleFieldDefinition<T> field) =>
      client.readValue(field);

  /// Writes one custom field with a response. The value must fit the peer limit.
  Future<void> writeValue<T>(BleFieldDefinition<T> field, T value) =>
      client.writeValue(field, value);

  /// Subscribes to a typed field. Listen to the returned stream and cancel that
  /// subscription when finished; the last watcher releases the native resource.
  Future<Stream<T>> watchValue<T>(BleFieldDefinition<T> field) =>
      client.watchValue(field);

  /// Combines multiple fields into one stream, retaining each field's identity.
  Stream<BleFieldUpdate> watchValues(
    List<BleFieldDefinition<dynamic>> fields,
  ) => client.watchValues(fields);
}

/// Readiness checks without a top-level helper function.
extension BleAdapterStateConvenience on BleAdapterState {
  /// Throws a typed [BleException] unless Bluetooth is supported and ready.
  void requireReady() => requireClientReady(this);
}

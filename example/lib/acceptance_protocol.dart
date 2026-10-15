import 'dart:async';
import 'dart:convert';

import 'package:universal_ble_server/universal_ble_server.dart';

/// Isolated test protocol shared by the native runner and regression tests.
BleMessageConfiguration acceptanceConfiguration(String run) {
  if (run.isEmpty || run.length > 32) {
    throw ArgumentError('BLE_TEST_RUN must contain 1–32 characters');
  }
  return BleMessageConfiguration(
    serviceUuid: '82600000-81aa-4d42-a571-1cbe2b21a660',
    clientToServerUuid: '82600001-81aa-4d42-a571-1cbe2b21a660',
    serverToClientUuid: '82600002-81aa-4d42-a571-1cbe2b21a660',
    nameUuid: '82600003-81aa-4d42-a571-1cbe2b21a660',
    metadataUuid: '82600004-81aa-4d42-a571-1cbe2b21a660',
    protocol: 'acceptance-$run',
  );
}

final acceptanceField = BleFieldDefinition(
  serviceUuid: '82600010-81aa-4d42-a571-1cbe2b21a660',
  uuid: '82600011-81aa-4d42-a571-1cbe2b21a660',
  codec: BleCodecs.uint16LittleEndian,
  access: {BleProperty.read, BleProperty.write, BleProperty.notify},
);

/// Test-only envelope: kind:u8, token:16 ASCII bytes, body:arbitrary bytes.
/// Kind 0 requests a private echo, 1 a broadcast, 2 a field update + echo, and
/// 3 a barrier: reply to each client once the requested peer count has arrived.
List<int> acceptancePacket(int kind, String token, List<int> body) {
  final encoded = ascii.encode(token);
  if (encoded.length != 16 || kind < 0 || kind > 3) {
    throw ArgumentError('Invalid acceptance packet');
  }
  return [kind, ...encoded, ...body];
}

/// Native host fixture, also exercised with injected transports in unit tests.
/// The fixture is deliberately unauthenticated; use only trusted test devices.
class AcceptanceHost {
  AcceptanceHost({
    required String run,
    required this.log,
    UniversalBleServerPlatform? platform,
    Duration assemblyTimeout = const Duration(seconds: 10),
  }) {
    field = acceptanceField.bind(initialValue: 7);
    server = BleMessageServer(
      name: 'BLE acceptance',
      configuration: acceptanceConfiguration(run),
      platform: platform,
      assemblyTimeout: assemblyTimeout,
      additionalServices: [
        BleService(uuid: acceptanceField.serviceUuid, fields: [field]),
      ],
    );
    // Serial processing keeps field updates and the corresponding replies ordered.
    _messages = server.receivedMessages
        .asyncMap(_handle)
        .listen((_) {}, onError: (Object error) => log('FAIL: $error'));
    _errors = server.errors.listen((error) => log('FAIL: $error'));
    _clients = server.clientEvents.listen((event) {
      if (event.kind == BleClientEventKind.disconnected ||
          event.kind == BleClientEventKind.unsubscribed) {
        _waiting.remove(event.clientId);
        if (_waiting.isEmpty) _expectedPeers = null;
      }
      log('${event.kind.name}: ${event.clientId}');
    });
  }

  final void Function(String) log;
  late final BleField<int> field;
  late final BleMessageServer server;
  late final StreamSubscription<void> _messages;
  late final StreamSubscription<Object> _errors;
  late final StreamSubscription<BleClientEvent> _clients;
  final _waiting = <String, BleReceivedMessage>{};
  int? _expectedPeers;

  Future<void> _handle(BleReceivedMessage message) async {
    final bytes = message.data;
    if (bytes.length < 17) throw const FormatException('Missing test envelope');
    switch (bytes.first) {
      case 0:
        await server.replyBytes(message, bytes);
      case 3:
        if (bytes.length != 18 || bytes[17] < 1 || bytes[17] > 16) {
          throw const FormatException('Expected 1–16 test clients');
        }
        if (_expectedPeers != null && _expectedPeers != bytes[17]) {
          throw const FormatException(
            'Clients configured different peer counts',
          );
        }
        _expectedPeers = bytes[17];
        _waiting[message.clientId] = message;
        if (_waiting.length == _expectedPeers) {
          final ready = _waiting.values.toList();
          _waiting.clear();
          _expectedPeers = null;
          for (final peer in ready) {
            await server.replyBytes(peer, peer.data);
          }
        }
      case 1:
        await server.sendBytes(bytes);
      case 2:
        if (bytes.length != 19) {
          throw const FormatException('Expected a uint16 field update');
        }
        await server.updateStoredValue(
          field,
          bytes[17] | (bytes[18] << 8),
          notify: true,
        );
        await server.replyBytes(message, bytes);
      default:
        throw const FormatException('Unknown acceptance operation');
    }
    log('Handled ${bytes.length} bytes from ${message.clientId}');
  }

  Future<void> start() => server.startWithPermissions();

  Future<void> dispose() async {
    _waiting.clear();
    await _messages.cancel();
    await _errors.cancel();
    await _clients.cancel();
    await server.dispose();
  }
}

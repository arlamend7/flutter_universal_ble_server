import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble_server/universal_ble_server.dart';
import 'package:universal_ble_server/testing.dart';

Future<void> deliverEvents() => Future<void>.delayed(Duration.zero);

void main() {
  late SimulatedBlePlatform adapter;
  late BleMessageServer server;
  setUp(() {
    adapter = SimulatedBlePlatform();
    server = BleMessageServer(name: 'Teste BLE', platform: adapter);
  });
  tearDown(() async {
    await server.dispose();
    await adapter.dispose();
  });

  test(
    'profile carries name policies and exposes readable logical name',
    () async {
      await server.start();
      expect(adapter.activeProfile!.toMap()['name'], 'Teste BLE');
      expect(
        utf8.decode(await adapter.read(BleMessageProtocol.serverNameUuid)),
        'Teste BLE',
      );
      expect(() => BleMessageServer(name: 'é' * 15), throwsArgumentError);
      expect(() => BleMessageServer(name: ''), throwsArgumentError);
    },
  );
  test('receives complete UTF-8 messages from interleaved clients', () async {
    await server.start();
    final messages = <BleReceivedMessage>[];
    final subscription = server.receivedMessages.listen(messages.add);
    final a = BleMessageFramer.encode(
      utf8.encode('Olá, mensagem suficientemente longa!'),
      messageId: 10,
      maxFrameBytes: 20,
    );
    final b = BleMessageFramer.encode([99], messageId: 10, maxFrameBytes: 20);
    await adapter.write(
      BleMessageProtocol.clientToServerUuid,
      a.first,
      clientId: 'a',
    );
    await adapter.write(
      BleMessageProtocol.clientToServerUuid,
      b.single,
      clientId: 'b',
    );
    for (final frame in a.skip(1)) {
      await adapter.write(
        BleMessageProtocol.clientToServerUuid,
        frame,
        clientId: 'a',
      );
    }
    await deliverEvents();
    expect(messages.map((e) => e.clientId), ['b', 'a']);
    expect(messages.last.text, 'Olá, mensagem suficientemente longa!');
    await subscription.cancel();
  });
  test(
    'fragments outgoing messages and targets subscribed clients only',
    () async {
      await server.start();
      adapter.subscribe(BleMessageProtocol.serverToClientUuid, 'a');
      adapter.subscribe(BleMessageProtocol.serverToClientUuid, 'b');
      await deliverEvents();
      final bytes = List.generate(1000, (i) => i % 256);
      await server.sendBytes(bytes, clientId: 'a');
      final assembler = BleMessageAssembler();
      List<int>? received;
      for (final event in adapter.notifications) {
        expect(event['clientId'], 'a');
        final frame = event['value'] as List<int>;
        expect(frame.length, lessThanOrEqualTo(20));
        received = assembler.add(frame);
      }
      expect(received, bytes);
      await expectLater(
        server.sendBytes([1], clientId: 'absent'),
        throwsStateError,
      );
    },
  );
  test('legacy message API interoperates with the descriptive names', () async {
    final messages = <BleReceivedMessage>[];
    final legacyMessages = <BleReceivedMessage>[];
    final clients = <BleClientEvent>[];
    final legacyClients = <BleClientEvent>[];
    final subscriptions = <StreamSubscription<dynamic>>[
      server.receivedMessages.listen(messages.add),
      server.received.listen(legacyMessages.add),
      server.clientEvents.listen(clients.add),
      server.clients.listen(legacyClients.add),
    ];
    await server.start();
    adapter.subscribe(BleMessageProtocol.transmit, 'a');
    await deliverEvents();
    expect(server.subscribedClientIds, {'a'});
    expect(server.readyClients, server.subscribedClientIds);
    await server.send([42], clientId: 'a');
    await server.sendText('Hi', clientId: 'a');
    for (final notification in adapter.notifications) {
      await adapter.write(
        BleMessageProtocol.receive,
        notification['value'] as List<int>,
        clientId: 'a',
      );
    }
    await deliverEvents();
    expect(messages.map((m) => m.data), [
      [42],
      [72, 105],
    ]);
    expect(legacyMessages, messages);
    expect(legacyClients, clients);
    expect(clients.single.kind, BleClientEventKind.subscribed);
    expect(BleMessageProtocol.service, BleMessageProtocol.serviceUuid);
    expect(BleMessageProtocol.name, BleMessageProtocol.serverNameUuid);
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  });

  test('concurrent sends cannot interleave frames', () async {
    await server.start();
    adapter.subscribe(BleMessageProtocol.serverToClientUuid, 'a');
    await deliverEvents();
    await Future.wait([
      server.sendBytes(List.filled(50, 1)),
      server.sendBytes(List.filled(50, 2)),
    ]);
    final assembler = BleMessageAssembler();
    final result = <List<int>>[];
    for (final event in adapter.notifications) {
      final data = assembler.add(event['value'] as List<int>);
      if (data != null) result.add(data);
    }
    expect(result, [List.filled(50, 1), List.filled(50, 2)]);
  });
  test('disconnect removes channel readiness and incomplete data', () async {
    await server.start();
    adapter.subscribe(BleMessageProtocol.serverToClientUuid, 'a');
    await deliverEvents();
    final errors = <Object>[];
    final sub = server.errors.listen(errors.add);
    final frames = BleMessageFramer.encode(
      List.filled(50, 1),
      messageId: 1,
      maxFrameBytes: 20,
    );
    await adapter.write(
      BleMessageProtocol.clientToServerUuid,
      frames.first,
      clientId: 'a',
    );
    adapter.disconnect('a');
    await deliverEvents();
    expect(server.subscribedClientIds, isEmpty);
    await expectLater(server.sendBytes([1]), throwsStateError);
    await adapter.write(
      BleMessageProtocol.clientToServerUuid,
      frames[1],
      clientId: 'a',
    );
    await deliverEvents();
    expect(errors.single, isA<FormatException>());
    await sub.cancel();
  });
  test('rejects oversized and malformed fragment writes', () async {
    await server.start();
    await expectLater(
      adapter.write(BleMessageProtocol.clientToServerUuid, [1, 2]),
      throwsA(isA<BleRequestException>()),
    );
    await expectLater(
      adapter.write(BleMessageProtocol.clientToServerUuid, List.filled(21, 0)),
      throwsA(isA<BleRequestException>()),
    );
    await expectLater(
      server.sendBytes(List.filled(65536, 1)),
      throwsArgumentError,
    );
  });
  test('incomplete messages expire and resources are released', () async {
    await server.dispose();
    server = BleMessageServer(
      name: 'Timeout',
      platform: adapter,
      assemblyTimeout: const Duration(milliseconds: 20),
    );
    await server.start();
    final error = server.errors.first;
    final frame = BleMessageFramer.encode(
      List.filled(50, 1),
      messageId: 1,
      maxFrameBytes: 20,
    ).first;
    await adapter.write(BleMessageProtocol.clientToServerUuid, frame);
    expect(await error, isA<TimeoutException>());
    await server.stop();
    expect(server.state, BleServerState.stopped);
  });
  test(
    'broadcast snapshots subscribers and preserves both complete payloads',
    () async {
      await server.start();
      adapter.subscribe(BleMessageProtocol.serverToClientUuid, 'a');
      adapter.subscribe(BleMessageProtocol.serverToClientUuid, 'b');
      await deliverEvents();
      final sending = server.sendBytes(List.filled(60, 7));
      adapter.subscribe(BleMessageProtocol.serverToClientUuid, 'late');
      await sending;
      expect(adapter.notifications.map((e) => e['clientId']).toSet(), {
        'a',
        'b',
      });
      for (final id in ['a', 'b']) {
        final assembler = BleMessageAssembler();
        List<int>? value;
        for (final frame in adapter.notifications.where(
          (e) => e['clientId'] == id,
        )) {
          value = assembler.add(frame['value'] as List<int>);
        }
        expect(value, List.filled(60, 7));
      }
    },
  );

  test(
    'stop invalidates queued sends instead of sending to a later session',
    () async {
      await server.start();
      adapter.subscribe(BleMessageProtocol.serverToClientUuid, 'a');
      await deliverEvents();
      final sending = server.sendBytes(List.filled(60, 1));
      final expectation = expectLater(sending, throwsStateError);
      await server.stop();
      await expectation;
      await server.start();
      expect(server.subscribedClientIds, isEmpty);
    },
  );
}

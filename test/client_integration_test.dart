import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble_server/universal_ble_server.dart';
import 'package:universal_ble_server/testing.dart';

void main() {
  late SimulatedBlePlatform platform;
  late BleMessageServer server;
  late BleMessageClient a, b;
  late BleFieldDefinition<int> temperature;
  late BleField<int> storedTemperature;
  setUp(() async {
    platform = SimulatedBlePlatform();
    temperature = BleFieldDefinition(
      serviceUuid: 'abcd',
      uuid: 'abce',
      codec: BleCodecs.uint16LittleEndian,
      access: {BleProperty.read, BleProperty.write, BleProperty.notify},
    );
    storedTemperature = temperature.bind(initialValue: 25);
    server = BleMessageServer(
      name: 'Integration',
      platform: platform,
      additionalServices: [
        BleService(uuid: temperature.serviceUuid, fields: [storedTemperature]),
      ],
    );
    a = BleMessageClient(
      client: UniversalBleClient(
        transport: SimulatedBleClientTransport(platform, clientId: 'a'),
      ),
    );
    b = BleMessageClient(
      client: UniversalBleClient(
        transport: SimulatedBleClientTransport(platform, clientId: 'b'),
      ),
    );
    await server.start();
  });
  tearDown(() async {
    await a.dispose();
    await b.dispose();
    await server.dispose();
    await platform.dispose();
  });
  test('expired authorization cannot invoke the application handler', () async {
    var handled = 0;
    final host = BleSessionServer(
      server: server,
      applicationProtocol: 'deadline',
      handlerTimeout: const Duration(milliseconds: 20),
      authorize: (_, method, _) async {
        if (method == 'slow') {
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }
        return true;
      },
      handlers: {
        'slow': (_, _, _) {
          handled++;
          return null;
        },
      },
    );
    final guest = BleSessionClient(client: a, applicationProtocol: 'deadline');
    try {
      await a.connect('server');
      await guest.open();
      await expectLater(
        guest.request('slow', null),
        throwsA(isA<BleException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(handled, 0);
    } finally {
      await guest.dispose();
      await host.dispose();
    }
  });
  test(
    'two clients discover, verify protocol, exchange fragmented and targeted messages',
    () async {
      final discovered = a.discoveredServers.first;
      await a.startScan();
      expect((await discovered).name, 'Integration');
      await a.connect('server');
      await b.connect('server');
      expect(a.state, BleConnectionState.ready);
      expect(a.serverName, 'Integration');
      final incoming = server.receivedMessages.first;
      await a.sendText('Hello ' * 100);
      expect((await incoming).text, 'Hello ' * 100);
      final receivedA = <String>[];
      final receivedB = <String>[];
      final sa = a.receivedText.listen(receivedA.add),
          sb = b.receivedText.listen(receivedB.add);
      await server.sendText('both');
      await server.sendText('private', clientId: 'a');
      await Future<void>.delayed(Duration.zero);
      expect(receivedA, ['both', 'private']);
      expect(receivedB, ['both']);
      await sa.cancel();
      await sb.cancel();
    },
  );
  test(
    'shared typed field supports read/write and reference-counted watching alongside messages',
    () async {
      await a.connect('server');
      expect(await a.client.readValue(temperature), 25);
      final stream1 = await a.client.watchValue(temperature);
      final stream2 = await a.client.watchValue(temperature);
      final values = <int>[];
      final sub1 = stream1.listen(values.add);
      final sub2 = stream2.listen(values.add);
      await server.gatt.updateStoredValue(storedTemperature, 30, notify: true);
      await Future<void>.delayed(Duration.zero);
      expect(values, [30, 30]);
      await sub1.cancel();
      expect(platform.subscribers[temperature.uuid], {'a'});
      await a.client.writeValue(temperature, 40);
      expect(server.gatt.readStoredValue(storedTemperature), 40);
      await sub2.cancel();
      expect(platform.subscribers[temperature.uuid], isEmpty);
    },
  );
  test(
    'protocol mismatch fails before ready; raw writes enforce negotiated limit',
    () async {
      final wrong = BleMessageClient(
        configuration: BleMessageConfiguration(version: 2),
        client: UniversalBleClient(
          transport: SimulatedBleClientTransport(platform, clientId: 'wrong'),
        ),
      );
      await expectLater(wrong.connect('server'), throwsA(isA<BleException>()));
      expect(wrong.state, isNot(BleConnectionState.ready));
      await wrong.dispose();
      await a.connect('server');
      final raw = a.configuration.field(a.configuration.clientToServerUuid, {
        BleProperty.write,
      });
      await expectLater(
        a.client.writeValue(raw, List.filled(21, 1)),
        throwsA(isA<BleException>()),
      );
    },
  );
  test(
    'sessions authorize, limit admission, project private state and resume after reconnect',
    () async {
      final host = BleSessionServer(
        server: server,
        applicationProtocol: 'test',
        maxSessions: 2,
        authenticate: (credentials) =>
            credentials is String ? credentials : null,
        authorize: (_, method, _) => method != 'forbidden',
        projectState: (s, state) => {'owner': s.principal, 'state': state},
        handlers: {'echo': (peer, method, p) => p},
        onAcknowledgedMessage: (_, p) => {'processed': p},
      );
      final sa = BleSessionClient(
        client: a,
        applicationProtocol: 'test',
        credentials: 'alice',
      );
      final sb = BleSessionClient(
        client: b,
        applicationProtocol: 'test',
        credentials: 'bob',
      );
      await a.connect('server');
      await sa.open();
      await b.connect('server');
      await sb.open();
      expect(host.sessions.length, 2);
      expect(await sa.request('echo', {'x': 2}), {'x': 2});
      await expectLater(
        sa.request('forbidden', null),
        throwsA(isA<BleException>()),
      );
      expect(await sa.sendAcknowledged('action'), {'processed': 'action'});
      final future = sa.sharedState.firstWhere((s) => s.revision == 1);
      await host.updateSharedState({'turn': 1});
      expect((await future).value, {
        'owner': 'alice',
        'state': {'turn': 1},
      });
      final id = sa.sessionId;
      await a.disconnect();
      await Future<void>.delayed(Duration.zero);
      await a.connect('server');
      await sa.open();
      expect(sa.sessionId, id);
      expect(host.sessions.length, 2);
      await sa.dispose();
      await sb.dispose();
      await host.dispose();
    },
  );
  test(
    'admission rejects invalid credentials, extra sessions, and a stolen token with another principal',
    () async {
      final host = BleSessionServer(
        server: server,
        applicationProtocol: 'admission',
        maxSessions: 1,
        authenticate: (p) => p == 'alice' || p == 'bob' ? p as String : null,
      );
      final sa = BleSessionClient(
        client: a,
        applicationProtocol: 'admission',
        credentials: 'alice',
      );
      await a.connect('server');
      await sa.open();
      final sb = BleSessionClient(
        client: b,
        applicationProtocol: 'admission',
        credentials: 'bob',
      );
      await b.connect('server');
      await expectLater(sb.open(), throwsA(isA<BleException>()));
      expect(host.sessions.length, 1);
      await a.disconnect();
      await Future<void>.delayed(Duration.zero);
      sb.resumeToken = sa.resumeToken;
      await expectLater(sb.open(), throwsA(isA<BleException>()));
      await sb.dispose();
      final rejected = BleSessionClient(
        client: b,
        applicationProtocol: 'admission',
        credentials: 'invalid',
      );
      await expectLater(rejected.open(), throwsA(isA<BleException>()));
      expect(host.sessions.single.principal, 'alice');
      await rejected.dispose();
      await sa.dispose();
      await host.dispose();
    },
  );

  test(
    'explicit command ID survives reconnect without re-executing an admitted request',
    () async {
      var calls = 0;
      final host = BleSessionServer(
        server: server,
        applicationProtocol: 'resume',
        handlers: {'increment': (session, method, payload) => ++calls},
      );
      final session = BleSessionClient(
        client: a,
        applicationProtocol: 'resume',
      );
      await a.connect('server');
      await session.open();
      expect(
        await session.request('increment', null, requestId: 'persistent-42'),
        1,
      );
      await a.disconnect();
      await Future<void>.delayed(Duration.zero);
      await a.connect('server');
      await session.open();
      expect(
        await session.request('increment', null, requestId: 'persistent-42'),
        1,
      );
      expect(calls, 1);
      await session.dispose();
      await host.dispose();
    },
  );

  test(
    'automatic reconnect restores field and message subscriptions',
    () async {
      final client = BleMessageClient(
        client: UniversalBleClient(
          reconnect: const BleReconnectPolicy(
            attempts: 2,
            delay: Duration(milliseconds: 5),
          ),
          transport: SimulatedBleClientTransport(platform, clientId: 'retry'),
        ),
      );
      await client.connect('server');
      final nextReady = client.stateChanges.firstWhere(
        (s) => s == BleConnectionState.ready,
      );
      platform.disconnect('retry');
      await nextReady.timeout(const Duration(seconds: 2));
      final message = client.receivedText.first;
      await server.sendText('again', clientId: 'retry');
      expect(await message, 'again');
      await client.dispose();
    },
  );
}

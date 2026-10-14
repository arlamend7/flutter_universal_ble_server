import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble_server/universal_ble_server.dart';
import 'package:universal_ble_server/testing.dart';

class DelayedConnect extends SimulatedBleClientTransport {
  DelayedConnect(super.server);
  final gate = Completer<void>();
  int discoveries = 0;
  @override
  Future<void> connect(String id) async {
    await super.connect(id);
    await gate.future;
  }

  @override
  Future<List<BleRemoteCharacteristic>> discover() {
    discoveries++;
    return super.discover();
  }
}

void main() {
  test(
    'combined watches close on client disposal and empty watch lists complete',
    () async {
      final platform = SimulatedBlePlatform();
      final definition = BleFieldDefinition(
        serviceUuid: 'abcd',
        uuid: 'abce',
        codec: BleCodecs.bytes,
        access: {BleProperty.read, BleProperty.notify},
      );
      final server = UniversalBleServer(
        platform: platform,
        profile: BleProfile(
          services: [
            BleService(
              uuid: 'abcd',
              fields: [
                definition.bind(initialValue: [1]),
              ],
            ),
          ],
        ),
      );
      final client = UniversalBleClient(
        transport: SimulatedBleClientTransport(platform),
      );
      await server.start();
      await client.connect('server');
      await client.watchValues([]).drain<void>();
      final completed = client.watchValues([definition]).drain<void>();
      await Future<void>.delayed(Duration.zero);
      await client.dispose();
      await completed;
      await server.dispose();
      await platform.dispose();
    },
  );

  test(
    'simultaneous connect calls cannot enqueue a second connection',
    () async {
      final platform = SimulatedBlePlatform();
      final server = BleMessageServer(name: 'Busy', platform: platform);
      await server.start();
      final transport = DelayedConnect(platform);
      final client = UniversalBleClient(transport: transport);
      try {
        final first = client.connect('server');
        await expectLater(
          client.connect('server'),
          throwsA(
            isA<BleException>().having(
              (e) => e.code,
              'code',
              BleErrorCode.busy,
            ),
          ),
        );
        transport.gate.complete();
        await first;
        expect(transport.discoveries, 1);
      } finally {
        await client.dispose();
        await server.dispose();
        await platform.dispose();
      }
    },
  );
  test(
    'late connect completion after timeout cannot discover services or become ready',
    () async {
      final platform = SimulatedBlePlatform();
      final server = BleMessageServer(name: 'Late', platform: platform);
      await server.start();
      final transport = DelayedConnect(platform);
      final client = UniversalBleClient(
        transport: transport,
        timeout: const Duration(milliseconds: 15),
      );
      await expectLater(
        client.connect('server'),
        throwsA(
          isA<BleException>().having(
            (e) => e.code,
            'code',
            BleErrorCode.timeout,
          ),
        ),
      );
      transport.gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(client.state, BleConnectionState.disconnected);
      expect(transport.discoveries, 0);
      await client.dispose();
      await server.dispose();
      await platform.dispose();
    },
  );
  test(
    'manual disconnect during setup invalidates the pending connection',
    () async {
      final platform = SimulatedBlePlatform();
      final server = BleMessageServer(name: 'Cancel', platform: platform);
      await server.start();
      final transport = DelayedConnect(platform);
      final client = UniversalBleClient(transport: transport);
      final pending = client.connect('server');
      final expectation = expectLater(pending, throwsA(isA<BleException>()));
      await Future<void>.delayed(Duration.zero);
      await client.disconnect();
      transport.gate.complete();
      await expectation;
      expect(client.state, BleConnectionState.disconnected);
      expect(transport.discoveries, 0);
      await client.dispose();
      await server.dispose();
      await platform.dispose();
    },
  );
  test(
    'watchValues identifies fields and removes all native subscriptions on cancel',
    () async {
      final platform = SimulatedBlePlatform();
      final first = BleFieldDefinition(
        serviceUuid: 'abcd',
        uuid: 'abce',
        codec: BleCodecs.uint16LittleEndian,
        access: {BleProperty.read, BleProperty.notify},
      );
      final second = BleFieldDefinition(
        serviceUuid: 'abcd',
        uuid: 'abcf',
        codec: BleCodecs.utf8String,
        access: {BleProperty.read, BleProperty.notify},
      );
      final a = first.bind(initialValue: 1),
          b = second.bind(initialValue: 'ready');
      final server = UniversalBleServer(
        platform: platform,
        profile: BleProfile(
          services: [
            BleService(uuid: 'abcd', fields: [a, b]),
          ],
        ),
      );
      final client = UniversalBleClient(
        transport: SimulatedBleClientTransport(platform),
      );
      await server.start();
      await client.connect('server');
      final updates = <BleFieldUpdate>[];
      final sub = client.watchValues([first, second]).listen(updates.add);
      await Future<void>.delayed(Duration.zero);
      await server.updateStoredValue(a, 2, notify: true);
      await server.updateStoredValue(b, 'running', notify: true);
      await Future<void>.delayed(Duration.zero);
      expect(updates.map((e) => e.field.uuid), [first.uuid, second.uuid]);
      expect(updates.map((e) => e.value), [2, 'running']);
      await sub.cancel();
      expect(platform.subscribers.values.every((s) => s.isEmpty), isTrue);
      await client.dispose();
      await server.dispose();
      await platform.dispose();
    },
  );
}

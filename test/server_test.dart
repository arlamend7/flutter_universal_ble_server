import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble_server/universal_ble_server.dart';
import 'package:universal_ble_server/testing.dart';

void main() {
  late SimulatedBlePlatform platform;
  late BleField<int> interval;
  late UniversalBleServer server;
  setUp(() {
    platform = SimulatedBlePlatform();
    interval = BleField<int>(
      uuid: 'abce',
      codec: BleCodecs.uint16LittleEndian,
      initialValue: 30,
      access: {BleProperty.read, BleProperty.write, BleProperty.notify},
      validate: (v) => v >= 1 && v <= 3600,
    );
    server = UniversalBleServer(
      platform: platform,
      profile: BleProfile(
        services: [
          BleService(uuid: 'abcd', fields: [interval]),
        ],
      ),
    );
  });
  tearDown(() async {
    await server.dispose();
    await platform.dispose();
  });
  test('profile accepts multiple services and rejects ambiguous UUIDs', () {
    expect(
      () => BleProfile(
        services: [
          BleService(uuid: 'abcd', fields: [interval]),
          BleService(uuid: 'abcf', fields: [interval]),
        ],
      ),
      throwsArgumentError,
    );
    expect(normalizeBleUuid('ABCE'), interval.uuid);
    expect(() => normalizeBleUuid('not-a-uuid'), throwsArgumentError);
    expect(() => BleCodecs.uint16LittleEndian.encode(65536), throwsRangeError);
  });
  test(
    'typed updates, reads and notifications have distinct semantics',
    () async {
      await server.start();
      expect(server.state, BleServerState.running);
      expect(await platform.read('abce'), [30, 0]);
      await server.updateStoredValue(interval, 45);
      expect(await platform.read('abce'), [45, 0]);
      expect(platform.notifications, isEmpty);
      await server.updateStoredValue(interval, 60, notify: true);
      expect(server.readStoredValue(interval), 60);
      expect(platform.notifications.single['value'], [60, 0]);
      await server.sendNotification('abce', [90, 0]);
      expect(await platform.read('abce'), [60, 0]);
      expect(await platform.read('abce', offset: 1), [0]);
      await expectLater(
        platform.read('abce', offset: 3),
        throwsA(isA<BleRequestException>()),
      );
    },
  );
  test(
    'legacy storage, notification and stream names retain behavior',
    () async {
      final states = <BleServerState>[];
      final oldStates = <BleServerState>[];
      final writes = <BleWriteEvent>[];
      final oldWrites = <BleWriteEvent>[];
      final reads = <BleReadEvent>[];
      final oldReads = <BleReadEvent>[];
      final subscriptions = <StreamSubscription<dynamic>>[
        server.stateChanges.listen(states.add),
        server.states.listen(oldStates.add),
        server.clientWrites.listen(writes.add),
        server.onWrite.listen(oldWrites.add),
        server.clientReads.listen(reads.add),
        server.onRead.listen(oldReads.add),
      ];
      await server.start();
      await server.setValue(interval, 40);
      expect(server.valueOf(interval), 40);
      expect(platform.notifications, isEmpty);
      expect(writes, isEmpty); // Local changes are not client writes.
      await server.setValue(interval, 50, notify: true);
      await server.notify(interval.uuid, [60, 0]);
      expect(await platform.read(interval.uuid), [50, 0]);
      expect(platform.notifications.map((n) => n['value']), [
        [50, 0],
        [60, 0],
      ]);
      await platform.write(interval.uuid, [70, 0]);
      expect(server.readStoredValue(interval), 70);
      await server.stopServer();
      await Future<void>.delayed(Duration.zero);
      expect(states, oldStates);
      expect(states.last, BleServerState.stopped);
      expect(writes.single.value, oldWrites.single.value);
      expect(
        reads.single.characteristicUuid,
        oldReads.single.characteristicUuid,
      );
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    },
  );

  test('callback aliases cannot silently override one another', () {
    expect(
      () => BleField<int>(
        uuid: 'abcf',
        codec: BleCodecs.uint16LittleEndian,
        initialValue: 1,
        access: {BleProperty.read},
        readValue: (_) => 2,
        onRead: (_) => 3,
      ),
      throwsArgumentError,
    );
    expect(
      () => BleField<int>(
        uuid: 'abcf',
        codec: BleCodecs.uint16LittleEndian,
        initialValue: 1,
        access: {BleProperty.write},
        authorizeWrite: (_, _) => true,
        onWrite: (_, _) => false,
      ),
      throwsArgumentError,
    );
  });

  test('rejected writes do not mutate readable state', () async {
    await server.start();
    await platform.write('abce', [120, 0]);
    expect(server.readStoredValue(interval), 120);
    await expectLater(
      platform.write('abce', [0, 0]),
      throwsA(isA<BleRequestException>()),
    );
    await expectLater(
      platform.write('abce', [1]),
      throwsA(isA<BleRequestException>()),
    );
    await expectLater(
      platform.write('abce', [1, 0], offset: 1),
      throwsA(isA<BleRequestException>()),
    );
    expect(server.readStoredValue(interval), 120);
  });
  test(
    'only one server owns the same adapter and ownership is released',
    () async {
      final other = UniversalBleServer(
        platform: platform,
        profile: server.profile,
      );
      await server.start();
      await expectLater(other.start(), throwsStateError);
      await other.dispose();
      expect(await platform.read('abce'), [30, 0]);
      await server.stop();
      await server.start();
      expect(server.state, BleServerState.running);
    },
  );
  test('dynamic reads and per-client write authorization', () async {
    final secret = BleField<String>(
      uuid: 'abcf',
      codec: BleCodecs.utf8String,
      initialValue: 'Olá',
      access: {BleProperty.read, BleProperty.write},
      readValue: (context) => 'Olá ${context.clientId}',
      authorizeWrite: (context, value) => context.clientId == 'owner',
    );
    final dynamicServer = UniversalBleServer(
      platform: platform,
      profile: BleProfile(
        services: [
          BleService(uuid: 'abcd', fields: [secret]),
        ],
      ),
    );
    await dynamicServer.start();
    expect(
      BleCodecs.utf8String.decode(
        await platform.read('abcf', clientId: 'owner'),
      ),
      'Olá owner',
    );
    expect(dynamicServer.readStoredValue(secret), 'Olá');
    await expectLater(
      platform.write('abcf', [65]),
      throwsA(isA<BleRequestException>()),
    );
    await platform.write('abcf', [65], clientId: 'owner');
    expect(dynamicServer.readStoredValue(secret), 'A');
    await dynamicServer.dispose();
  });
  test('slow request cannot commit after stop or timeout', () async {
    final gate = Completer<bool>();
    final slow = BleField<int>(
      uuid: 'abcf',
      codec: BleCodecs.uint16LittleEndian,
      initialValue: 1,
      access: {BleProperty.read, BleProperty.write},
      onWrite: (_, _) => gate.future,
    );
    final dynamicServer = UniversalBleServer(
      platform: platform,
      requestTimeout: const Duration(milliseconds: 10),
      profile: BleProfile(
        services: [
          BleService(uuid: 'abcd', fields: [slow]),
        ],
      ),
    );
    await dynamicServer.start();
    await expectLater(
      platform.write('abcf', [2, 0]),
      throwsA(isA<BleRequestException>()),
    );
    expect(dynamicServer.readStoredValue(slow), 1);
    gate.complete(true);
    await dynamicServer.dispose();
  });
  test('queued operations preserve order and disposal is idempotent', () async {
    await server.start();
    await Future.wait([
      server.updateStoredValue(interval, 1),
      server.updateStoredValue(interval, 2),
      server.updateStoredValue(interval, 3),
    ]);
    expect(server.readStoredValue(interval), 3);
    await server.dispose();
    await server.dispose();
    await expectLater(server.start(), throwsStateError);
  });
  test(
    'legacy API validates configuration before calling native code',
    () async {
      final legacy = UniversalBleServer(platform: platform);
      await expectLater(
        legacy.startServer(serviceUuid: '', characteristics: []),
        throwsArgumentError,
      );
      await legacy.startServer(
        serviceUuid: 'abcd',
        characteristics: [
          BleCharacteristic(
            uuid: 'abce',
            properties: [BleProperty.read],
            initialValue: [42],
          ),
        ],
      );
      expect(await platform.read('abce'), [42]);
      await expectLater(
        platform.write('abce', [43]),
        throwsA(isA<BleRequestException>()),
      );
      await legacy.dispose();
    },
  );
}

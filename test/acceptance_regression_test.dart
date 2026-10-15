import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble_server/testing.dart';
import 'package:universal_ble_server/universal_ble_server.dart';

// Exercise the exact device fixture without depending on the example package.
// ignore: avoid_relative_lib_imports
import '../example/lib/acceptance_protocol.dart';

class FaultTransport extends SimulatedBleClientTransport {
  FaultTransport(super.server);
  final states = StreamController<BleAdapterState>.broadcast();
  final scanStarted = Completer<void>();
  BleAdapterState adapter = BleAdapterState.poweredOn;
  int scans = 0, writes = 0;
  bool interruptWrite = false;

  @override
  Stream<BleAdapterState> get adapterStates => states.stream;
  @override
  Future<BleAdapterState> checkSupport() async => adapter;
  @override
  Future<void> startScan(List<String> serviceUuids) async {
    scans++;
    await super.startScan(serviceUuids);
    if (!scanStarted.isCompleted) scanStarted.complete();
  }

  @override
  Future<void> write(String key, List<int> bytes) async {
    await super.write(key, bytes);
    writes++;
    if (interruptWrite && writes == 2) server.disconnect(clientId);
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    await states.close();
  }
}

void main() {
  late SimulatedBlePlatform platform;
  late AcceptanceHost host;
  late List<String> hostLog;
  setUp(() async {
    platform = SimulatedBlePlatform();
    hostLog = [];
    host = AcceptanceHost(
      run: 'regression',
      log: hostLog.add,
      platform: platform,
    );
    await host.start();
  });
  tearDown(() async {
    await host.dispose();
    await platform.dispose();
  });
  BleMessageClient createClient(String id) => BleMessageClient(
    configuration: acceptanceConfiguration('regression'),
    client: UniversalBleClient(
      transport: SimulatedBleClientTransport(platform, clientId: id),
    ),
  );

  test(
    'acceptance fixture preserves a full 65535-byte binary round trip',
    () async {
      final client = createClient('full');
      addTearDown(client.dispose);
      await client.connect('server');
      final packet = acceptancePacket(
        0,
        '0123456789abcdef',
        List.generate(65535 - 17, (i) => i % 256),
      );
      final reply = client.receivedMessages.first;
      await client.sendBytes(packet);
      expect(await reply.timeout(const Duration(seconds: 10)), packet);
      await expectLater(
        client.sendBytes(List.filled(65536, 0)),
        throwsA(
          isA<BleException>().having(
            (e) => e.code,
            'code',
            BleErrorCode.tooLarge,
          ),
        ),
      );
      final recovered = client.receivedMessages.first;
      final small = acceptancePacket(0, '0123456789abcdef', [255]);
      await client.sendBytes(small);
      expect(await recovered, small);
      expect(hostLog.where((line) => line.startsWith('FAIL')), isEmpty);
    },
  );

  test(
    'concurrent clients receive only their private replies and both broadcasts',
    () async {
      final a = createClient('a'), b = createClient('b');
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      await a.connect('server');
      await b.connect('server');
      final aReady = a.receivedMessages.first;
      final bReady = b.receivedMessages.first;
      final aJoin = acceptancePacket(3, 'aaaaaaaaaaaaaaaa', [2]);
      final bJoin = acceptancePacket(3, 'bbbbbbbbbbbbbbbb', [2]);
      await a.sendBytes(aJoin);
      await b.sendBytes(bJoin);
      expect(await aReady, aJoin);
      expect(await bReady, bJoin);
      final aMessages = <List<int>>[], bMessages = <List<int>>[];
      final sa = a.receivedMessages.listen(aMessages.add);
      final sb = b.receivedMessages.listen(bMessages.add);
      addTearDown(sa.cancel);
      addTearDown(sb.cancel);
      final first = acceptancePacket(
        0,
        'aaaaaaaaaaaaaaaa',
        List.filled(200, 1),
      );
      final second = acceptancePacket(
        0,
        'bbbbbbbbbbbbbbbb',
        List.filled(200, 2),
      );
      final aReply = a.receivedMessages.first,
          bReply = b.receivedMessages.first;
      await Future.wait([a.sendBytes(first), b.sendBytes(second)]);
      expect(await aReply, first);
      expect(await bReply, second);
      final broadcast = acceptancePacket(1, 'aaaaaaaaaaaaaaaa', [3]);
      final aBroadcast = a.receivedMessages.first,
          bBroadcast = b.receivedMessages.first;
      await a.sendBytes(broadcast);
      expect(await aBroadcast, broadcast);
      expect(await bBroadcast, broadcast);
      await Future<void>.delayed(Duration.zero);
      expect(aMessages, [first, broadcast]);
      expect(bMessages, [second, broadcast]);
    },
  );

  test(
    'field fixture notifies two clients; cancelling one preserves the other',
    () async {
      final a = createClient('a'), b = createClient('b');
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      await a.connect('server');
      await b.connect('server');
      await a.writeValue(acceptanceField, 19);
      expect(await b.readValue(acceptanceField), 19);
      final av = <int>[], bv = <int>[];
      final sa = (await a.watchValue(acceptanceField)).listen(av.add);
      final sb = (await b.watchValue(acceptanceField)).listen(bv.add);
      addTearDown(sa.cancel);
      addTearDown(sb.cancel);
      Future<void> update(int value) async {
        final reply = a.receivedMessages.first;
        await a.sendBytes(acceptancePacket(2, 'aaaaaaaaaaaaaaaa', [value, 0]));
        await reply;
      }

      await update(27);
      await sa.cancel();
      await update(28);
      expect(av, [27]);
      expect(bv, [27, 28]);
      expect(await a.readValue(acceptanceField), 28);
    },
  );

  for (final state in [
    BleAdapterState.unauthorized,
    BleAdapterState.poweredOff,
  ]) {
    test(
      '${state.name} rejects discovery before scanning and permits a later retry',
      () async {
        final transport = FaultTransport(platform)..adapter = state;
        final client = UniversalBleClient(transport: transport);
        addTearDown(client.dispose);
        await expectLater(
          client.discover(),
          throwsA(
            isA<BleException>().having(
              (e) => e.code,
              'code',
              state == BleAdapterState.unauthorized
                  ? BleErrorCode.permissionDenied
                  : BleErrorCode.bluetoothOff,
            ),
          ),
        );
        expect(transport.scans, 0);
        transport.adapter = BleAdapterState.poweredOn;
        expect(
          await client.discover(duration: const Duration(milliseconds: 5)),
          hasLength(1),
        );
        expect(transport.scans, 1);
      },
    );
  }

  test(
    'Bluetooth off during discovery ends it with an error, not partial success',
    () async {
      final transport = FaultTransport(platform);
      final client = UniversalBleClient(transport: transport);
      addTearDown(client.dispose);
      final discovery = client.discover(duration: const Duration(seconds: 30));
      final rejected = expectLater(
        discovery,
        throwsA(
          isA<BleException>().having(
            (e) => e.code,
            'code',
            BleErrorCode.bluetoothOff,
          ),
        ),
      );
      await transport.scanStarted.future;
      await Future<void>.delayed(Duration.zero);
      transport.adapter = BleAdapterState.poweredOff;
      transport.states.add(BleAdapterState.poweredOff);
      await rejected.timeout(const Duration(seconds: 1));
      transport.adapter = BleAdapterState.poweredOn;
      expect(
        await client.discover(duration: const Duration(milliseconds: 5)),
        hasLength(1),
      );
    },
  );

  test(
    'disconnect midway through a fragmented write cannot commit a partial message',
    () async {
      final transport = FaultTransport(platform)..interruptWrite = true;
      final client = BleMessageClient(
        configuration: acceptanceConfiguration('regression'),
        client: UniversalBleClient(transport: transport),
      );
      addTearDown(client.dispose);
      final messages = <BleReceivedMessage>[];
      final sub = host.server.receivedMessages.listen(messages.add);
      addTearDown(sub.cancel);
      await client.connect('server');
      await expectLater(
        client.sendBytes(
          acceptancePacket(0, 'aaaaaaaaaaaaaaaa', List.filled(200, 3)),
        ),
        throwsA(isA<BleException>()),
      );
      expect(messages, isEmpty);
      transport.interruptWrite = false;
      await client.connect('server');
      final packet = acceptancePacket(0, 'aaaaaaaaaaaaaaaa', [4]);
      final reply = client.receivedMessages.first;
      await client.sendBytes(packet);
      expect(await reply, packet);
      expect(messages.single.data, packet);
    },
  );

  test(
    '20 reconnect cycles restore field and message subscriptions without duplicates',
    () async {
      final client = createClient('cycles');
      addTearDown(client.dispose);
      await client.connect('server');
      final changes = <int>[];
      final subscription = (await client.watchValue(
        acceptanceField,
      )).listen(changes.add);
      addTearDown(subscription.cancel);
      for (var i = 0; i < 20; i++) {
        final reply = client.receivedMessages.first;
        await client.sendBytes(acceptancePacket(2, 'aaaaaaaaaaaaaaaa', [i, 0]));
        await reply;
        expect(changes, List.generate(i + 1, (index) => index));
        await client.disconnect();
        expect(
          platform.subscribers.values.every((peers) => peers.isEmpty),
          isTrue,
        );
        await client.connect('server');
      }
    },
  );
}

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble_server/universal_ble_server.dart';
import 'package:universal_ble_server/testing.dart';

class DiscoveryTransport extends SimulatedBleClientTransport {
  DiscoveryTransport(super.server);
  final results = StreamController<BleDiscoveredServer>.broadcast();
  final failures = StreamController<BleRawNotification>.broadcast();
  final started = Completer<void>();
  Completer<void>? gate;
  int permissions = 0, stops = 0;
  bool failDispose = false;
  @override
  Stream<BleDiscoveredServer> get discovered => results.stream;
  @override
  Stream<BleRawNotification> get notifications => failures.stream;
  @override
  Future<BleAdapterState> requestPermissions() async {
    permissions++;
    return BleAdapterState.poweredOn;
  }

  @override
  Future<void> startScan(List<String> serviceUuids) async {
    started.complete();
    await gate?.future;
    results.add(const BleDiscoveredServer('a', name: 'Old'));
    results.add(const BleDiscoveredServer('a', name: 'Updated'));
    results.add(const BleDiscoveredServer('b'));
  }

  @override
  Future<void> stopScan() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    unawaited(results.close());
    unawaited(failures.close());
    if (failDispose) throw StateError('Native cleanup failed');
  }
}

void main() {
  test(
    'discovery requests permission, deduplicates, bounds results and stops',
    () async {
      final platform = SimulatedBlePlatform();
      final transport = DiscoveryTransport(platform);
      final client = UniversalBleClient(transport: transport);
      try {
        final results = await client.discover(
          duration: const Duration(milliseconds: 20),
          maxResults: 1,
        );
        expect(results.map((d) => d.id), ['a']);
        expect(results.single.name, 'Updated');
        expect(transport.permissions, 1);
        expect(transport.stops, 2);
        expect(results.clear, throwsUnsupportedError);
      } finally {
        await client.dispose();
        await platform.dispose();
      }
    },
  );
  test(
    'explicit stop returns discovery early and concurrent discovery is rejected',
    () async {
      final platform = SimulatedBlePlatform();
      final transport = DiscoveryTransport(platform);
      final client = UniversalBleClient(transport: transport);
      try {
        final discovery = client.discover(
          duration: const Duration(minutes: 1),
          requestPermissions: false,
        );
        await transport.started.future;
        await expectLater(
          client.discover(),
          throwsA(
            isA<BleException>().having(
              (e) => e.code,
              'code',
              BleErrorCode.busy,
            ),
          ),
        );
        await client.stopScan();
        expect((await discovery).length, 2);
        expect(transport.permissions, 0);
      } finally {
        await client.dispose();
        await platform.dispose();
      }
    },
  );
  test(
    'dispose cancels a pending native scan start without leaving a scan active',
    () async {
      final platform = SimulatedBlePlatform();
      final transport = DiscoveryTransport(platform)..gate = Completer<void>();
      final client = UniversalBleClient(transport: transport);
      final discovery = client.discover();
      final rejected = expectLater(discovery, throwsA(isA<BleException>()));
      await transport.started.future;
      final cleanup = client.dispose();
      expect(identical(cleanup, client.dispose()), isTrue);
      transport.gate!.complete();
      await cleanup;
      await rejected;
      expect(transport.stops, greaterThanOrEqualTo(2));
      expect(client.state, BleConnectionState.disposed);
      await platform.dispose();
    },
  );
  test(
    'native scan errors finish discovery instead of returning a false empty success',
    () async {
      final platform = SimulatedBlePlatform();
      final transport = DiscoveryTransport(platform);
      final client = UniversalBleClient(transport: transport);
      try {
        final discovery = client.discover();
        final rejected = expectLater(discovery, throwsStateError);
        await transport.started.future;
        await Future<void>.delayed(Duration.zero);
        transport.failures.addError(StateError('Scan failed'));
        await rejected;
      } finally {
        await client.dispose();
        await platform.dispose();
      }
    },
  );
  test('message streams close even when native disposal fails', () async {
    final platform = SimulatedBlePlatform();
    final transport = DiscoveryTransport(platform)..failDispose = true;
    final client = BleMessageClient(
      client: UniversalBleClient(transport: transport),
    );
    final closed = client.receivedMessages.drain<void>();
    final cleanup = client.dispose();
    expect(identical(cleanup, client.dispose()), isTrue);
    await expectLater(cleanup, throwsStateError);
    await closed;
    await platform.dispose();
  });
  test(
    'reply, forwarding and field helpers share the existing connection',
    () async {
      final platform = SimulatedBlePlatform();
      final definition = BleFieldDefinition(
        serviceUuid: 'abcd',
        uuid: 'abce',
        codec: BleCodecs.uint16LittleEndian,
        access: {BleProperty.read, BleProperty.notify},
      );
      final field = definition.bind(initialValue: 5);
      final server = BleMessageServer(
        name: 'Routing',
        platform: platform,
        additionalServices: [
          BleService(uuid: 'abcd', fields: [field]),
        ],
      );
      final a = BleMessageClient(
        client: UniversalBleClient(
          transport: SimulatedBleClientTransport(platform, clientId: 'a'),
        ),
      );
      final b = BleMessageClient(
        client: UniversalBleClient(
          transport: SimulatedBleClientTransport(platform, clientId: 'b'),
        ),
      );
      final c = BleMessageClient(
        client: UniversalBleClient(
          transport: SimulatedBleClientTransport(platform, clientId: 'c'),
        ),
      );
      final aValues = <String>[], bValues = <String>[], cValues = <String>[];
      final sa = a.receivedText.listen(aValues.add),
          sb = b.receivedText.listen(bValues.add),
          sc = c.receivedText.listen(cValues.add);
      try {
        await server.startWithPermissions();
        final devices = await a.discover(
          duration: const Duration(milliseconds: 10),
        );
        await a.connect(devices.single.id);
        await b.connect(devices.single.id);
        await c.connect(devices.single.id);
        final incoming = server.receivedMessages.first;
        await a.sendText('hello');
        final message = await incoming;
        await server.replyText(message, 'reply');
        await server.forward(message);
        await server.forward(message, clientId: 'b');
        await Future<void>.delayed(Duration.zero);
        expect(aValues, ['reply']);
        expect(bValues, ['hello', 'hello']);
        expect(cValues, ['hello']);
        expect(await a.readValue(definition), 5);
        final updates = await a.watchValue(definition);
        final changed = updates.first;
        await server.updateStoredValue(field, 6, notify: true);
        expect(await changed, 6);
        expect(server.readStoredValue(field), 6);
        await expectLater(
          server.sendText('none', clientId: 'a', excludeClientId: 'a'),
          throwsStateError,
        );
      } finally {
        await sa.cancel();
        await sb.cancel();
        await sc.cancel();
        await a.dispose();
        await b.dispose();
        await c.dispose();
        await server.dispose();
        await platform.dispose();
      }
    },
  );
}

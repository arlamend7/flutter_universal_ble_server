@TestOn('browser')
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble_server/testing.dart';
import 'package:universal_ble_server/universal_ble_server.dart';
import 'package:universal_ble_server/universal_ble_server_web.dart';

import 'browser_fixture.dart';

Matcher failure(BleErrorCode code) =>
    throwsA(isA<BleException>().having((e) => e.code, 'code', code));

void main() {
  late SimulatedBlePlatform platform;
  late BleMessageServer server;
  late BrowserFixture browser;
  late BleMessageClient client;
  final field = BleFieldDefinition<int>(
    serviceUuid: 'abcd',
    uuid: 'abce',
    codec: BleCodecs.uint16LittleEndian,
    access: {BleProperty.read, BleProperty.write, BleProperty.notify},
  );
  final stored = BleField<int>(
    uuid: 'abce',
    codec: BleCodecs.uint16LittleEndian,
    initialValue: 7,
    access: {BleProperty.read, BleProperty.write, BleProperty.notify},
  );
  setUp(() async {
    platform = SimulatedBlePlatform();
    server = BleMessageServer(
      name: 'Browser test',
      platform: platform,
      additionalServices: [
        BleService(uuid: 'abcd', fields: [stored]),
      ],
    );
    await server.start();
    browser = BrowserFixture(platform);
    client = BleMessageClient(); // Real default web transport, no injection.
  });
  tearDown(() async {
    await client.dispose();
    await browser.dispose();
    await server.dispose();
    await platform.dispose();
  });
  Future<void> connect({bool fields = false}) async {
    final device = await client.selectDevice(
      optionalServiceUuids: fields ? ['abcd'] : [],
    );
    await client.connect(device!.id);
  }

  test(
    'chooser is called synchronously, grants normalized services, then connects',
    () async {
      final selection = client.selectDevice(
        optionalServiceUuids: ['ABCD', 'abcd'],
      );
      expect(browser.chooserCalls, 1); // Before awaiting: preserves activation.
      expect(browser.lastOptions!['filters'], [
        {
          'services': [client.configuration.serviceUuid],
        },
      ]);
      expect(browser.lastOptions!['optionalServices'], [
        normalizeBleUuid('abcd'),
      ]);
      final device = await selection;
      expect(device!.name, 'Advertised name');
      await client.connect(device.id);
      expect(client.state, BleConnectionState.ready);
      expect(client.serverName, 'Browser test');
      expect(await client.readValue(field), 7); // DataView offset preserved.
    },
  );

  test(
    'large UTF-8 and binary messages round trip through browser GATT',
    () async {
      await connect();
      final text = List.filled(90, 'Olá 🎮').join();
      final received = server.receivedMessages.first;
      await client.sendText(text);
      final message = await received;
      expect(message.text, text);
      expect(message.clientId, BrowserFixture.id);
      final reply = client.receivedText.first;
      await server.replyText(message, text);
      expect(await reply, text);
      final bytes = List.generate(2048, (i) => i % 256);
      final incoming = client.receivedMessages.first;
      await server.sendBytes(bytes);
      expect(await incoming, bytes);
      expect(browser.writes.length, greaterThan(1));
      expect(browser.writes.every((frame) => frame.length <= 20), isTrue);
      await expectLater(
        client.sendBytes(List.filled(65536, 0)),
        failure(BleErrorCode.tooLarge),
      );
    },
  );

  test(
    'typed fields read, write, notify, cancel, and restore after reconnect',
    () async {
      await connect(fields: true);
      await client.writeValue(field, 513);
      expect(await client.readValue(field), 513);
      final changes = <int>[];
      final sub = (await client.watchValue(field)).listen(changes.add);
      addTearDown(sub.cancel);
      await server.updateStoredValue(stored, 1234, notify: true);
      await Future<void>.delayed(Duration.zero);
      expect(changes, [1234]);
      final lost = client.stateChanges.firstWhere(
        (s) => s == BleConnectionState.disconnected,
      );
      browser.disconnect();
      await lost;
      await client.connect(BrowserFixture.id);
      await server.updateStoredValue(stored, 2345, notify: true);
      await Future<void>.delayed(Duration.zero);
      expect(changes, [1234, 2345]);
      final message = client.receivedText.first;
      await server.sendText('Restored');
      expect(await message, 'Restored');
      await sub.cancel();
      await Future<void>.delayed(Duration.zero);
      await server.updateStoredValue(stored, 3456, notify: true);
      await Future<void>.delayed(Duration.zero);
      expect(changes, [1234, 2345]);
    },
  );

  test('custom services require permission at selection time', () async {
    await connect();
    await expectLater(
      client.readValue(field),
      failure(BleErrorCode.incompatibleProtocol),
    );
  });

  test(
    'cancelled chooser returns null and preserves previous selection',
    () async {
      final selected = await client.selectDevice();
      browser.chooserError = 'NotFoundError';
      expect(await client.selectDevice(), isNull);
      await client.connect(selected!.id);
      expect(client.state, BleConnectionState.ready);
    },
  );

  for (final name in ['SecurityError', 'NotAllowedError']) {
    test('$name becomes a permission error', () async {
      browser.chooserError = name;
      await expectLater(
        client.selectDevice(),
        failure(BleErrorCode.permissionDenied),
      );
    });
  }

  test(
    'parallel choosers reject busy and late selection after disposal fails',
    () async {
      browser.chooserGate = Completer<void>();
      final pending = client.selectDevice();
      final rejected = expectLater(pending, failure(BleErrorCode.disconnected));
      await expectLater(client.selectDevice(), failure(BleErrorCode.busy));
      await client.dispose();
      browser.chooserGate!.complete();
      await rejected;
      expect(browser.connected, false);
    },
  );

  test('connection completed after disposal is immediately closed', () async {
    await client.selectDevice();
    browser.connectGate = Completer<void>();
    final pending = client.connect(BrowserFixture.id);
    final rejected = expectLater(pending, throwsA(anything));
    await browser.connectStarted.future;
    await client.dispose();
    browser.connectGate!.complete();
    await rejected;
    await Future<void>.delayed(Duration.zero);
    expect(browser.connected, false);
  });

  test('missing browser API and background scans fail explicitly', () async {
    browser.install(supported: false);
    expect(await client.client.checkSupport(), BleAdapterState.unsupported);
    expect(
      await client.client.requestPermissions(),
      BleAdapterState.unsupported,
    );
    await expectLater(client.selectDevice(), failure(BleErrorCode.unsupported));
    browser.install();
    expect(await client.client.checkSupport(), BleAdapterState.poweredOn);
    await expectLater(client.discover(), failure(BleErrorCode.unsupported));
    expect(browser.chooserCalls, 0);
  });

  test(
    'availability is unknown when browser cannot expose an adapter',
    () async {
      browser.available = false;
      expect(await client.client.checkSupport(), BleAdapterState.unknown);
      browser.available = true;
      await connect();
      final lost = client.stateChanges.firstWhere(
        (s) => s == BleConnectionState.disconnected,
      );
      browser.setAvailable(false);
      await lost;
      expect(browser.connected, false);
    },
  );

  test('subscription rejection cleans up and permits retry', () async {
    await connect(fields: true);
    browser.subscriptionError = 'NotSupportedError';
    await expectLater(
      client.watchValue(field),
      failure(BleErrorCode.unsupported),
    );
    browser.subscriptionError = null;
    final stream = await client.watchValue(field);
    final update = stream.first;
    await server.updateStoredValue(stored, 42, notify: true);
    expect(await update, 42);
  });

  test('protocol mismatch is rejected before messaging readiness', () async {
    await client.dispose();
    client = BleMessageClient(
      configuration: BleMessageConfiguration(protocol: 'wrong'),
    );
    await client.selectDevice();
    await expectLater(
      client.connect(BrowserFixture.id),
      failure(BleErrorCode.incompatibleProtocol),
    );
    expect(client.state, isNot(BleConnectionState.ready));
  });

  test('web server remains unsupported', () async {
    final backend = UniversalBleServerWeb();
    expect((await backend.checkSupport()).peripheral, false);
    await expectLater(backend.notify('abce', []), throwsUnsupportedError);
  });

  test(
    'raw writes over the browser limit fail before sending a frame',
    () async {
      await connect();
      final rx = client.configuration.field(
        client.configuration.clientToServerUuid,
        {BleProperty.write},
      );
      await expectLater(
        client.writeValue(rx, List.filled(21, 0)),
        failure(BleErrorCode.tooLarge),
      );
      expect(browser.writes, isEmpty);
    },
  );

  test('unselected device IDs cannot bypass browser permission', () async {
    await expectLater(
      client.connect('unselected'),
      failure(BleErrorCode.permissionDenied),
    );
    expect(browser.connected, false);
    await connect();
    await expectLater(client.selectDevice(), failure(BleErrorCode.busy));
  });

  test('all-devices chooser explicitly grants optional services', () async {
    final selected = await client.client.selectDevice(
      optionalServiceUuids: [client.configuration.serviceUuid],
    );
    expect(browser.lastOptions!['acceptAllDevices'], true);
    expect(browser.lastOptions!.containsKey('filters'), false);
    await client.connect(selected!.id);
    expect(client.state, BleConnectionState.ready);
  });
}

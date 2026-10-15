import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:universal_ble_server/universal_ble_server.dart';

import 'package:universal_ble_server_example/acceptance_protocol.dart';

const _enabled = bool.fromEnvironment('BLE_RUN_HARDWARE');
const _run = String.fromEnvironment('BLE_TEST_RUN', defaultValue: 'local');
const _peer = String.fromEnvironment('BLE_TEST_PEER');
const _maxBytes = int.fromEnvironment('BLE_TEST_MAX_BYTES', defaultValue: 4096);
const _fields = bool.fromEnvironment('BLE_TEST_FIELDS', defaultValue: true);
const _expectedState = String.fromEnvironment('BLE_EXPECT_STATE');
const _clients = int.fromEnvironment('BLE_TEST_CLIENTS', defaultValue: 1);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native BLE acceptance (requires a separate physical host)',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: Text(
                'BLE acceptance is running.\n'
                'Keep both devices unlocked and in the foreground.',
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        final client = BleMessageClient(
          configuration: acceptanceConfiguration(_run),
          assemblyTimeout: const Duration(
            seconds: int.fromEnvironment(
              'BLE_ASSEMBLY_SECONDS',
              defaultValue: 10,
            ),
          ),
        );
        final errors = <Object>[];
        final errorSubscription = client.errors.listen(errors.add);
        // Unique per process, so concurrent clients detect leaked private replies.
        final random = Random.secure();
        final token = List.generate(
          8,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        final tokenBytes = ascii.encode(token);
        final incoming = <List<int>>[];
        final subscription = client.receivedMessages.listen(incoming.add);
        void checkIsolation() {
          for (final message in incoming) {
            expect(message.length, greaterThanOrEqualTo(17));
            if (message.first != 1) {
              expect(
                message.sublist(1, 17),
                tokenBytes,
                reason: 'A private message reached the wrong client',
              );
            }
          }
          expect(errors, isEmpty, reason: 'Unexpected asynchronous BLE errors');
        }

        Future<void> exchange(List<int> packet) async {
          // Register before writing, and attach both futures immediately.
          final response = client.receivedMessages.firstWhere(
            (bytes) => listEquals(bytes, packet),
          );
          await Future.wait<void>([
            response.timeout(const Duration(minutes: 3)).then((_) {}),
            client.sendBytes(packet),
          ]);
          checkIsolation();
        }

        try {
          if (_expectedState.isNotEmpty) {
            final expected = BleAdapterState.values.byName(_expectedState);
            expect(
              expected,
              anyOf(BleAdapterState.unauthorized, BleAdapterState.poweredOff),
            );
            final actual = await client.requestPermissions();
            expect(actual, expected);
            await expectLater(
              client.discover(requestPermissions: false),
              throwsA(
                isA<BleException>().having(
                  (e) => e.code,
                  'code',
                  expected == BleAdapterState.unauthorized
                      ? BleErrorCode.permissionDenied
                      : BleErrorCode.bluetoothOff,
                ),
              ),
            );
            debugPrint(
              'PASS: expected ${expected.name} reported; no connection',
            );
            return;
          }
          expect(_maxBytes, inInclusiveRange(32, 65535));
          expect(_clients, inInclusiveRange(1, 2));
          expect(
            _clients == 1 || !_fields,
            isTrue,
            reason: 'Set BLE_TEST_FIELDS=false for concurrent clients',
          );
          final devices = await client.discover(
            duration: const Duration(seconds: 8),
          );
          final candidates = devices
              .where((d) => _peer.isEmpty || d.id == _peer)
              .toList();
          debugPrint(
            'Discovered: ${devices.map((d) => '${d.name}: ${d.id}').join(', ')}',
          );
          expect(
            candidates,
            hasLength(1),
            reason:
                'Run one acceptance host, or set BLE_TEST_PEER to its discovered ID.',
          );
          final id = candidates.single.id;
          await client.connect(id);
          expect(client.state, BleConnectionState.ready);
          expect(client.serverName, 'BLE acceptance');
          debugPrint('PASS: discovery, metadata and logical server name');
          await exchange(acceptancePacket(3, token, [_clients]));
          debugPrint('PASS: $_clients client(s) reached the start barrier');

          await exchange(acceptancePacket(0, token, utf8.encode('Olá 🎮 日本語')));
          for (final length in {32, 512, _maxBytes}) {
            await exchange(
              acceptancePacket(
                0,
                token,
                List.generate(length - 17, (i) => (i * 37) % 256),
              ),
            );
            debugPrint('PASS: $length-byte binary round trip');
          }
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
          await exchange(acceptancePacket(0, token, [99]));
          debugPrint(
            'PASS: oversized message rejected; subsequent send succeeds',
          );

          bool fromOther(List<int> packet) =>
              packet.length >= 17 &&
              packet.first == 1 &&
              !listEquals(packet.sublist(1, 17), tokenBytes);
          final otherBroadcast = _clients > 1 && !incoming.any(fromOther)
              ? client.receivedMessages
                    .firstWhere(fromOther)
                    .timeout(const Duration(minutes: 3))
                    .then((_) {})
              : Future<void>.value();
          await Future.wait<void>([
            otherBroadcast,
            exchange(acceptancePacket(1, token, utf8.encode('broadcast'))),
          ]);
          debugPrint(
            'PASS: own broadcast and, in two-client mode, peer broadcast',
          );
          // Both clients finish routing checks before either disconnects.
          await exchange(acceptancePacket(3, token, [_clients]));

          if (_fields) {
            // Run with one client; concurrent writes to a shared field race.
            await client.writeValue(acceptanceField, 19);
            expect(await client.readValue(acceptanceField), 19);
            final values = <int>[];
            final updates = await client.watchValue(acceptanceField);
            final watcher = updates.listen(values.add, onError: errors.add);
            try {
              final changed = updates.first.timeout(
                const Duration(seconds: 15),
              );
              await Future.wait<void>([
                changed.then((value) => expect(value, 27)),
                exchange(acceptancePacket(2, token, [27, 0])),
              ]);
            } finally {
              await watcher.cancel();
            }
            final before = values.length;
            await exchange(acceptancePacket(2, token, [28, 0]));
            expect(await client.readValue(acceptanceField), 28);
            expect(values.length, before);
            debugPrint(
              'PASS: typed read/write, notifications and watch cancellation',
            );
          }

          for (var cycle = 0; cycle < 3; cycle++) {
            await client.disconnect();
            expect(client.state, BleConnectionState.disconnected);
            await expectLater(
              client.sendText('offline'),
              throwsA(isA<BleException>()),
            );
            await client.connect(id);
            await exchange(acceptancePacket(0, token, [cycle]));
          }
          debugPrint('PASS: three intentional disconnect/reconnect cycles');
          await Future<void>.delayed(const Duration(seconds: 1));
          checkIsolation();
          debugPrint('PASS: no unexpected errors or foreign private replies');
        } finally {
          await subscription.cancel();
          await errorSubscription.cancel();
          await client.dispose();
        }
      });
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

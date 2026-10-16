import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble_server/universal_ble_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('universal_ble_server/client/methods');
  const events = MethodChannel('universal_ble_server/client/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late NativeBleClientTransport transport;
  late List<MethodCall> calls;
  setUp(() {
    transport = NativeBleClientTransport();
    calls = [];
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return switch (call.method) {
        'checkSupport' => 'poweredOn',
        'read' => 'AAH/',
        'maximumWriteBytes' => 20,
        _ => null,
      };
    });
  });
  tearDown(() async {
    await transport.dispose();
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  });
  test(
    'native channel preserves binary values and notification identity',
    () async {
      expect(await transport.checkSupport(), BleAdapterState.poweredOn);
      const key =
          '0000abcd-0000-1000-8000-00805f9b34fb/0000abce-0000-1000-8000-00805f9b34fb';
      expect(await transport.read(key), [0, 1, 255]);
      await transport.write(key, [0, 1, 255]);
      expect(calls.last.arguments, {'key': key, 'value': 'AAH/'});
      await transport.subscribe(key, true);
      expect(calls.last.arguments, {'key': key, 'enabled': true});
      final received = transport.notifications.first;
      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'notification',
          'key': key,
          'value': 'AAH/',
        }),
        (_) {},
      );
      final notification = await received;
      expect(notification.key, key);
      expect(notification.bytes, [0, 1, 255]);
    },
  );
  test(
    'malformed events and native asynchronous failures use typed errors',
    () async {
      await transport.checkSupport();
      final malformed = expectLater(
        transport.notifications.first,
        throwsA(
          isA<BleException>().having(
            (e) => e.code,
            'code',
            BleErrorCode.invalidData,
          ),
        ),
      );
      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'notification',
          'key': 'key',
          'value': '%%%',
        }),
        (_) {},
      );
      await malformed;
      final denied = expectLater(
        transport.notifications.first,
        throwsA(
          isA<BleException>().having(
            (e) => e.code,
            'code',
            BleErrorCode.permissionDenied,
          ),
        ),
      );
      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeErrorEnvelope(
          code: 'permission_denied',
          message: 'Revoked',
        ),
        (_) {},
      );
      await denied;
    },
  );
  test('ownership is exclusive and permission errors are typed', () async {
    await transport.checkSupport();
    final other = NativeBleClientTransport();
    await expectLater(
      other.checkSupport(),
      throwsA(
        isA<BleException>().having((e) => e.code, 'code', BleErrorCode.busy),
      ),
    );
    await other.dispose();
    expect(calls.where((c) => c.method == 'dispose'), isEmpty);
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'startScan') {
        throw PlatformException(code: 'permission_denied', message: 'Denied');
      }
      return null;
    });
    await expectLater(
      transport.startScan([]),
      throwsA(
        isA<BleException>().having(
          (e) => e.code,
          'code',
          BleErrorCode.permissionDenied,
        ),
      ),
    );
  });
  test('disposal failures are typed and release adapter ownership', () async {
    await transport.checkSupport();
    messenger.setMockMethodCallHandler(methods, (call) async {
      throw PlatformException(code: 'permission_denied');
    });
    await expectLater(
      transport.dispose(),
      throwsA(
        isA<BleException>().having(
          (error) => error.code,
          'code',
          BleErrorCode.permissionDenied,
        ),
      ),
    );
    messenger.setMockMethodCallHandler(methods, (call) async {
      return call.method == 'checkSupport' ? 'poweredOn' : null;
    });
    final next = NativeBleClientTransport();
    addTearDown(next.dispose);
    expect(await next.checkSupport(), BleAdapterState.poweredOn);
  });
  test('Linux clients have independent channels and disposal', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final sessions = <String>[];
    final disposed = <String>[];
    messenger.setMockMethodCallHandler(methods, (call) async {
      expect(call.method, 'createClient');
      final id = (call.arguments as Map)['session'] as String;
      sessions.add(id);
      messenger.setMockMethodCallHandler(
        MethodChannel('universal_ble_server/client/$id/events'),
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(
        MethodChannel('universal_ble_server/client/$id/methods'),
        (call) async {
          if (call.method == 'dispose') disposed.add(id);
          return call.method == 'checkSupport' ? 'poweredOn' : null;
        },
      );
      return null;
    });
    final a = NativeBleClientTransport(), b = NativeBleClientTransport();
    addTearDown(() async {
      await a.dispose();
      await b.dispose();
      for (final id in sessions) {
        messenger.setMockMethodCallHandler(
          MethodChannel('universal_ble_server/client/$id/methods'),
          null,
        );
        messenger.setMockMethodCallHandler(
          MethodChannel('universal_ble_server/client/$id/events'),
          null,
        );
      }
      debugDefaultTargetPlatformOverride = null;
    });
    expect(await Future.wait([a.checkSupport(), b.checkSupport()]), [
      BleAdapterState.poweredOn,
      BleAdapterState.poweredOn,
    ]);
    expect(sessions.toSet(), hasLength(2));
    final bMessages = <BleRawNotification>[];
    final sub = b.notifications.listen(bMessages.add);
    addTearDown(sub.cancel);
    final received = a.notifications.first;
    await messenger.handlePlatformMessage(
      'universal_ble_server/client/${sessions[0]}/events',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'type': 'notification',
        'key': 'a',
        'value': 'AQ==',
      }),
      (_) {},
    );
    expect((await received).bytes, [1]);
    expect(bMessages, isEmpty);
    await a.dispose();
    expect(disposed, [sessions[0]]);
    expect(await b.checkSupport(), BleAdapterState.poweredOn);
    await b.dispose();
    expect(disposed, sessions);
  });

  test(
    'Linux disposal during session creation releases the late native session',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final gate = Completer<void>();
      String? session;
      var releases = 0;
      messenger.setMockMethodCallHandler(methods, (call) async {
        session = (call.arguments as Map)['session'] as String;
        messenger.setMockMethodCallHandler(
          MethodChannel('universal_ble_server/client/$session/methods'),
          (call) async {
            expect(call.method, 'dispose');
            releases++;
            return null;
          },
        );
        await gate.future;
        return null;
      });
      final next = NativeBleClientTransport();
      addTearDown(() async {
        await next.dispose();
        if (session != null) {
          messenger.setMockMethodCallHandler(
            MethodChannel('universal_ble_server/client/$session/methods'),
            null,
          );
        }
        debugDefaultTargetPlatformOverride = null;
      });
      final pending = expectLater(next.checkSupport(), throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final disposal = next.dispose();
      gate.complete();
      await Future.wait([pending, disposal]);
      expect(releases, 1);
    },
  );
}

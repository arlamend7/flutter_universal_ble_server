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
}

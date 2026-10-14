import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble_server/universal_ble_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('universal_ble_server/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });
  test('serializes multiple services and canonical UUIDs', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final backend = MethodChannelUniversalBleServer();
    await backend.startProfile(
      BleProfile(
        services: [
          BleService(
            uuid: '180f',
            fields: [
              BleField(
                uuid: '2a19',
                codec: BleCodecs.bytes,
                initialValue: [99],
                access: {BleProperty.read},
              ),
            ],
          ),
          BleService(
            uuid: 'abcd',
            fields: [
              BleField(
                uuid: 'abce',
                codec: BleCodecs.uint16LittleEndian,
                initialValue: 300,
                access: {BleProperty.write},
              ),
            ],
          ),
        ],
      ),
    );
    expect(
      ((calls.single.arguments as Map<Object?, Object?>)['services'] as List)
          .length,
      2,
    );
    await backend.notify('abce', [44, 1]);
    expect(calls.last.arguments, {
      'characteristicUuid': normalizeBleUuid('abce'),
      'value': 'LAE=',
    });
  });
  test(
    'method channel adapters share ownership and target a specific client',
    () async {
      final first = MethodChannelUniversalBleServer();
      final second = MethodChannelUniversalBleServer();
      expect(identical(first.ownershipKey, second.ownershipKey), true);
      MethodCall? sent;
      messenger.setMockMethodCallHandler(channel, (call) async {
        sent = call;
        return null;
      });
      await first.notifyClient('abce', [1, 2], 'peer-1');
      expect(sent!.method, 'notify');
      expect((sent!.arguments as Map<Object?, Object?>)['clientId'], 'peer-1');
      expect((sent!.arguments as Map<Object?, Object?>)['value'], 'AQI=');
    },
  );
  test('request bridge returns application validation response', () async {
    final backend = MethodChannelUniversalBleServer();
    backend.setRequestHandler(
      (request) async => {'status': request['type'] == 'write' ? 8 : 0},
    );
    ByteData? response;
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('request', {'type': 'write'}),
      ),
      (data) {
        response = data;
      },
    );
    expect(const StandardMethodCodec().decodeEnvelope(response!), {
      'status': 8,
    });
    backend.setRequestHandler(null);
  });
}

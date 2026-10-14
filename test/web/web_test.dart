@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble_server/universal_ble_server_web.dart';
import 'package:universal_ble_server/universal_ble_server.dart';

void main() {
  test(
    'Web client reports unsupported and releases resources without native channels',
    () async {
      final client = UniversalBleClient();
      expect(await client.checkSupport(), BleAdapterState.unsupported);
      expect(await client.requestPermissions(), BleAdapterState.unsupported);
      await expectLater(
        client.startScan(),
        throwsA(
          isA<BleException>().having(
            (e) => e.code,
            'code',
            BleErrorCode.unsupported,
          ),
        ),
      );
      await client.dispose();
      expect(client.state, BleConnectionState.disposed);
    },
  );
  test('Web reports unsupported instead of pretending to send', () async {
    final backend = UniversalBleServerWeb();
    expect((await backend.checkSupport()).peripheral, false);
    await expectLater(backend.notify('abce', []), throwsUnsupportedError);
  });
}

import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble_server/universal_ble_server.dart';

void main() {
  test(
    'lost reply retries same command without repeating handler; concurrent requests correlate',
    () async {
      final left = StreamController<List<int>>(),
          right = StreamController<List<int>>();
      var calls = 0, drop = true;
      final a = BleRpcChannel(
        incoming: left.stream,
        send: (v) async {
          right.add(v);
        },
        timeout: const Duration(milliseconds: 30),
        handler: (_, _) => null,
      );
      final b = BleRpcChannel(
        incoming: right.stream,
        send: (v) async {
          if (drop) {
            drop = false;
            return;
          }
          left.add(v);
        },
        handler: (_, p) {
          calls++;
          return p;
        },
      );
      expect(await a.request('echo', 1, retries: 1), 1);
      expect(calls, 1);
      expect(await Future.wait([a.request('echo', 2), a.request('echo', 3)]), [
        2,
        3,
      ]);
      expect(calls, 3);
      await a.close();
      await b.close();
      await left.close();
      await right.close();
    },
  );
  test(
    'duplicates in flight execute once and conflicting payload is rejected',
    () async {
      final input = StreamController<List<int>>();
      final sent = <Map<String, dynamic>>[];
      final gate = Completer<Object?>();
      var calls = 0;
      final rpc = BleRpcChannel(
        incoming: input.stream,
        send: (v) async {
          sent.add(jsonDecode(utf8.decode(v)) as Map<String, dynamic>);
        },
        handler: (_, _) {
          calls++;
          return gate.future;
        },
      );
      void request(int n) => input.add(
        utf8.encode(
          jsonEncode({
            'v': 1,
            't': 'req',
            'id': 'same',
            'method': 'x',
            'payload': n,
          }),
        ),
      );
      request(1);
      request(1);
      request(2);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      gate.complete('done');
      await Future<void>.delayed(Duration.zero);
      expect(sent.where((v) => v['error'] != null).length, 1);
      expect(sent.where((v) => v['payload'] == 'done').length, 2);
      await rpc.close();
      await input.close();
    },
  );
  test(
    'invalid JSON does not consume a pending slot and close interrupts blocked sends',
    () async {
      final input = StreamController<List<int>>();
      final blocked = Completer<void>();
      final rpc = BleRpcChannel(
        incoming: input.stream,
        maxPending: 1,
        send: (_) => blocked.future,
        handler: (_, _) => null,
      );
      await expectLater(
        rpc.request('invalid', double.nan),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
      final pending = rpc.request('valid', 1);
      final assertion = expectLater(
        pending,
        throwsA(
          isA<BleException>().having(
            (e) => e.code,
            'code',
            BleErrorCode.disconnected,
          ),
        ),
      );
      await rpc.close();
      await assertion;
      blocked.complete();
      await input.close();
    },
  );

  test(
    'disconnect fails pending request immediately and handlers cannot leak errors',
    () async {
      final input = StreamController<List<int>>();
      final rpc = BleRpcChannel(
        incoming: input.stream,
        send: (_) async {},
        handler: (_, _) => null,
      );
      final pending = rpc.request('x', null);
      final expectation = expectLater(
        pending,
        throwsA(
          isA<BleException>().having(
            (e) => e.code,
            'code',
            BleErrorCode.disconnected,
          ),
        ),
      );
      await rpc.close();
      await expectation;
      await input.close();
    },
  );
}

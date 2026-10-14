import 'package:universal_ble_server/ble_protocol.dart';

/// Run with `dart run tool/protocol_smoke.dart`, outside the Flutter test runner.
void main() {
  final assembler = BleMessageAssembler();
  final value = List<int>.generate(100, (i) => i);
  List<int>? decoded;
  for (final frame in BleMessageFramer.encode(
    value,
    messageId: 1,
    maxFrameBytes: 20,
  )) {
    decoded = assembler.add(frame) ?? decoded;
  }
  if (decoded == null ||
      decoded.length != value.length ||
      List.generate(
        value.length,
        (i) => decoded![i] == value[i],
      ).contains(false)) {
    throw StateError('Pure Dart framing round-trip failed');
  }
}

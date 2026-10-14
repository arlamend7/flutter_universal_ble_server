import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble_server/ble_profile.dart';

void main() {
  test('messages round-trip across small MTU-sized frames', () {
    final payload = List.generate(1024, (i) => i % 256);
    final frames = BleMessageFramer.encode(
      payload,
      messageId: 42,
      maxFrameBytes: 20,
    );
    final assembler = BleMessageAssembler();
    List<int>? result;
    for (final frame in frames) {
      expect(frame.length, lessThanOrEqualTo(20));
      result = assembler.add(frame);
    }
    expect(result, payload);
    expect(
      assembler.add(
        BleMessageFramer.encode([], messageId: 43, maxFrameBytes: 20).single,
      ),
      isEmpty,
    );
  });
  test('duplicate, reordered and expired messages cannot be committed', () {
    final frames = BleMessageFramer.encode(
      List.filled(30, 1),
      messageId: 0,
      maxFrameBytes: 20,
    );
    final assembler = BleMessageAssembler(timeout: const Duration(seconds: 1));
    expect(() => assembler.add(frames[1]), throwsFormatException);
    assembler.add(frames[0]);
    expect(() => assembler.add(frames[0]), throwsFormatException);
    final now = DateTime.utc(2026);
    assembler.add(frames[0], now: now);
    expect(
      () => assembler.add(frames[1], now: now.add(const Duration(seconds: 2))),
      throwsFormatException,
    );
  });
  test('oversized data resets the bounded assembler', () {
    final frames = BleMessageFramer.encode(
      List.filled(30, 1),
      messageId: 1,
      maxFrameBytes: 20,
    );
    final assembler = BleMessageAssembler(maxMessageBytes: 15);
    assembler.add(frames[0]);
    expect(() => assembler.add(frames[1]), throwsFormatException);
    expect(
      assembler.add(
        BleMessageFramer.encode([1], messageId: 2, maxFrameBytes: 20).single,
      ),
      [1],
    );
  });
}

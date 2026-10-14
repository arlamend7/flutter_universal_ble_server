import 'dart:typed_data';

/// Optional, versioned message framing. Both peers MUST implement this format.
/// Header: version:u8 (=1), messageId:u16le, index:u16le, count:u16le.
/// This is framing only: no encryption, acknowledgement, retry or replay defense.
class BleMessageFramer {
  const BleMessageFramer._();
  static List<Uint8List> encode(
    List<int> message, {
    required int messageId,
    required int maxFrameBytes,
  }) {
    if (messageId < 0 || messageId > 65535) {
      throw RangeError.range(messageId, 0, 65535);
    }
    if (maxFrameBytes < 8 || maxFrameBytes > 512) {
      throw RangeError.range(maxFrameBytes, 8, 512);
    }
    if (message.length > 65535 || message.any((b) => b < 0 || b > 255)) {
      throw ArgumentError('Message must contain at most 65535 bytes');
    }
    final payload = maxFrameBytes - 7;
    final count = message.isEmpty
        ? 1
        : (message.length + payload - 1) ~/ payload;
    return List.generate(count, (index) {
      final begin = index * payload;
      final end = (begin + payload).clamp(0, message.length);
      final bytes = Uint8List(7 + end - begin);
      final header = ByteData.sublistView(bytes);
      header.setUint8(0, 1);
      header.setUint16(1, messageId, Endian.little);
      header.setUint16(3, index, Endian.little);
      header.setUint16(5, count, Endian.little);
      bytes.setRange(7, bytes.length, message, begin);
      return bytes;
    });
  }
}

/// One bounded, ordered message assembly per peer. Create a separate instance
/// per connection; reset on disconnect. Duplicate/reordered fragments are errors.
class BleMessageAssembler {
  BleMessageAssembler({
    this.maxMessageBytes = 65535,
    this.timeout = const Duration(seconds: 10),
  }) {
    if (maxMessageBytes < 0 ||
        maxMessageBytes > 65535 ||
        timeout <= Duration.zero) {
      throw ArgumentError('Invalid assembly limits');
    }
  }
  final int maxMessageBytes;
  final Duration timeout;
  int? _id;
  int _count = 0;
  int _next = 0;
  DateTime? _started;
  BytesBuilder _bytes = BytesBuilder(copy: true);
  void reset() {
    _id = null;
    _count = 0;
    _next = 0;
    _started = null;
    _bytes = BytesBuilder(copy: true);
  }

  Uint8List? add(List<int> frame, {DateTime? now}) {
    now ??= DateTime.now();
    try {
      if (frame.length < 7 ||
          frame.length > 512 ||
          frame.any((b) => b < 0 || b > 255)) {
        throw const FormatException('Invalid frame');
      }
      final header = ByteData.sublistView(Uint8List.fromList(frame));
      final id = header.getUint16(1, Endian.little);
      final index = header.getUint16(3, Endian.little);
      final count = header.getUint16(5, Endian.little);
      if (header.getUint8(0) != 1 || count == 0 || index >= count) {
        throw const FormatException('Invalid frame header');
      }
      if (_started != null && now.difference(_started!) > timeout) {
        throw const FormatException('Message assembly expired');
      }
      if (_id == null) {
        if (index != 0) {
          throw const FormatException('First fragment is missing');
        }
        _id = id;
        _count = count;
        _started = now;
      }
      if (id != _id || count != _count || index != _next) {
        throw const FormatException('Unexpected fragment');
      }
      if (frame.length == 7 && count != 1) {
        throw const FormatException('Empty fragmented payload');
      }
      if (_bytes.length + frame.length - 7 > maxMessageBytes) {
        throw const FormatException('Message exceeds configured limit');
      }
      _bytes.add(frame.sublist(7));
      _next++;
      if (_next != _count) return null;
      final message = _bytes.takeBytes();
      reset();
      return message;
    } catch (_) {
      reset();
      rethrow;
    }
  }
}

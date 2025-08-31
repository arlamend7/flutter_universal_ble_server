import 'dart:typed_data';
import 'package:encrypt/encrypt.dart' as encrypt;

/// Simple AES/CBC cipher used to protect characteristic data.
class AesCipher {
  AesCipher(List<int> keyBytes)
      : _key = encrypt.Key(Uint8List.fromList(keyBytes));

  final encrypt.Key _key;

  /// Encrypts [data] and returns the IV concatenated with ciphertext.
  Uint8List encryptData(List<int> data) {
    final iv = encrypt.IV.fromSecureRandom(16);
    final encrypter = encrypt.Encrypter(
      encrypt.AES(_key, mode: encrypt.AESMode.cbc),
    );
    final encrypted = encrypter.encryptBytes(data, iv: iv);
    return Uint8List.fromList(iv.bytes + encrypted.bytes);
  }

  /// Decrypts [data] produced by [encryptData].
  List<int> decryptData(List<int> data) {
    final iv = encrypt.IV(data.sublist(0, 16));
    final cipherText = data.sublist(16);
    final encrypter = encrypt.Encrypter(
      encrypt.AES(_key, mode: encrypt.AESMode.cbc),
    );
    return encrypter.decryptBytes(
      encrypt.Encrypted(Uint8List.fromList(cipherText)),
      iv: iv,
    );
  }
}

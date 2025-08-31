import 'package:test/test.dart';
import 'package:universal_ble_server/universal_ble_server.dart';

void main() {
  test('AES encryption round trip', () {
    final cipher = AesCipher(List<int>.filled(32, 1));
    final data = [1, 2, 3, 4];
    final enc = cipher.encryptData(data);
    final dec = cipher.decryptData(enc);
    expect(dec, data);
  });
}

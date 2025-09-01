import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as encrypt;

import 'src/models.dart';
import 'universal_ble_server_platform_interface.dart';

/// Encrypt [data] using AES-CBC.
List<int> aesEncrypt(List<int> data, List<int> key, List<int> iv) {
  final encrypter = encrypt.Encrypter(encrypt.AES(encrypt.Key(Uint8List.fromList(key))));
  return encrypter.encryptBytes(data, iv: encrypt.IV(Uint8List.fromList(iv))).bytes;
}

/// Decrypt [data] previously encrypted with [aesEncrypt].
List<int> aesDecrypt(List<int> data, List<int> key, List<int> iv) {
  final encrypter = encrypt.Encrypter(encrypt.AES(encrypt.Key(Uint8List.fromList(key))));
  return encrypter.decryptBytes(encrypt.Encrypted(Uint8List.fromList(data)), iv: encrypt.IV(Uint8List.fromList(iv)));
}

/// High level API for the universal BLE server.
class UniversalBleServer {
  UniversalBleServer({required List<int> key, List<int>? iv})
      : _key = encrypt.Key(Uint8List.fromList(key)),
        _iv = encrypt.IV(Uint8List.fromList(iv ?? List<int>.filled(16, 0)));

  final encrypt.Key _key;
  final encrypt.IV _iv;

  Stream<BleWriteEvent> get onWrite => UniversalBleServerPlatform.instance.onWrite.map(
        (e) => BleWriteEvent(
          characteristicUuid: e.characteristicUuid,
          value: aesDecrypt(e.value, _key.bytes, _iv.bytes),
        ),
      );

  Stream<BleReadEvent> get onRead => UniversalBleServerPlatform.instance.onRead;

  Future<void> startServer({required String serviceUuid, required List<BleCharacteristic> characteristics}) async {
    final encryptedChars = characteristics
        .map((c) => BleCharacteristic(
              uuid: c.uuid,
              properties: c.properties,
              initialValue: aesEncrypt(c.initialValue, _key.bytes, _iv.bytes),
            ))
        .toList();
    await UniversalBleServerPlatform.instance
        .startServer(serviceUuid: serviceUuid, characteristics: encryptedChars);
  }

  Future<void> stopServer() => UniversalBleServerPlatform.instance.stopServer();

  Future<void> notify(String characteristicUuid, List<int> value) async {
    final enc = aesEncrypt(value, _key.bytes, _iv.bytes);
    await UniversalBleServerPlatform.instance.notify(characteristicUuid, enc);
  }
}

export 'src/models.dart';

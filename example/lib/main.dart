import 'package:flutter/material.dart';
import 'package:universal_ble_server/universal_ble_server.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final server = UniversalBleServer(key: List<int>.filled(32, 1));
  String log = 'Server not started';

  @override
  void initState() {
    super.initState();
    server.onWrite.listen((event) {
      setState(() {
        log = 'Received: ' + String.fromCharCodes(event.value);
      });
    });
  }

  Future<void> _start() async {
    await server.startServer(
      serviceUuid: '0000abcd-0000-1000-8000-00805f9b34fb',
      characteristics: [
        BleCharacteristic(
            uuid: '0000abce-0000-1000-8000-00805f9b34fb',
            properties: [BleProperty.write]),
        BleCharacteristic(
            uuid: '0000abcf-0000-1000-8000-00805f9b34fb',
            properties: [BleProperty.notify]),
      ],
    );
    setState(() {
      log = 'Server started';
    });
  }

  Future<void> _send() async {
    await server.notify(
        '0000abcf-0000-1000-8000-00805f9b34fb', 'Hello Central'.codeUnits);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Universal BLE Server Example')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text(log),
              const SizedBox(height: 20),
              ElevatedButton(onPressed: _start, child: const Text('Start Server')),
              ElevatedButton(onPressed: _send, child: const Text('Send Message')),
            ],
          ),
        ),
      ),
    );
  }
}

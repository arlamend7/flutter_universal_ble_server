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
  late final UniversalBleServer _server;
  final _log = <String>[];
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _server = UniversalBleServer();
    _server.onWrite.listen((e) {
      setState(() {
        _log.add(
          'Write ${e.characteristicUuid}: ' + String.fromCharCodes(e.value),
        );
      });
    });
    _server.onRead.listen((e) {
      setState(() {
        _log.add('Read ${e.characteristicUuid}');
      });
    });
    _server.startServer(
      serviceUuid: '0000180A-0000-1000-8000-00805F9B34FB',
      characteristics: const [
        BleCharacteristic(
          uuid: '00002A57-0000-1000-8000-00805F9B34FB',
          properties: [BleProperty.read, BleProperty.write, BleProperty.notify],
        ),
      ],
    );
  }

  @override
  void dispose() {
    _server.stopServer();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Universal BLE Server')),
        body: Column(
          children: [
            TextField(
              controller: _controller,
              decoration: const InputDecoration(labelText: 'Message'),
            ),
            ElevatedButton(
              onPressed: () {
                final text = _controller.text;
                _server.notify(
                  '00002A57-0000-1000-8000-00805F9B34FB',
                  text.codeUnits,
                );
                _controller.clear();
              },
              child: const Text('Notify'),
            ),
            Expanded(
              child: ListView(children: _log.map((e) => Text(e)).toList()),
            ),
          ],
        ),
      ),
    );
  }
}

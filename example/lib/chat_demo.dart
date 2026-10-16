import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:universal_ble_server/universal_ble_server.dart';

/// A minimal foreground chat: host, discover, choose, send and optionally relay.
class ChatDemo extends StatefulWidget {
  const ChatDemo({super.key});
  @override
  State<ChatDemo> createState() => _ChatDemoState();
}

class _ChatDemoState extends State<ChatDemo> {
  final _name = TextEditingController(text: 'BLE chat');
  final _text = TextEditingController();
  final _configuration = BleMessageConfiguration(protocol: 'chat-demo');
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _log = <String>[];
  BleMessageServer? _server;
  BleMessageClient? _client;
  List<BleDiscoveredServer> _devices = const [];
  Set<String> _recipients = const {};
  String? _target;
  bool _busy = false, _relay = true;
  bool get _connected => _client?.state == BleConnectionState.ready;

  void _record(Object event) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, event.toString());
      if (_log.length > 100) _log.removeLast();
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _record(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _host() async {
    final server = BleMessageServer(
      name: _name.text,
      configuration: _configuration,
    );
    _server = server;
    _subscriptions.add(server.errors.listen(_record));
    _subscriptions.add(
      server.clientEvents.listen((_) {
        if (!mounted) return;
        setState(() {
          _recipients = server.subscribedClientIds;
          if (!_recipients.contains(_target)) _target = null;
        });
      }),
    );
    _subscriptions.add(
      server.receivedMessages.listen((message) {
        unawaited(_receive(server, message));
      }),
    );
    try {
      await server.startWithPermissions();
      _record(
        'Hosting ${server.name}. Other devices can now discover this chat.',
      );
    } catch (_) {
      await _reset();
      rethrow;
    }
  }

  Future<void> _receive(
    BleMessageServer server,
    BleReceivedMessage message,
  ) async {
    try {
      _record('${message.clientId}: ${message.text}');
      if (_relay &&
          server.subscribedClientIds.any((id) => id != message.clientId)) {
        await server.forward(message);
      }
    } catch (error) {
      _record(error);
    }
  }

  Future<void> _discover() async {
    final client = _client ??= BleMessageClient(configuration: _configuration);
    if (_subscriptions.isEmpty) {
      _subscriptions.add(client.errors.listen(_record));
      _subscriptions.add(
        client.receivedText.listen(
          (text) => _record('Received: $text'),
          onError: _record,
        ),
      );
      _subscriptions.add(
        client.stateChanges.listen(
          (state) => _record('Connection: ${state.name}'),
        ),
      );
    }
    final List<BleDiscoveredServer> devices;
    if (kIsWeb) {
      // Call before any await so the browser retains the button's activation.
      final device = await client.selectDevice();
      devices = device == null ? [] : [device];
    } else {
      devices = await client.discover();
    }
    if (mounted) setState(() => _devices = devices);
    if (devices.isEmpty && !kIsWeb) {
      _record('No chat found. Start a host nearby and try again.');
    }
  }

  Future<void> _connect(BleDiscoveredServer device) async {
    await _client!.connect(device.id);
    _record('Connected to ${_client!.serverName}');
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    if (_server != null) {
      await _server!.sendText(text, clientId: _target);
    } else {
      await _client!.sendText(text);
    }
    _record('Sent: $text');
    _text.clear();
  }

  Future<void> _reset() async {
    final server = _server, client = _client;
    _server = null;
    _client = null;
    final subscriptions = _subscriptions.toList();
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    try {
      await client?.dispose();
    } finally {
      await server?.dispose();
    }
    if (mounted) {
      setState(() {
        _devices = const [];
        _recipients = const {};
        _target = null;
      });
    }
  }

  @override
  void dispose() {
    // Flutter disposal is synchronous; observe asynchronous resource errors.
    unawaited(
      _reset().catchError((Object error) {
        debugPrint('BLE cleanup: $error');
      }),
    );
    _name.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Simple BLE chat')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Open this screen on two or three devices. Host on one, then discover and connect on the others.',
        ),
        if (kIsWeb)
          const Text(
            'Web browsers can join a native host. Use a browser with Web Bluetooth on HTTPS or localhost, then choose a device below.',
          ),
        const SizedBox(height: 12),
        TextField(
          controller: _name,
          enabled: !_busy && _server == null && _client == null,
          decoration: const InputDecoration(labelText: 'Host name'),
        ),
        Wrap(
          spacing: 12,
          children: [
            FilledButton(
              onPressed: kIsWeb || _busy || _server != null || _client != null
                  ? null
                  : () => _run(_host),
              child: const Text('Host chat'),
            ),
            OutlinedButton(
              onPressed: _busy || _server != null || _connected
                  ? null
                  : () => _run(_discover),
              child: const Text(
                kIsWeb ? 'Choose BLE device' : 'Discover chats',
              ),
            ),
            TextButton(
              onPressed: _busy ? null : () => _run(_reset),
              child: const Text('Stop / reset'),
            ),
          ],
        ),
        if (_busy) const LinearProgressIndicator(),
        if (!_connected)
          ..._devices.map(
            (device) => ListTile(
              title: Text(device.name ?? 'Nearby chat'),
              subtitle: Text(device.id),
              trailing: FilledButton(
                onPressed: _busy ? null : () => _run(() => _connect(device)),
                child: const Text('Connect'),
              ),
            ),
          ),
        if (_server != null) ...[
          SwitchListTile(
            value: _relay,
            onChanged: (value) => setState(() => _relay = value),
            title: const Text('Forward client messages to the other clients'),
          ),
          DropdownButton<String>(
            value: _target ?? '',
            isExpanded: true,
            items: [
              const DropdownMenuItem(
                value: '',
                child: Text('Send to everyone'),
              ),
              ..._recipients.map(
                (id) => DropdownMenuItem(value: id, child: Text(id)),
              ),
            ],
            onChanged: (value) =>
                setState(() => _target = value == '' ? null : value),
          ),
        ],
        TextField(
          controller: _text,
          decoration: const InputDecoration(labelText: 'Message'),
        ),
        FilledButton(
          onPressed: _busy || (!_connected && _recipients.isEmpty)
              ? null
              : () => _run(_send),
          child: const Text('Send'),
        ),
        const Text(
          'This demo has no login or application encryption. Use trusted devices. Keep the app open.',
        ),
        const Divider(),
        ..._log.map(SelectableText.new),
      ],
    ),
  );
}

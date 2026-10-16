import 'dart:async';
import 'package:flutter/material.dart';
import 'package:universal_ble_server/universal_ble_server.dart';

/// Linux hub: one independently owned message client for each selected host.
class PeripheralHubDemo extends StatefulWidget {
  const PeripheralHubDemo({super.key});
  @override
  State<PeripheralHubDemo> createState() => _PeripheralHubDemoState();
}

class _Peer {
  _Peer(this.device, this.client);
  final BleDiscoveredServer device;
  final BleMessageClient client;
  final subscriptions = <StreamSubscription<dynamic>>[];
  Future<void> dispose() async {
    for (final sub in subscriptions) {
      await sub.cancel();
    }
    await client.dispose();
  }
}

class _PeripheralHubDemoState extends State<PeripheralHubDemo> {
  final _peers = <String, _Peer>{};
  final _message = TextEditingController(text: 'Hello from the Linux hub');
  final _log = <String>[];
  List<BleDiscoveredServer> _devices = const [];
  BleMessageClient? _scanner;
  bool _busy = false;
  BleMessageClient _newClient() => BleMessageClient(
    configuration: BleMessageConfiguration(protocol: 'chat-demo'),
  );

  void _record(Object value) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, value.toString());
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

  Future<void> _discover() async {
    final scanner = _scanner = _newClient();
    try {
      final devices = await scanner.discover();
      if (mounted) setState(() => _devices = devices);
    } finally {
      await scanner.dispose();
      if (identical(_scanner, scanner)) _scanner = null;
    }
  }

  Future<void> _connect(BleDiscoveredServer device) async {
    if (_peers.containsKey(device.id)) return;
    final peer = _Peer(device, _newClient());
    _peers[device.id] = peer;
    peer.subscriptions.add(peer.client.errors.listen(_record));
    peer.subscriptions.add(
      peer.client.receivedText.listen(
        (text) => _record('${device.name ?? device.id}: $text'),
        onError: _record,
      ),
    );
    peer.subscriptions.add(
      peer.client.stateChanges.listen(
        (state) => _record('${device.name ?? device.id}: ${state.name}'),
      ),
    );
    try {
      await peer.client.connect(device.id);
    } catch (_) {
      _peers.remove(device.id);
      await peer.dispose();
      rethrow;
    }
  }

  Future<void> _disconnect(String id) async {
    final peer = _peers.remove(id);
    await peer?.dispose();
  }

  Future<void> _send(_Peer peer) => peer.client.sendText(_message.text);

  Future<void> _sendAll() async {
    // Independent per-device queues. One failure does not cancel the other send.
    await Future.wait(
      _peers.values
          .where((peer) => peer.client.state == BleConnectionState.ready)
          .map((peer) async {
            try {
              await _send(peer);
            } catch (error) {
              _record('${peer.device.id}: $error');
            }
          }),
    );
  }

  Future<void> _release() async {
    final peers = _peers.values.toList();
    _peers.clear();
    await Future.wait([
      if (_scanner != null) _scanner!.dispose(),
      ...peers.map((peer) => peer.dispose()),
    ]);
  }

  @override
  void dispose() {
    unawaited(
      _release().catchError((Object error) {
        debugPrint('Hub cleanup: $error');
      }),
    );
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Linux peripheral hub')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'On two other devices, open Simple chat and Host chat. '
          'Discover them here, then connect to each. Each connection has its '
          'own messages and lifecycle. Keep every app in the foreground.',
        ),
        FilledButton(
          onPressed: _busy ? null : () => _run(_discover),
          child: const Text('Discover hosts'),
        ),
        if (_busy) const LinearProgressIndicator(),
        for (final device in _devices.where((d) => !_peers.containsKey(d.id)))
          ListTile(
            title: Text(device.name ?? device.id),
            trailing: OutlinedButton(
              onPressed: _busy ? null : () => _run(() => _connect(device)),
              child: const Text('Connect'),
            ),
          ),
        TextField(
          controller: _message,
          decoration: const InputDecoration(labelText: 'Message'),
        ),
        FilledButton(
          onPressed: _busy || _peers.isEmpty ? null : () => _run(_sendAll),
          child: const Text('Send to all connected hosts'),
        ),
        for (final peer in _peers.values)
          ListTile(
            title: Text(
              peer.client.serverName ?? peer.device.name ?? peer.device.id,
            ),
            subtitle: Text(peer.client.state.name),
            trailing: Wrap(
              children: [
                TextButton(
                  onPressed:
                      _busy || peer.client.state != BleConnectionState.ready
                      ? null
                      : () => _run(() => _send(peer)),
                  child: const Text('Send'),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() => _disconnect(peer.device.id)),
                  child: const Text('Disconnect'),
                ),
              ],
            ),
          ),
        const Divider(),
        ..._log.map(SelectableText.new),
      ],
    ),
  );
}

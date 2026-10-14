import 'dart:async';
import 'package:flutter/material.dart';
import 'package:universal_ble_server/universal_ble_server.dart';

// Both roles import the same protocol and field definitions.
final demoProtocol = BleMessageConfiguration(protocol: 'shared-counter-demo');
final counterDefinition = BleFieldDefinition<int>(
  serviceUuid: '9c461840-f714-461c-9980-fc7ae4879880',
  uuid: '9c461841-f714-461c-9980-fc7ae4879880',
  codec: BleCodecs.uint16LittleEndian,
  access: {BleProperty.read, BleProperty.notify},
);

class ClientServerDemo extends StatefulWidget {
  const ClientServerDemo({super.key});
  @override
  State<ClientServerDemo> createState() => _ClientServerDemoState();
}

class _ClientServerDemoState extends State<ClientServerDemo> {
  final name = TextEditingController(text: 'Shared counter');
  final text = TextEditingController(text: 'Hello from this device');
  final subscriptions = <StreamSubscription<dynamic>>[];
  final found = <String, BleDiscoveredServer>{};
  final logs = <String>[];
  BleMessageServer? server;
  BleMessageClient? client;
  BleSessionServer? hostSessions;
  BleSessionClient? session;
  int counter = 0;
  bool busy = false;
  void log(Object? message) {
    if (!mounted) return;
    setState(() {
      logs.insert(0, '$message');
      if (logs.length > 80) logs.removeLast();
    });
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      log(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> host() async {
    final counterField = counterDefinition.bind(initialValue: 0);
    final next = BleMessageServer(
      name: name.text,
      configuration: demoProtocol,
      additionalServices: [
        BleService(uuid: counterDefinition.serviceUuid, fields: [counterField]),
      ],
    );
    server = next;
    Future<void> updates = Future.value();
    hostSessions = BleSessionServer(
      server: next,
      applicationProtocol: 'counter-app',
      maxSessions: 2,
      handlers: {
        'increment': (peer, method, payload) {
          final update = updates.then((_) async {
            counter = (counter + 1) % 65536;
            await next.gatt.updateStoredValue(
              counterField,
              counter,
              notify: true,
            );
            await hostSessions!.updateSharedState({'counter': counter});
            log('Counter: $counter');
            return {'counter': counter};
          });
          updates = update.then<void>(
            (_) {},
            onError: (Object e, StackTrace _) {
              log(e);
            },
          );
          return update;
        },
      },
      onAcknowledgedMessage: (peer, payload) {
        log('${peer.id.substring(0, 6)}: $payload');
        return 'Displayed on server';
      },
    );
    subscriptions.add(
      hostSessions!.sessionChanges.listen(
        (peers) => log('Admitted sessions: ${peers.length}'),
      ),
    );
    subscriptions.add(hostSessions!.errors.listen(log));
    subscriptions.add(next.errors.listen(log));
    (await next.requestPermissions()).requireCompatible();
    await next.start();
    await hostSessions!.updateSharedState({'counter': 0});
    log('Server ready. Open this demo on another physical device and scan.');
  }

  Future<void> scan() async {
    if (client == null) {
      final next = BleMessageClient(
        configuration: demoProtocol,
        client: UniversalBleClient(
          reconnect: const BleReconnectPolicy(attempts: 3),
        ),
      );
      client = next;
      session = BleSessionClient(
        client: next,
        applicationProtocol: 'counter-app',
        handler: (method, payload) {
          if (method != 'notice') {
            throw const BleException(
              BleErrorCode.unsupported,
              'Unknown request',
            );
          }
          log('Server: $payload');
          return 'Displayed on client';
        },
      );
      subscriptions.add(
        next.discoveredServers.listen((device) {
          if (mounted) setState(() => found[device.id] = device);
        }),
      );
      subscriptions.add(
        next.stateChanges.listen((state) => log('Connection: ${state.name}')),
      );
      subscriptions.add(next.errors.listen(log));
      subscriptions.add(session!.errors.listen(log));
      subscriptions.add(
        session!.sharedState.listen(
          (state) => log('Shared state #${state.revision}: ${state.value}'),
        ),
      );
    }
    requireClientReady(await client!.requestPermissions());
    found.clear();
    await client!.startScan();
    log('Scanning for demo servers…');
  }

  Future<void> connect(String id) async {
    await client!.connect(id);
    await session!.open();
    final updates = await client!.watchValue(counterDefinition);
    subscriptions.add(
      updates.listen((v) {
        counter = v;
        log('Field notification: $v');
      }, onError: log),
    );
    counter = await client!.readValue(counterDefinition);
    log('Connected to ${client!.serverName}. Current counter: $counter');
  }

  Future<void> release() async {
    for (final s in subscriptions) {
      await s.cancel();
    }
    subscriptions.clear();
    await session?.dispose();
    await hostSessions?.dispose();
    await client?.dispose();
    await server?.dispose();
    session = null;
    hostSessions = null;
    client = null;
    server = null;
    found.clear();
    counter = 0;
  }

  @override
  void dispose() {
    unawaited(release());
    name.dispose();
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Client + server demo')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Use two or three physical devices. One hosts; the others connect. This demo has no authentication—use trusted test devices.',
        ),
        TextField(
          controller: name,
          enabled: server == null && client == null,
          decoration: const InputDecoration(labelText: 'Server name'),
        ),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: busy || server != null || client != null
                  ? null
                  : () => run(host),
              child: const Text('Host server'),
            ),
            FilledButton(
              onPressed:
                  busy ||
                      server != null ||
                      client?.state == BleConnectionState.ready
                  ? null
                  : () => run(scan),
              child: const Text('Scan for servers'),
            ),
            OutlinedButton(
              onPressed: busy ? null : () => run(release),
              child: const Text('Stop / reset'),
            ),
          ],
        ),
        if (client?.state != BleConnectionState.ready)
          ...found.values.map(
            (device) => ListTile(
              title: Text(device.name ?? device.id),
              subtitle: Text(device.id),
              trailing: TextButton(
                onPressed: busy ? null : () => run(() => connect(device.id)),
                child: const Text('Connect'),
              ),
            ),
          ),
        Text('Counter field: $counter'),
        FilledButton(
          onPressed: busy || session?.ready != true
              ? null
              : () => run(() async {
                  log(await session!.request('increment', null, retries: 1));
                }),
          child: const Text('Request increment'),
        ),
        TextField(
          controller: text,
          decoration: const InputDecoration(labelText: 'Message'),
        ),
        FilledButton(
          onPressed: busy || (session?.ready != true && hostSessions == null)
              ? null
              : () => run(() async {
                  if (session != null) {
                    log(await session!.sendAcknowledged(text.text));
                  } else {
                    for (final peer in hostSessions!.sessions.where(
                      (s) => s.clientId != null,
                    )) {
                      log(
                        await hostSessions!.requestClient(
                          peer.id,
                          'notice',
                          text.text,
                        ),
                      );
                    }
                  }
                }),
          child: const Text('Send and wait for reply'),
        ),
        const Divider(),
        ...logs.map(SelectableText.new),
      ],
    ),
  );
}

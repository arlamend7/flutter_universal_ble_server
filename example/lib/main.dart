import 'dart:async';
import 'dart:convert';
import 'client_demo.dart';
import 'chat_demo.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:universal_ble_server/universal_ble_server.dart';

void main() => runApp(const MaterialApp(home: DemoHome()));

class DemoHome extends StatelessWidget {
  const DemoHome({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('BLE examples')),
    body: ListView(
      children: [
        ListTile(
          title: const Text('Simple chat: host, connect and send'),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const ChatDemo())),
        ),
        ListTile(
          title: const Text('Client + server: fields, messages and sessions'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ClientServerDemo()),
          ),
        ),
        ListTile(
          title: const Text('Original message server / browser client'),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const BleExample())),
        ),
      ],
    ),
  );
}

class BleExample extends StatefulWidget {
  const BleExample({super.key});
  @override
  State<BleExample> createState() => _BleExampleState();
}

class _BleExampleState extends State<BleExample> {
  final name = TextEditingController(text: 'Meu servidor BLE');
  final message = TextEditingController(text: 'Olá do servidor!');
  BleMessageServer? server;
  final subscriptions = <StreamSubscription<dynamic>>[];
  final logs = <String>[];
  bool busy = false;
  bool allowRename = false;
  String? target;

  void log(String text) {
    if (!mounted) return;
    setState(() {
      logs.insert(0, text);
      if (logs.length > 100) logs.removeLast();
    });
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
    } catch (error) {
      log('$error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> release() async {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    subscriptions.clear();
    await server?.dispose();
    server = null;
    target = null;
  }

  Future<void> start() async {
    await release();
    final next = BleMessageServer(
      name: name.text,
      allowAndroidAdapterNameChange: allowRename,
    );
    server = next;
    subscriptions.add(
      next.stateChanges.listen((_) {
        if (mounted) setState(() {});
      }),
    );
    subscriptions.add(
      next.receivedMessages.listen((event) {
        log(
          'Recebido de ${event.clientId}: ${utf8.decode(event.data, allowMalformed: true)}',
        );
      }),
    );
    subscriptions.add(
      next.clientEvents.listen((event) {
        if (!next.subscribedClientIds.contains(target)) target = null;
        log('${event.kind.name}: ${event.clientId}');
      }),
    );
    subscriptions.add(next.errors.listen((error) => log('$error')));
    subscriptions.add(
      next.events
          .where((event) => event['type'] == 'warning')
          .listen((event) => log('${event['message']}')),
    );
    final support = await next.requestPermissions();
    support.requireCompatible();
    await next.start();
    log(
      'Servidor iniciado. O cliente deve assinar TX e escrever quadros em RX.',
    );
  }

  @override
  void dispose() {
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(
      server?.dispose().catchError((Object _) {}) ?? Future<void>.value(),
    );
    name.dispose();
    message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final running = server?.state == BleServerState.running;
    final clients = server?.subscribedClientIds ?? <String>{};
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    return Scaffold(
      appBar: AppBar(title: const Text('Mensagens BLE')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TextField(
            controller: name,
            enabled: !busy && !running,
            decoration: const InputDecoration(
              labelText: 'Nome do servidor',
              helperText:
                  'Até 29 bytes UTF-8; alguns sistemas limitam o anúncio.',
            ),
          ),
          if (android)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: allowRename,
              onChanged: busy || running
                  ? null
                  : (value) => setState(() => allowRename = value!),
              title: const Text('Anunciar este nome no Android'),
              subtitle: const Text(
                'Altera o nome Bluetooth do aparelho e tenta restaurá-lo ao parar. Sem essa opção, o nome pode ser lido após conectar.',
              ),
            ),
          const SizedBox(height: 16),
          Text('Estado: ${server?.state.name ?? 'stopped'}'),
          Text('Clientes inscritos para receber: ${clients.length}'),
          const Text(
            'No iOS/macOS/Windows, inscrição não equivale a conexão física.',
          ),
          Wrap(
            spacing: 12,
            children: [
              FilledButton(
                onPressed: busy || running ? null : () => run(start),
                child: const Text('Iniciar'),
              ),
              OutlinedButton(
                onPressed: busy || !running
                    ? null
                    : () => run(() async {
                        await server!.stop();
                        target = null;
                        log('Servidor parado');
                      }),
                child: const Text('Parar'),
              ),
            ],
          ),
          const Divider(height: 32),
          DropdownButton<String>(
            value: target ?? '',
            isExpanded: true,
            items: [
              const DropdownMenuItem(
                value: '',
                child: Text('Todos os inscritos'),
              ),
              ...clients.map(
                (id) => DropdownMenuItem(
                  value: id,
                  child: Text(id, overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
            onChanged: busy
                ? null
                : (value) =>
                      setState(() => target = value == '' ? null : value),
          ),
          TextField(
            controller: message,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Mensagem UTF-8'),
          ),
          FilledButton(
            onPressed: busy || !running || clients.isEmpty
                ? null
                : () => run(() async {
                    await server!.sendText(message.text, clientId: target);
                    log('Enviado: ${message.text}');
                  }),
            child: const Text('Enviar mensagem'),
          ),
          const SelectableText(
            'Protocolo v1: cliente lê NAME, assina TX e escreve RX com resposta. Mensagens usam quadros de até 20 bytes, com cabeçalho de 7 bytes. Consulte doc/PROTOCOL.md.',
          ),
          const Divider(height: 32),
          ...logs.map(
            (line) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SelectableText(line),
            ),
          ),
        ],
      ),
    );
  }
}

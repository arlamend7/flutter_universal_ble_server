import 'dart:async';

import 'package:flutter/material.dart';

import 'acceptance_protocol.dart';

void main() => runApp(const MaterialApp(home: AcceptanceHostPage()));

/// Separate entry point for native acceptance tests; never starts on app launch.
class AcceptanceHostPage extends StatefulWidget {
  const AcceptanceHostPage({super.key});

  @override
  State<AcceptanceHostPage> createState() => _AcceptanceHostPageState();
}

class _AcceptanceHostPageState extends State<AcceptanceHostPage> {
  final _lines = <String>[];
  AcceptanceHost? _host;
  bool _busy = false;
  static const _run = String.fromEnvironment(
    'BLE_TEST_RUN',
    defaultValue: 'local',
  );

  void _log(String line) {
    debugPrint(line);
    if (!mounted) return;
    setState(() {
      _lines.add(line);
      if (_lines.length > 100) _lines.removeAt(0);
    });
  }

  Future<void> _toggle() async {
    setState(() => _busy = true);
    try {
      final previous = _host;
      _host = null;
      if (previous != null) {
        await previous.dispose();
        _log('Stopped');
      } else {
        final host = AcceptanceHost(
          run: _run,
          log: _log,
          assemblyTimeout: const Duration(
            seconds: int.fromEnvironment(
              'BLE_ASSEMBLY_SECONDS',
              defaultValue: 10,
            ),
          ),
        );
        try {
          await host.start();
          if (!mounted) {
            await host.dispose();
            return;
          }
          _host = host;
          _log('READY: run=$_run; start the client test on another device');
        } catch (_) {
          await host.dispose();
          rethrow;
        }
      }
    } catch (error) {
      _log('FAIL: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    final host = _host;
    if (host != null) {
      unawaited(host.dispose().catchError((Object e) => debugPrint('$e')));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('BLE hardware acceptance host')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Run: $_run · Keep this app in the foreground.'),
          const Text('Use trusted test devices. See doc/HARDWARE_TESTING.md.'),
          FilledButton(
            onPressed: _busy ? null : _toggle,
            child: Text(_host == null ? 'Start host' : 'Stop host'),
          ),
          Expanded(
            child: ListView(children: [for (final line in _lines) Text(line)]),
          ),
        ],
      ),
    ),
  );
}

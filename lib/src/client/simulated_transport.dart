import 'dart:async';
import '../communication.dart';
import '../simulated_platform.dart';
import 'transport.dart';

/// Test-only link between the actual Dart client and server implementations.
class SimulatedBleClientTransport extends BleClientTransport {
  SimulatedBleClientTransport(
    this.server, {
    this.clientId = 'client',
    this.writeLimit = 20,
  }) {
    _subscriptions.add(
      server.notificationEvents.listen((event) {
        if (!_connected) return;
        final uuid = event['uuid'] as String;
        if ((event['clientId'] != null && event['clientId'] != clientId) ||
            server.subscribers[uuid]?.contains(clientId) != true) {
          return;
        }
        final profile = server.activeProfile!;
        for (final service in profile.services) {
          if (service.fields.any((f) => f.uuid == uuid)) {
            _notifications.add(
              BleRawNotification(
                '${service.uuid}/$uuid',
                event['value'] as List<int>,
              ),
            );
          }
        }
      }),
    );
    _subscriptions.add(
      server.events.listen((event) {
        if (event['type'] == 'disconnected' && event['clientId'] == clientId) {
          _connected = false;
          _disconnected.add(null);
        }
      }),
    );
  }
  final SimulatedBlePlatform server;
  final String clientId;
  final int writeLimit;
  bool _connected = false;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _states = StreamController<BleAdapterState>.broadcast();
  final _discovered = StreamController<BleDiscoveredServer>.broadcast();
  final _disconnected = StreamController<void>.broadcast();
  final _notifications = StreamController<BleRawNotification>.broadcast();
  @override
  Stream<BleAdapterState> get adapterStates => _states.stream;
  @override
  Stream<BleDiscoveredServer> get discovered => _discovered.stream;
  @override
  Stream<void> get disconnected => _disconnected.stream;
  @override
  Stream<BleRawNotification> get notifications => _notifications.stream;
  @override
  Future<BleAdapterState> checkSupport() async => BleAdapterState.poweredOn;
  @override
  Future<BleAdapterState> requestPermissions() => checkSupport();
  @override
  Future<void> startScan(List<String> serviceUuids) async {
    final profile = server.activeProfile;
    if (profile != null &&
        (serviceUuids.isEmpty ||
            serviceUuids.contains(profile.advertisedServiceUuid))) {
      _discovered.add(
        BleDiscoveredServer('server', name: profile.name, rssi: -40),
      );
    }
  }

  @override
  Future<void> stopScan() async {
    /* Discovery is a single deterministic event. */
  }
  @override
  Future<void> connect(String id) async {
    if (id != 'server' || server.activeProfile == null) {
      throw const BleException(BleErrorCode.disconnected, 'Server unavailable');
    }
    _connected = true;
    server.connect(clientId);
  }

  void _check() {
    if (!_connected || server.activeProfile == null) {
      throw const BleException(BleErrorCode.disconnected, 'Disconnected');
    }
  }

  @override
  Future<List<BleRemoteCharacteristic>> discover() async {
    _check();
    return [
      for (final service in server.activeProfile!.services)
        for (final field in service.fields)
          BleRemoteCharacteristic(service.uuid, field.uuid, field.access),
    ];
  }

  @override
  Future<int> maximumWriteBytes() async => writeLimit;
  @override
  Future<List<int>> read(String key) {
    _check();
    return server.read(key.split('/').last, clientId: clientId);
  }

  @override
  Future<void> write(String key, List<int> bytes) {
    _check();
    if (bytes.length > writeLimit) {
      throw const BleException(BleErrorCode.tooLarge, 'Write too large');
    }
    return server.write(key.split('/').last, bytes, clientId: clientId);
  }

  @override
  Future<void> subscribe(String key, bool enabled) async {
    _check();
    final uuid = key.split('/').last;
    if (enabled) {
      server.subscribe(uuid, clientId);
    } else {
      server.unsubscribe(uuid, clientId);
    }
  }

  @override
  Future<void> disconnect() async {
    if (_connected) {
      _connected = false;
      server.disconnect(clientId);
    }
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    for (final s in _subscriptions) {
      await s.cancel();
    }
    unawaited(_states.close());
    unawaited(_discovered.close());
    unawaited(_disconnected.close());
    unawaited(_notifications.close());
  }
}

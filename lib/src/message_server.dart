import 'dart:async';
import 'dart:convert';
import '../universal_ble_server_impl.dart';
import '../universal_ble_server_platform_interface.dart';
import 'framing.dart';
import 'models.dart';
import 'profile.dart';
import 'communication.dart';

/// Stable, custom UUIDs for the bidirectional message protocol, version 1.
abstract final class BleMessageProtocol {
  static const serviceUuid = 'd973f2e0-b19e-11ee-a506-0242ac120002';

  /// Clients write message frames here (RX from the server's perspective).
  static const clientToServerUuid = 'd973f2e1-b19e-11ee-a506-0242ac120002';

  /// Clients subscribe here to receive server messages (TX).
  static const serverToClientUuid = 'd973f2e2-b19e-11ee-a506-0242ac120002';

  /// Clients read this characteristic to obtain the logical UTF-8 server name.
  static const serverNameUuid = 'd973f2e3-b19e-11ee-a506-0242ac120002';

  /// Compatibility alias for [serviceUuid].
  static const service = serviceUuid;

  /// Compatibility alias for [clientToServerUuid].
  static const receive = clientToServerUuid;

  /// Compatibility alias for [serverToClientUuid].
  static const transmit = serverToClientUuid;

  /// Compatibility alias for [serverNameUuid].
  static const name = serverNameUuid;
}

class BleReceivedMessage {
  BleReceivedMessage({required this.clientId, required List<int> data})
    : data = List.unmodifiable(data);
  final String clientId;
  final List<int> data;
  String get text => utf8.decode(data);
  Object? get json => jsonDecode(text);
}

enum BleClientEventKind { connected, disconnected, subscribed, unsubscribed }

/// Subscription events represent channel readiness, not physical connections.
class BleClientEvent {
  const BleClientEvent(this.clientId, this.kind);
  final String clientId;
  final BleClientEventKind kind;
}

/// A ready-to-use framed BLE message service. Clients write RX with response,
/// subscribe to TX notifications and read NAME for the logical server name.
/// Both peers must implement [BleMessageFramer]'s version 1 wire format.
class BleMessageServer {
  BleMessageServer({
    required this.name,
    int frameBytes = 20,
    int maxMessageBytes = 65535,
    int maxClients = 16,
    int? maxIncomingAssemblies,
    BleMessageConfiguration? configuration,
    List<BleService> additionalServices = const [],
    this.assemblyTimeout = const Duration(seconds: 10),
    bool requireAdvertisedName = false,
    bool allowAndroidAdapterNameChange = false,
    UniversalBleServerPlatform? platform,
  }) : configuration =
           configuration ??
           BleMessageConfiguration(
             frameBytes: frameBytes,
             maxMessageBytes: maxMessageBytes,
           ),
       maxIncomingAssemblies = maxIncomingAssemblies ?? maxClients {
    frameBytes = this.configuration.frameBytes;
    maxMessageBytes = this.configuration.maxMessageBytes;
    maxClients = this.maxIncomingAssemblies;
    if (frameBytes < 8 || frameBytes > 512) {
      throw RangeError.range(frameBytes, 8, 512);
    }
    if (maxMessageBytes < 0 ||
        maxMessageBytes > 65535 ||
        maxClients < 1 ||
        assemblyTimeout <= Duration.zero) {
      throw ArgumentError('Invalid message limits');
    }
    final rx = BleField<List<int>>(
      uuid: this.configuration.clientToServerUuid,
      codec: BleCodecs.bytes,
      initialValue: [],
      access: {BleProperty.write},
      authorizeWrite: (context, value) =>
          value.length >= 7 && value.length <= frameBytes,
    );
    _server = UniversalBleServer(
      platform: platform,
      profile: BleProfile(
        name: name,
        requireAdvertisedName: requireAdvertisedName,
        allowAndroidAdapterNameChange: allowAndroidAdapterNameChange,
        services: [
          BleService(
            uuid: this.configuration.serviceUuid,
            fields: [
              rx,
              BleField<String>(
                uuid: this.configuration.metadataUuid,
                codec: BleCodecs.utf8String,
                initialValue: jsonEncode(this.configuration.metadata),
                access: {BleProperty.read},
              ),
              BleField<List<int>>(
                uuid: this.configuration.serverToClientUuid,
                codec: BleCodecs.bytes,
                initialValue: [],
                access: {BleProperty.notify},
              ),
              BleField<String>(
                uuid: this.configuration.nameUuid,
                codec: BleCodecs.utf8String,
                initialValue: name,
                access: {BleProperty.read},
              ),
            ],
          ),
          ...additionalServices,
        ],
      ),
    );
    _subscriptions.add(_server.clientWrites.listen(_receive));
    _subscriptions.add(_server.events.listen(_event));
    _subscriptions.add(_server.errors.listen(_report));
    _subscriptions.add(
      _server.stateChanges.listen((state) {
        if (state == BleServerState.failed ||
            state == BleServerState.stopping ||
            state == BleServerState.stopped) {
          _reset();
        }
      }),
    );
  }
  final String name;

  /// Defaults to the baseline ATT payload (20 bytes), of which 7 are header.
  /// Increase only when the client protocol and all target MTUs support it.
  final BleMessageConfiguration configuration;
  int get frameBytes => configuration.frameBytes;
  int get maxMessageBytes => configuration.maxMessageBytes;

  /// Compatibility name. This limits assemblies, not connections or sessions.
  int get maxClients => maxIncomingAssemblies;
  final int maxIncomingAssemblies;

  /// Custom fields and messages share this single native server. Use the wrapper
  /// for lifecycle; use this accessor only for field reads/updates/notifications.
  UniversalBleServer get gatt => _server;
  final Duration assemblyTimeout;
  late final UniversalBleServer _server;
  final _messages = StreamController<BleReceivedMessage>.broadcast();
  final _clients = StreamController<BleClientEvent>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _assemblers = <String, BleMessageAssembler>{};
  final _expiry = <String, Timer>{};
  final _peerSessions = <String, int>{};
  final _peers = <String, BlePeerInfo>{};
  final _peerChanges = StreamController<List<BlePeerInfo>>.broadcast();
  final _diagnostics = StreamController<BleDiagnostic>.broadcast();
  int _pendingMessages = 0;
  List<BlePeerInfo> get peers => List.unmodifiable(_peers.values);
  Stream<List<BlePeerInfo>> get peerChanges => _peerChanges.stream;
  Stream<BleDiagnostic> get diagnostics => _diagnostics.stream;
  int _sessionCounter = 0;
  int _messageId = 0;
  int _generation = 0;
  Future<void> _outgoing = Future.value();
  Future<void>? _disposeFuture;
  bool _disposed = false;

  BleServerState get state => _server.state;

  /// Lifecycle changes. Subscribe before [start].
  Stream<BleServerState> get stateChanges => _server.stateChanges;

  /// Complete incoming messages, after frame reassembly.
  Stream<BleReceivedMessage> get receivedMessages => _messages.stream;

  /// Subscription changes and physical connections where supported by the OS.
  Stream<BleClientEvent> get clientEvents => _clients.stream;

  /// Compatibility alias for [stateChanges].
  Stream<BleServerState> get states => stateChanges;

  /// Compatibility alias for [receivedMessages].
  Stream<BleReceivedMessage> get received => receivedMessages;

  /// Compatibility alias for [clientEvents].
  Stream<BleClientEvent> get clients => clientEvents;
  Stream<Object> get errors => _errors.stream;

  /// Includes platform warning events (e.g. advertised name unavailable).
  Stream<Map<String, Object?>> get events => _server.events;

  /// Snapshot of clients subscribed to receive outgoing messages. A physical
  /// connection alone is insufficient; IDs are opaque and platform-local.
  Set<String> get subscribedClientIds => Set.unmodifiable(_peerSessions.keys);

  /// Compatibility alias for [subscribedClientIds].
  Set<String> get readyClients => subscribedClientIds;

  /// Checks BLE server capabilities and readiness; Apple may prompt for consent.
  Future<BleCapabilities> checkSupport() => _server.checkSupport();

  /// Requests OS permission and returns the resulting adapter readiness.
  Future<BleCapabilities> requestPermissions() => _server.requestPermissions();

  /// Registers the message service and begins advertising.
  Future<void> start() => _server.start();

  /// Stops advertising, interrupts transfers and clears client subscriptions.
  /// This instance can be started again.
  Future<void> stop() {
    _reset();
    return _server.stop();
  }

  void _report(Object error) {
    if (!_errors.isClosed) _errors.add(error);
  }

  void _event(Map<String, Object?> event) {
    final id = event['clientId'] as String?;
    if (id == null) return;
    final type = event['type'];
    if (type == 'connected' ||
        type == 'disconnected' ||
        type == 'subscribed' ||
        type == 'unsubscribed' ||
        type == 'mtu') {
      final previous = _peers[id];
      final subscriptions = {...?previous?.subscriptions};
      if (type == 'subscribed') {
        subscriptions.add(normalizeBleUuid(event['uuid'] as String));
      }
      if (type == 'unsubscribed') {
        subscriptions.remove(normalizeBleUuid(event['uuid'] as String));
      }
      if (type == 'disconnected' ||
          (type == 'unsubscribed' &&
              subscriptions.isEmpty &&
              previous?.connected != true)) {
        _peers.remove(id);
      } else {
        _peers[id] = BlePeerInfo(
          clientId: id,
          connected: type == 'connected' ? true : previous?.connected,
          subscriptions: subscriptions,
          maxNotificationBytes:
              event['maxNotificationBytes'] as int? ??
              previous?.maxNotificationBytes,
        );
      }
      _peerChanges.add(peers);
    }
    if ((type == 'subscribed' || type == 'unsubscribed') &&
        normalizeBleUuid(event['uuid'] as String) !=
            configuration.serverToClientUuid) {
      return;
    }
    switch (type) {
      case 'connected':
        _clients.add(BleClientEvent(id, BleClientEventKind.connected));
      case 'disconnected':
        _peerSessions.remove(id);
        _forgetAssembly(id);
        _clients.add(BleClientEvent(id, BleClientEventKind.disconnected));
      case 'subscribed':
        // A duplicate subscription does not invalidate an in-flight message.
        _peerSessions.putIfAbsent(id, () => ++_sessionCounter);
        _clients.add(BleClientEvent(id, BleClientEventKind.subscribed));
      case 'unsubscribed':
        _peerSessions.remove(id);
        _forgetAssembly(id);
        _clients.add(BleClientEvent(id, BleClientEventKind.unsubscribed));
    }
  }

  void _forgetAssembly(String id) {
    _assemblers.remove(id);
    _expiry.remove(id)?.cancel();
  }

  void _receive(BleWriteEvent event) {
    if (normalizeBleUuid(event.characteristicUuid) !=
        configuration.clientToServerUuid) {
      return;
    }
    try {
      if (!_assemblers.containsKey(event.clientId)) {
        if (_assemblers.length >= maxClients) {
          throw StateError('Too many concurrent incoming messages');
        }
        _assemblers[event.clientId] = BleMessageAssembler(
          maxMessageBytes: maxMessageBytes,
          timeout: assemblyTimeout,
        );
        _expiry[event.clientId] = Timer(assemblyTimeout, () {
          _forgetAssembly(event.clientId);
          _report(
            TimeoutException(
              'Incomplete message from ${event.clientId}',
              assemblyTimeout,
            ),
          );
        });
      }
      final message = _assemblers[event.clientId]!.add(event.value);
      if (message != null) {
        _forgetAssembly(event.clientId);
        _messages.add(
          BleReceivedMessage(clientId: event.clientId, data: message),
        );
      }
    } catch (error) {
      _forgetAssembly(event.clientId);
      _report(error);
    }
  }

  void _reset() {
    _generation++;
    for (final timer in _expiry.values) {
      timer.cancel();
    }
    _expiry.clear();
    _assemblers.clear();
    _peerSessions.clear();
    _peers.clear();
    if (!_peerChanges.isClosed) _peerChanges.add(peers);
  }

  /// Sends one complete framed message, targeting one subscribed client or a
  /// snapshot of all current subscribers. Messages never interleave. On partial
  /// failure throws; there are no automatic retries or delivery guarantees.
  /// [excludeClientId] removes a recipient, for example the original sender.
  /// Throws when no target remains subscribed. [sendText] encodes text as UTF-8.
  Future<void> sendBytes(
    List<int> data, {
    String? clientId,
    String? excludeClientId,
  }) {
    if (_disposed) return Future.error(StateError('Server disposed'));
    if (data.length > maxMessageBytes || data.any((b) => b < 0 || b > 255)) {
      return Future.error(ArgumentError('Invalid or oversized message'));
    }
    if (state != BleServerState.running) {
      return Future.error(StateError('Server is not running'));
    }
    final targets = clientId == null
        ? Map<String, int>.of(_peerSessions)
        : <String, int>{
            if (_peerSessions.containsKey(clientId))
              clientId: _peerSessions[clientId]!,
          };
    if (excludeClientId != null) targets.remove(excludeClientId);
    if (targets.isEmpty) {
      return Future.error(StateError('No subscribed clients'));
    }
    if (_pendingMessages >= 128) {
      return Future.error(
        const BleException(BleErrorCode.busy, 'Server message queue full'),
      );
    }
    _pendingMessages++;
    final snapshot = List<int>.of(data);
    final generation = _generation;
    final operation = _outgoing.then((_) async {
      final frames = BleMessageFramer.encode(
        snapshot,
        messageId: _messageId++ % 65536,
        maxFrameBytes: frameBytes,
      );
      for (final frame in frames) {
        for (final target in targets.entries) {
          if (generation != _generation ||
              _peerSessions[target.key] != target.value ||
              state != BleServerState.running) {
            throw StateError(
              'Transfer interrupted by stop, disconnect or unsubscribe',
            );
          }
          await _server.sendNotification(
            configuration.serverToClientUuid,
            frame,
            clientId: target.key,
          );
          if (!_diagnostics.isClosed) {
            _diagnostics.add(
              BleDiagnostic(
                'frameSent',
                bytes: frame.length,
                pending: _pendingMessages,
              ),
            );
          }
        }
      }
    });
    _outgoing = operation
        .then<void>((_) {}, onError: (Object _, StackTrace __) {})
        .whenComplete(() => _pendingMessages--);
    return operation;
  }

  /// Compatibility alias for [sendBytes].
  Future<void> send(List<int> data, {String? clientId}) =>
      sendBytes(data, clientId: clientId);

  /// Encodes UTF-8 text and sends a complete message using [sendBytes].
  Future<void> sendText(
    String text, {
    String? clientId,
    String? excludeClientId,
  }) => sendBytes(
    utf8.encode(text),
    clientId: clientId,
    excludeClientId: excludeClientId,
  );

  /// Encodes JSON as UTF-8. Both peers must agree on its application schema.
  Future<void> sendJson(
    Object? value, {
    String? clientId,
    String? excludeClientId,
  }) => sendText(
    jsonEncode(value),
    clientId: clientId,
    excludeClientId: excludeClientId,
  );

  /// Stops permanently and closes streams. Safe to call more than once.
  Future<void> dispose() {
    if (_disposeFuture != null) return _disposeFuture!;
    _disposed = true;
    _reset();
    return _disposeFuture = () async {
      try {
        await _server.dispose();
      } finally {
        for (final subscription in _subscriptions) {
          await subscription.cancel();
        }
        unawaited(_messages.close());
        unawaited(_clients.close());
        unawaited(_errors.close());
        unawaited(_peerChanges.close());
        unawaited(_diagnostics.close());
      }
    }();
  }
}

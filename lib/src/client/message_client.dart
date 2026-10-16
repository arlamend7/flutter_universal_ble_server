import 'dart:async';
import 'dart:convert';
import '../communication.dart';
import '../framing.dart';
import '../models.dart';
import 'client.dart';
import 'transport.dart';

/// Matching central for BleMessageServer, including protocol verification.
class BleMessageClient {
  /// Creates a client owning [client], or the platform client when omitted.
  /// Dispose this wrapper to release the underlying connection.
  BleMessageClient({
    UniversalBleClient? client,
    BleMessageConfiguration? configuration,
    this.assemblyTimeout = const Duration(seconds: 10),
  }) : client = client ?? UniversalBleClient(),
       configuration = configuration ?? BleMessageConfiguration() {
    if (assemblyTimeout <= Duration.zero) {
      throw ArgumentError('Invalid assembly timeout');
    }
    _assembler = BleMessageAssembler(
      maxMessageBytes: this.configuration.maxMessageBytes,
      timeout: assemblyTimeout,
    );
    _subscriptions.add(
      this.client.stateChanges.listen((s) {
        if (s == BleConnectionState.ready) {
          unawaited(
            _prepare().catchError((Object e) {
              if (!_disposed) _errors.add(e);
            }),
          );
        } else {
          _ready = false;
          if (s == BleConnectionState.disconnected ||
              s == BleConnectionState.reconnecting ||
              s == BleConnectionState.disposed) {
            _generation++;
            _expiry?.cancel();
            _assembler.reset();
          }
          _states.add(s);
        }
      }),
    );
    _subscriptions.add(this.client.errors.listen(_errors.add));
  }

  /// Underlying typed GATT client; use the convenience extensions for fields.
  final UniversalBleClient client;

  /// Shared wire contract, checked against server metadata before readiness.
  final BleMessageConfiguration configuration;

  /// Maximum time allowed for one incoming fragmented message.
  final Duration assemblyTimeout;
  late final BleMessageAssembler _assembler;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  StreamSubscription<List<int>>? _incoming;
  final _messages = StreamController<List<int>>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _states = StreamController<BleConnectionState>.broadcast();
  final _diagnostics = StreamController<BleDiagnostic>.broadcast();

  /// Complete immutable byte messages. Subscribe before connecting.
  Stream<List<int>> get receivedMessages => _messages.stream;

  /// Complete messages decoded as UTF-8; malformed text emits a stream error.
  Stream<String> get receivedText => receivedMessages.map(utf8.decode);

  /// Complete JSON values; malformed text/JSON emits a stream error.
  Stream<Object?> get receivedJson => receivedText.map(jsonDecode);

  /// Asynchronous transport/setup errors, independent of returned call futures.
  Stream<Object> get errors => _errors.stream;

  /// Connection and message readiness changes; does not replay current state.
  Stream<BleConnectionState> get stateChanges => _states.stream;

  /// Frame counters and queue information without payload recording.
  Stream<BleDiagnostic> get diagnostics => _diagnostics.stream;

  /// Current readiness; ready means metadata and subscriptions are established.
  BleConnectionState get state => _ready
      ? BleConnectionState.ready
      : (client.state == BleConnectionState.ready
            ? BleConnectionState.subscribing
            : client.state);

  /// Logical server name read during setup; may differ from advertisement name.
  String? serverName;
  bool _ready = false, _disposed = false;
  int _generation = 0, _messageId = 0, _pending = 0;
  Timer? _expiry;
  Future<void> _outgoing = Future.value();
  Future<void>? _preparing;
  Future<void>? _disposeFuture;
  int _preparingGeneration = -1;
  Future<void> _prepare() {
    if (_preparing != null && _preparingGeneration == _generation) {
      return _preparing!;
    }
    _preparingGeneration = _generation;
    late Future<void> future;
    future = _prepareNow().whenComplete(() {
      if (identical(_preparing, future)) _preparing = null;
    });
    _preparing = future;
    return future;
  }

  Future<void> _prepareNow() async {
    if (_ready) return;
    if (_disposed) throw StateError('Client disposed');
    final generation = _generation;
    _states.add(BleConnectionState.subscribing);
    try {
      final bytes = await client.readValue(
        configuration.field(configuration.metadataUuid, {BleProperty.read}),
      );
      configuration.verify(jsonDecode(utf8.decode(bytes)));
      if (configuration.frameBytes > client.maxWriteBytes) {
        throw const BleException(
          BleErrorCode.tooLarge,
          'Configured frame size exceeds negotiated write limit',
        );
      }
      serverName = utf8.decode(
        await client.readValue(
          configuration.field(configuration.nameUuid, {BleProperty.read}),
        ),
      );
      if (_incoming == null) {
        final stream = await client.watchValue(
          configuration.field(configuration.serverToClientUuid, {
            BleProperty.notify,
          }),
        );
        _incoming = stream.listen((frame) {
          try {
            _expiry ??= Timer(assemblyTimeout, () {
              _expiry = null;
              _assembler.reset();
              _errors.add(
                const BleException(
                  BleErrorCode.timeout,
                  'Incomplete incoming message',
                ),
              );
            });
            final complete = _assembler.add(frame);
            if (complete != null) {
              _expiry?.cancel();
              _expiry = null;
              _messages.add(List.unmodifiable(complete));
            }
          } catch (e) {
            _expiry?.cancel();
            _expiry = null;
            _errors.add(e);
          }
        }, onError: _errors.add);
      }
      if (_disposed || generation != _generation) {
        throw const BleException(
          BleErrorCode.disconnected,
          'Connection changed during setup',
        );
      }
      _ready = true;
      _states.add(BleConnectionState.ready);
    } catch (_) {
      if (!_disposed && generation == _generation) {
        _ready = false;
        await client.disconnect();
      }
      rethrow;
    }
  }

  /// Live scan results. Use discover() for a bounded, deduplicated list.
  Stream<BleDiscoveredServer> get discoveredServers => client.discoveredServers;

  /// Checks native capability, consent and power; Apple may prompt on access.
  Future<BleAdapterState> checkSupport() => client.checkSupport();

  /// Requests the operating system permissions for the client role.
  Future<BleAdapterState> requestPermissions() => client.requestPermissions();

  /// Scans only for this configuration's service, stopping after [duration].
  Future<void> startScan({Duration duration = const Duration(seconds: 10)}) =>
      client.startScan(
        serviceUuids: [configuration.serviceUuid],
        duration: duration,
      );

  /// Stops scanning; also completes a pending discover() early.
  Future<void> stopScan() => client.stopScan();

  /// Connects to a discovered ID and verifies the protocol before completing.
  Future<void> connect(String id) async {
    await client.connect(id);
    await _prepare();
  }

  /// Intentionally disconnects and cancels automatic reconnection attempts.
  Future<void> disconnect() async {
    _ready = false;
    _generation++;
    await client.disconnect();
  }

  /// Queues an immutable message snapshot and fragments it to the configured size.
  /// Requires readiness. Completion does not acknowledge remote application work.
  Future<void> sendBytes(List<int> bytes) {
    if (!_ready || _disposed) {
      return Future.error(
        const BleException(
          BleErrorCode.disconnected,
          'Message client is not ready',
        ),
      );
    }
    if (bytes.length > configuration.maxMessageBytes ||
        bytes.any((b) => b < 0 || b > 255)) {
      return Future.error(
        const BleException(
          BleErrorCode.tooLarge,
          'Invalid message size or bytes',
        ),
      );
    }
    if (_pending >= 128) {
      return Future.error(
        const BleException(BleErrorCode.busy, 'Outgoing queue full'),
      );
    }
    final snapshot = List<int>.of(bytes);
    final generation = _generation;
    _pending++;
    final result = _outgoing.then((_) async {
      final frames = BleMessageFramer.encode(
        snapshot,
        messageId: _messageId++ % 65536,
        maxFrameBytes: configuration.frameBytes,
      );
      for (final frame in frames) {
        if (!_ready || generation != _generation) {
          throw const BleException(
            BleErrorCode.disconnected,
            'Transfer interrupted',
          );
        }
        await client.writeValue(
          configuration.field(configuration.clientToServerUuid, {
            BleProperty.write,
          }),
          frame,
        );
        if (!_diagnostics.isClosed) {
          _diagnostics.add(
            BleDiagnostic('frameSent', bytes: frame.length, pending: _pending),
          );
        }
      }
    });
    _outgoing = result
        .then<void>((_) {}, onError: (Object _, StackTrace __) {})
        .whenComplete(() => _pending--);
    return result;
  }

  /// Encodes UTF-8 and sends a complete framed message.
  Future<void> sendText(String text) => sendBytes(utf8.encode(text));

  /// Encodes a JSON-serializable value and sends a complete framed message.
  Future<void> sendJson(Object? value) => sendText(jsonEncode(value));

  /// Releases the owned client and closes streams, even if native cleanup fails.
  /// Concurrent calls share the same cleanup future.
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    if (_disposed) return;
    _disposed = true;
    _ready = false;
    _generation++;
    _expiry?.cancel();
    await _incoming?.cancel();
    for (final s in _subscriptions) {
      await s.cancel();
    }
    try {
      await client.dispose();
    } finally {
      unawaited(_messages.close());
      unawaited(_errors.close());
      unawaited(_states.close());
      unawaited(_diagnostics.close());
    }
  }
}

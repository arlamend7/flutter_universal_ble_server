import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'communication.dart';

String bleRandomToken() {
  final random = Random.secure();
  return base64UrlEncode(
    List.generate(32, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
}

/// Detached JSON copy prevents application mutation after queueing/snapshotting.
Object? bleJsonCopy(Object? value) => jsonDecode(jsonEncode(value));

typedef BleRpcHandler =
    FutureOr<Object?> Function(String method, Object? payload);

class BleRpcEvent {
  const BleRpcEvent(this.name, this.payload);
  final String name;
  final Object? payload;
}

class BleRpcReply {
  const BleRpcReply(this.value, [this.error]);
  final Object? value;
  final String? error;
}

class _CachedRequest {
  _CachedRequest(this.fingerprint, this.future, this.created);
  final String fingerprint;
  final Future<BleRpcReply> future;
  final DateTime created;
  bool complete = false;
}

/// Bounded deduplication window. Share across resumed channels for one session.
/// This is not durable storage or an exactly-once execution guarantee.
class BleRequestCache {
  BleRequestCache({
    this.capacity = 256,
    this.retention = const Duration(minutes: 5),
  }) {
    if (capacity < 1 || retention <= Duration.zero) {
      throw ArgumentError('Invalid cache limits');
    }
  }
  final int capacity;
  final Duration retention;
  final _entries = <String, _CachedRequest>{};
  Future<BleRpcReply> execute(
    String id,
    String fingerprint,
    Future<BleRpcReply> Function() action,
  ) {
    final now = DateTime.now();
    _entries.removeWhere(
      (_, e) => e.complete && now.difference(e.created) > retention,
    );
    final existing = _entries[id];
    if (existing != null) {
      if (existing.fingerprint != fingerprint) {
        throw const BleException(
          BleErrorCode.invalidData,
          'Request ID reused with different content',
        );
      }
      return existing.future;
    }
    if (_entries.length >= capacity) {
      throw const BleException(
        BleErrorCode.busy,
        'Deduplication window full; retry after retention expires',
      );
    }
    final completer = Completer<BleRpcReply>();
    final entry = _CachedRequest(fingerprint, completer.future, now);
    _entries[id] = entry;
    unawaited(() async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        entry.complete = true;
      }
    }());
    return completer.future;
  }
}

/// Optional JSON request/reply protocol carried inside complete BLE messages.
/// A response acknowledges handler completion, not a durable application commit.
class BleRpcChannel {
  BleRpcChannel({
    required Stream<List<int>> incoming,
    required this.send,
    required this.handler,
    BleRequestCache? cache,
    this.timeout = const Duration(seconds: 5),
    this.handlerTimeout = const Duration(seconds: 10),
    this.maxPending = 32,
    this.maxMessageBytes = 65535,
  }) : cache = cache ?? BleRequestCache() {
    if (timeout <= Duration.zero ||
        handlerTimeout <= Duration.zero ||
        maxPending < 1 ||
        maxMessageBytes < 1 ||
        maxMessageBytes > 65535) {
      throw ArgumentError('Invalid RPC limits');
    }
    _subscription = incoming.listen(
      (bytes) {
        unawaited(_receive(bytes).catchError(_report));
      },
      onError: _report,
      onDone: close,
    );
  }
  final Future<void> Function(List<int>) send;
  final BleRpcHandler handler;
  BleRequestCache cache;
  final _handshakeCache = BleRequestCache();
  final Duration timeout, handlerTimeout;
  final int maxPending, maxMessageBytes;
  late final StreamSubscription<List<int>> _subscription;
  final _pending = <String, Completer<Map<String, Object?>>>{};
  final _events = StreamController<BleRpcEvent>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _diagnostics = StreamController<BleDiagnostic>.broadcast();
  final String _prefix = bleRandomToken();
  int _counter = 0;
  bool _closed = false;
  final _closedSignal = Completer<void>();
  Stream<BleRpcEvent> get events => _events.stream;
  Stream<Object> get errors => _errors.stream;
  Stream<BleDiagnostic> get diagnostics => _diagnostics.stream;
  void _report(Object e) {
    if (!_closed) {
      _errors.add(e);
      _diagnostics.add(BleDiagnostic('error', error: e));
    }
  }

  Future<void> _send(Map<String, Object?> envelope) async {
    if (_closed) {
      throw const BleException(BleErrorCode.disconnected, 'RPC channel closed');
    }
    final bytes = utf8.encode(jsonEncode({'v': 1, ...envelope}));
    if (bytes.length > maxMessageBytes) {
      throw const BleException(
        BleErrorCode.tooLarge,
        'RPC envelope exceeds message limit',
      );
    }
    await Future.any<void>([
      send(bytes),
      _closedSignal.future.then(
        (_) => throw const BleException(
          BleErrorCode.disconnected,
          'RPC channel closed',
        ),
      ),
    ]).timeout(timeout);
    if (!_closed) {
      _diagnostics.add(
        BleDiagnostic(
          'messageSent',
          bytes: bytes.length,
          pending: _pending.length,
        ),
      );
    }
  }

  /// Retries are opt-in, use the same ID and require the remote deduplication
  /// cache to outlive the retry window. A timeout does not cancel remote work.
  Future<Object?> request(
    String method,
    Object? payload, {
    int retries = 0,
    String? requestId,
  }) async {
    if (_closed) {
      throw const BleException(BleErrorCode.disconnected, 'RPC channel closed');
    }
    if (method.isEmpty || method.length > 128 || retries < 0 || retries > 10) {
      throw ArgumentError('Invalid request options');
    }
    if (_pending.length >= maxPending) {
      throw const BleException(BleErrorCode.busy, 'Too many pending requests');
    }
    final id = requestId ?? '$_prefix:${_counter++}';
    if (id.isEmpty || id.length > 128) {
      throw ArgumentError('Request ID must contain 1..128 characters');
    }
    if (_pending.containsKey(id)) {
      throw const BleException(
        BleErrorCode.busy,
        'Request ID is already pending',
      );
    }
    final completer = Completer<Map<String, Object?>>();
    // Observe errors even if disconnect happens while the send is still pending.
    unawaited(
      completer.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      ),
    );
    final copiedPayload = bleJsonCopy(payload);
    _pending[id] = completer;
    final envelope = <String, Object?>{
      't': 'req',
      'id': id,
      'method': method,
      'payload': copiedPayload,
    };
    try {
      for (var attempt = 0; ; attempt++) {
        try {
          await _send(envelope);
          final response = await completer.future.timeout(timeout);
          if (response['error'] != null) {
            throw BleException(
              BleErrorCode.remote,
              response['error'] as String,
            );
          }
          return response['payload'];
        } on TimeoutException catch (e) {
          if (attempt >= retries) {
            throw BleException(
              BleErrorCode.timeout,
              'Request timed out; outcome is unknown',
              e,
            );
          }
          if (!_closed) {
            _diagnostics.add(BleDiagnostic('retry', pending: _pending.length));
          }
        }
      }
    } finally {
      _pending.remove(id);
    }
  }

  Future<T> requestTyped<T>(
    String method,
    Object? payload,
    T Function(Object?) decode, {
    int retries = 0,
    String? requestId,
  }) async => decode(
    await request(method, payload, retries: retries, requestId: requestId),
  );
  Future<void> sendEvent(String name, Object? payload) {
    if (name.isEmpty || name.length > 128) {
      throw ArgumentError('Invalid event name');
    }
    return _send({'t': 'evt', 'method': name, 'payload': bleJsonCopy(payload)});
  }

  /// The remote '$message' handler must complete before this resolves.
  Future<Object?> sendAcknowledged(
    Object? payload, {
    int retries = 0,
    String? requestId,
  }) => request(r'$message', payload, retries: retries, requestId: requestId);
  Future<void> _receive(List<int> bytes) async {
    if (_closed) return;
    if (bytes.length > maxMessageBytes) {
      throw const BleException(BleErrorCode.tooLarge, 'RPC envelope too large');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> || decoded['v'] != 1) {
      throw const BleException(
        BleErrorCode.incompatibleProtocol,
        'Invalid RPC envelope/version',
      );
    }
    final message = Map<String, Object?>.from(decoded);
    final type = message['t'];
    if (type == 'res') {
      final id = message['id'];
      if (id is! String ||
          (message['error'] != null && message['error'] is! String)) {
        throw const FormatException('Invalid reply');
      }
      final pending = _pending[id];
      if (pending != null && !pending.isCompleted) pending.complete(message);
      return;
    }
    final method = message['method'];
    if (method is! String || method.isEmpty || method.length > 128) {
      throw const FormatException('Invalid method');
    }
    if (type == 'evt') {
      _events.add(BleRpcEvent(method, message['payload']));
      return;
    }
    if (type != 'req' ||
        message['id'] is! String ||
        (message['id'] as String).length > 128) {
      throw const FormatException('Invalid request');
    }
    final id = message['id'] as String;
    BleRpcReply reply;
    try {
      reply = await (method == r'$hello' ? _handshakeCache : cache).execute(
        id,
        jsonEncode([method, message['payload']]),
        () async {
          try {
            final value = await Future<Object?>.sync(
              () => handler(method, message['payload']),
            ).timeout(handlerTimeout);
            final copy = bleJsonCopy(value);
            if (utf8
                    .encode(
                      jsonEncode({
                        'v': 1,
                        't': 'res',
                        'id': id,
                        'payload': copy,
                        'error': null,
                      }),
                    )
                    .length >
                maxMessageBytes) {
              throw const BleException(
                BleErrorCode.tooLarge,
                'Response exceeds message limit',
              );
            }
            return BleRpcReply(copy);
          } catch (e) {
            _report(e);
            // Do not disclose handler exceptions or secrets to the peer.
            return BleRpcReply(
              null,
              e is BleException ? e.code.name : 'handlerFailed',
            );
          }
        },
      );
    } catch (e) {
      reply = BleRpcReply(
        null,
        e is BleException ? e.code.name : 'invalidRequest',
      );
    }
    if (!_closed) {
      await _send({
        't': 'res',
        'id': id,
        'payload': reply.value,
        'error': reply.error,
      });
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _closedSignal.complete();
    for (final p in _pending.values) {
      if (!p.isCompleted) {
        p.completeError(
          const BleException(BleErrorCode.disconnected, 'RPC channel closed'),
        );
      }
    }
    _pending.clear();
    await _subscription.cancel();
    unawaited(_events.close());
    unawaited(_errors.close());
    unawaited(_diagnostics.close());
  }
}

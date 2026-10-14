import 'dart:async';
import 'communication.dart';
import 'message_server.dart';
import 'client/message_client.dart';
import 'client/transport.dart';
import 'rpc.dart';

typedef BleSessionRequestHandler =
    FutureOr<Object?> Function(
      BleSession session,
      String method,
      Object? payload,
    );

class BleSession {
  BleSession._(this.id, this.token, this.principal, this.lastSeen, this.cache);
  final String id;

  /// Bearer secret: do not log or expose. No application encryption is provided.
  final String token;
  final String principal;
  DateTime lastSeen;
  String? clientId;
  final BleRequestCache cache;
}

class BleSharedSnapshot {
  BleSharedSnapshot(this.revision, Object? value) : _value = bleJsonCopy(value);
  final int revision;
  final Object? _value;
  Object? get value => bleJsonCopy(_value);
}

/// Optional admitted sessions + request handlers + public shared-state snapshots.
/// Start this wrapper before clients connect; it owns its message subscriptions,
/// not the underlying server lifecycle. Authentication is application-supplied.
class BleSessionServer {
  BleSessionServer({
    required this.server,
    required this.applicationProtocol,
    this.version = 1,
    this.maxSessions = 8,
    this.maxPendingConnections = 4,
    this.requestTimeout = const Duration(seconds: 5),
    this.handlerTimeout = const Duration(seconds: 10),
    this.maxPendingRequests = 32,
    this.requestCacheCapacity = 256,
    this.requestCacheRetention = const Duration(minutes: 5),
    this.sessionRetention = const Duration(minutes: 5),
    this.authenticate,
    this.authorize,
    this.projectState,
    this.onAcknowledgedMessage,
    Map<String, BleSessionRequestHandler> handlers = const {},
  }) : handlers = Map.of(handlers) {
    if (applicationProtocol.isEmpty ||
        version < 1 ||
        maxSessions < 1 ||
        maxPendingConnections < 0 ||
        maxPendingRequests < 1 ||
        requestCacheCapacity < 1 ||
        requestCacheRetention <= Duration.zero ||
        requestTimeout <= Duration.zero ||
        handlerTimeout <= Duration.zero ||
        sessionRetention <= Duration.zero) {
      throw ArgumentError('Invalid session configuration');
    }
    _subscriptions.add(
      server.receivedMessages.listen((m) {
        final channel = _channels[m.clientId];
        if (channel != null) _inputs[m.clientId]!.add(m.data);
      }),
    );
    _subscriptions.add(
      server.clientEvents.listen((e) {
        if (e.kind == BleClientEventKind.subscribed) _attach(e.clientId);
        if (e.kind == BleClientEventKind.unsubscribed ||
            e.kind == BleClientEventKind.disconnected) {
          _detach(e.clientId);
        }
      }),
    );
    _subscriptions.add(
      server.states.listen((s) {
        if (s.name == 'stopping' || s.name == 'failed' || s.name == 'stopped') {
          for (final id in _channels.keys.toList()) {
            _detach(id);
          }
        }
      }),
    );
    for (final id in server.subscribedClientIds) {
      _attach(id);
    }
  }
  final BleMessageServer server;
  final String applicationProtocol;
  final int version,
      maxSessions,
      maxPendingConnections,
      maxPendingRequests,
      requestCacheCapacity;
  final Duration requestTimeout, handlerTimeout, requestCacheRetention;
  final Duration sessionRetention;

  /// Return a stable principal or null to reject. Re-run on every resume.
  final FutureOr<String?> Function(Object? credentials)? authenticate;

  /// Runs before each application request, including state reads.
  final FutureOr<bool> Function(
    BleSession session,
    String method,
    Object? payload,
  )?
  authorize;

  /// Return a per-session view to keep private state out of broadcasts.
  final FutureOr<Object?> Function(BleSession session, Object? state)?
  projectState;
  final FutureOr<Object?> Function(BleSession session, Object? payload)?
  onAcknowledgedMessage;
  final Map<String, BleSessionRequestHandler> handlers;
  final _sessions = <String, BleSession>{};
  final _channels = <String, BleRpcChannel>{};
  final _inputs = <String, StreamController<List<int>>>{};
  final _channelSubscriptions = <String, List<StreamSubscription<dynamic>>>{};
  final String _instanceId = bleRandomToken();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _errors = StreamController<Object>.broadcast();
  final _diagnostics = StreamController<BleDiagnostic>.broadcast();
  final _changes = StreamController<List<BleSession>>.broadcast();
  int _revision = 0;
  Object? _state;
  bool _disposed = false;
  Future<void> _mutations = Future.value();
  int _pendingUpdates = 0;
  Stream<Object> get errors => _errors.stream;
  Stream<BleDiagnostic> get diagnostics => _diagnostics.stream;
  Stream<List<BleSession>> get sessionChanges => _changes.stream;
  List<BleSession> get sessions => List.unmodifiable(_sessions.values);
  BleSession? sessionForClient(String clientId) {
    for (final session in _sessions.values) {
      if (session.clientId == clientId) return session;
    }
    return null;
  }

  void _report(Object e) {
    if (!_disposed) _errors.add(e);
  }

  void _attach(String id) {
    if (_disposed || _channels.containsKey(id)) return;
    // Bounds unauthenticated protocol handlers independently of physical links.
    if (_channels.length >= maxSessions + maxPendingConnections) {
      _report(
        const BleException(
          BleErrorCode.busy,
          'Too many pending session channels',
        ),
      );
      return;
    }
    // Ownership transfers to _inputs; _detach closes it on disconnect/dispose.
    // ignore: close_sinks
    final input = StreamController<List<int>>();
    _inputs[id] = input;
    final channel = BleRpcChannel(
      incoming: input.stream,
      send: (bytes) => server.sendBytes(bytes, clientId: id),
      maxMessageBytes: server.maxMessageBytes,
      timeout: requestTimeout,
      handlerTimeout: handlerTimeout,
      maxPending: maxPendingRequests,
      handler: (method, payload) => _handle(id, method, payload),
    );
    _channels[id] = channel;
    _channelSubscriptions[id] = [
      channel.errors.listen(_report),
      channel.diagnostics.listen((e) {
        if (!_disposed) _diagnostics.add(e);
      }),
    ];
  }

  void _detach(String id) {
    for (final subscription
        in _channelSubscriptions.remove(id) ??
            <StreamSubscription<dynamic>>[]) {
      unawaited(subscription.cancel());
    }
    final channel = _channels.remove(id);
    if (channel != null) unawaited(channel.close());
    final input = _inputs.remove(id);
    if (input != null) unawaited(input.close());
    for (final session in _sessions.values) {
      if (session.clientId == id) {
        session.clientId = null;
        session.lastSeen = DateTime.now();
      }
    }
    if (!_disposed) _changes.add(sessions);
  }

  BleSession _session(String id) => _sessions.values.firstWhere(
    (s) => s.clientId == id,
    orElse: () => throw const BleException(
      BleErrorCode.unauthorized,
      'Open a session first',
    ),
  );
  Future<Object?> _handle(String id, String method, Object? payload) async {
    final original = _channels[id];
    final elapsed = Stopwatch()..start();
    void ensureActive() {
      if (elapsed.elapsed >= handlerTimeout) {
        throw const BleException(
          BleErrorCode.timeout,
          'Session request expired',
        );
      }
      if (_disposed || original != _channels[id]) {
        throw const BleException(
          BleErrorCode.disconnected,
          'Connection changed',
        );
      }
    }

    if (method == r'$hello') {
      if (payload is! Map ||
          payload['protocol'] != applicationProtocol ||
          payload['version'] != version) {
        throw const BleException(
          BleErrorCode.incompatibleProtocol,
          'Application protocol mismatch',
        );
      }
      final principal = authenticate == null
          ? 'anonymous'
          : await Future<String?>.sync(
              () => authenticate!(payload['credentials']),
            ).timeout(handlerTimeout);
      if (principal == null) {
        throw const BleException(BleErrorCode.unauthorized, 'Session rejected');
      }
      ensureActive();
      // Admission and cache binding happen synchronously after authentication.
      _sessions.removeWhere(
        (_, s) =>
            s.clientId == null &&
            DateTime.now().difference(s.lastSeen) > sessionRetention,
      );
      BleSession? session;
      final token = payload['resumeToken'];
      if (token != null) {
        for (final s in _sessions.values) {
          if (s.token == token && s.principal == principal) session = s;
        }
        if (session == null) {
          throw const BleException(
            BleErrorCode.unauthorized,
            'Resume token expired or invalid',
          );
        }
        if (session.clientId != null && session.clientId != id) {
          throw const BleException(
            BleErrorCode.busy,
            'Session is already active',
          );
        }
      } else {
        if (_sessions.values.any((s) => s.clientId == id)) {
          throw const BleException(
            BleErrorCode.busy,
            'Session already admitted',
          );
        }
        if (_sessions.length >= maxSessions) {
          throw const BleException(BleErrorCode.busy, 'Session limit reached');
        }
        session = BleSession._(
          bleRandomToken(),
          bleRandomToken(),
          principal,
          DateTime.now(),
          BleRequestCache(
            capacity: requestCacheCapacity,
            retention: requestCacheRetention,
          ),
        );
        _sessions[session.id] = session;
      }
      if (_sessions.values.any(
        (s) => s.clientId == id && !identical(s, session),
      )) {
        throw const BleException(
          BleErrorCode.busy,
          'Connection already has a different session',
        );
      }
      session.clientId = id;
      session.lastSeen = DateTime.now();
      original!.cache = session.cache;
      _changes.add(sessions);
      return {
        'sessionId': session.id,
        'resumeToken': session.token,
        'instanceId': _instanceId,
      };
    }
    final session = _session(id);
    session.lastSeen = DateTime.now();
    if (authorize != null &&
        !await Future<bool>.sync(
          () => authorize!(session, method, payload),
        ).timeout(handlerTimeout)) {
      throw const BleException(BleErrorCode.unauthorized, 'Operation rejected');
    }
    ensureActive();
    if (session.clientId != id) {
      throw const BleException(BleErrorCode.disconnected, 'Session changed');
    }
    if (method == r'$snapshot') return _snapshot(session);
    if (method == r'$message') {
      if (onAcknowledgedMessage == null) {
        throw const BleException(
          BleErrorCode.unsupported,
          'No acknowledged-message handler',
        );
      }
      return onAcknowledgedMessage!(session, payload);
    }
    final handler = handlers[method];
    if (handler == null || method.startsWith(r'$')) {
      throw const BleException(BleErrorCode.unsupported, 'Unknown request');
    }
    return handler(session, method, payload);
  }

  Future<Map<String, Object?>> _snapshot(BleSession session) async {
    final revision = _revision;
    final state = bleJsonCopy(_state);
    return {
      'revision': revision,
      'value': projectState == null
          ? state
          : bleJsonCopy(
              await Future<Object?>.sync(
                () => projectState!(session, state),
              ).timeout(handlerTimeout),
            ),
    };
  }

  /// Serializes snapshots and sends each session its projected view. State is
  /// retained even if delivery fails; clients can explicitly refresh it later.
  Future<void> updateSharedState(Object? state) {
    if (_disposed) return Future.error(StateError('Session server disposed'));
    if (_pendingUpdates >= 32) {
      return Future.error(
        const BleException(BleErrorCode.busy, 'Shared state update queue full'),
      );
    }
    final copy = bleJsonCopy(state);
    _pendingUpdates++;
    final result = _mutations.then((_) async {
      if (_disposed) throw StateError('Session server disposed');
      _state = copy;
      _revision++;
      for (final session in sessions) {
        final id = session.clientId;
        final channel = _channels[id];
        if (channel == null) continue;
        try {
          if (authorize != null &&
              !await Future<bool>.sync(
                () => authorize!(session, r'$snapshot', null),
              ).timeout(handlerTimeout)) {
            continue;
          }
          final snapshot = await _snapshot(session);
          if (session.clientId == id && identical(channel, _channels[id])) {
            await channel.sendEvent(r'$state', snapshot);
          }
        } catch (e) {
          _report(e);
        }
      }
    });
    _mutations = result
        .then<void>((_) {}, onError: (Object _, StackTrace __) {})
        .whenComplete(() => _pendingUpdates--);
    return result;
  }

  Future<Object?> requestClient(
    String sessionId,
    String method,
    Object? payload, {
    int retries = 0,
    String? requestId,
  }) {
    final session = _sessions[sessionId];
    final channel = _channels[session?.clientId];
    if (channel == null) {
      return Future.error(
        const BleException(BleErrorCode.disconnected, 'Session offline'),
      );
    }
    return channel.request(
      method,
      payload,
      retries: retries,
      requestId: requestId,
    );
  }

  /// Revokes the logical session. Portable forced physical disconnect is not
  /// exposed by all server backends; future application requests are rejected.
  void removeSession(String sessionId) {
    final session = _sessions.remove(sessionId);
    if (session?.clientId != null) _detach(session!.clientId!);
    if (!_disposed) _changes.add(sessions);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final id in _channels.keys.toList()) {
      _detach(id);
    }
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _sessions.clear();
    unawaited(_errors.close());
    unawaited(_diagnostics.close());
    unawaited(_changes.close());
  }
}

/// Reopens a logical session and fetches a fresh snapshot after BLE reconnects.
class BleSessionClient {
  BleSessionClient({
    required this.client,
    required this.applicationProtocol,
    this.version = 1,
    this.credentials,
    this.handler,
    this.resumeToken,
    this.requestTimeout = const Duration(seconds: 5),
    this.handlerTimeout = const Duration(seconds: 10),
    this.maxPendingRequests = 32,
  }) {
    if (applicationProtocol.isEmpty ||
        version < 1 ||
        requestTimeout <= Duration.zero ||
        handlerTimeout <= Duration.zero ||
        maxPendingRequests < 1) {
      throw ArgumentError('Invalid session configuration');
    }
    _subscription = client.stateChanges.listen((state) {
      if (state == BleConnectionState.ready) {
        unawaited(open().catchError(_report));
      } else {
        _generation++;
        _ready = false;
        final channel = _channel;
        _channel = null;
        if (channel != null) unawaited(channel.close());
      }
    });
  }
  final BleRequestCache _requestCache = BleRequestCache();
  final BleMessageClient client;
  final Duration requestTimeout, handlerTimeout;
  final int maxPendingRequests;
  int _generation = 0, _openingGeneration = -1;
  final String applicationProtocol;
  final int version;
  final Object? credentials;
  final BleRpcHandler? handler;
  String? resumeToken;
  String? sessionId;
  bool _ready = false, _disposed = false;
  bool get ready => _ready;
  late final StreamSubscription<BleConnectionState> _subscription;
  BleRpcChannel? _channel;
  Future<void>? _opening;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _errors = StreamController<Object>.broadcast();
  final _snapshots = StreamController<BleSharedSnapshot>.broadcast();
  final _diagnostics = StreamController<BleDiagnostic>.broadcast();
  BleSharedSnapshot? currentState;
  Stream<Object> get errors => _errors.stream;
  Stream<BleSharedSnapshot> get sharedState => _snapshots.stream;
  Stream<BleDiagnostic> get diagnostics => _diagnostics.stream;
  void _report(Object e) {
    if (!_disposed) _errors.add(e);
  }

  Future<void> open() {
    if (_opening != null && _openingGeneration == _generation) return _opening!;
    _openingGeneration = _generation;
    late Future<void> future;
    future = _open().whenComplete(() {
      if (identical(_opening, future)) _opening = null;
    });
    _opening = future;
    return future;
  }

  Future<void> _open() async {
    if (_disposed) throw StateError('Session client disposed');
    if (_ready) return;
    if (client.state != BleConnectionState.ready) {
      throw const BleException(
        BleErrorCode.disconnected,
        'Message connection not ready',
      );
    }
    final generation = _generation;
    await _channel?.close();
    if (_disposed || generation != _generation) {
      throw const BleException(
        BleErrorCode.disconnected,
        'Session interrupted',
      );
    }
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    if (_disposed || generation != _generation) {
      throw const BleException(
        BleErrorCode.disconnected,
        'Session interrupted',
      );
    }
    currentState = null;
    final channel = BleRpcChannel(
      incoming: client.receivedMessages,
      send: client.sendBytes,
      cache: _requestCache,
      maxMessageBytes: client.configuration.maxMessageBytes,
      timeout: requestTimeout,
      handlerTimeout: handlerTimeout,
      maxPending: maxPendingRequests,
      handler:
          handler ??
          (_, _) => throw const BleException(
            BleErrorCode.unsupported,
            'Client request not supported',
          ),
    );
    _channel = channel;
    _subscriptions.add(channel.errors.listen(_report));
    _subscriptions.add(
      channel.diagnostics.listen((e) {
        if (!_disposed) _diagnostics.add(e);
      }),
    );
    _subscriptions.add(
      channel.events.listen((e) {
        if (e.name == r'$state' && identical(_channel, channel)) {
          _acceptSnapshot(e.payload);
        }
      }),
    );
    try {
      final result = await channel.request(r'$hello', {
        'protocol': applicationProtocol,
        'version': version,
        'credentials': credentials,
        'resumeToken': resumeToken,
      });
      if (result is! Map ||
          result['sessionId'] is! String ||
          result['resumeToken'] is! String) {
        throw const FormatException('Invalid session response');
      }
      if (!identical(channel, _channel) || _disposed) {
        throw const BleException(
          BleErrorCode.disconnected,
          'Session interrupted',
        );
      }
      sessionId = result['sessionId'] as String;
      resumeToken = result['resumeToken'] as String;
      _ready = true;
      await refreshState();
    } catch (_) {
      if (identical(_channel, channel)) {
        _ready = false;
        _channel = null;
      }
      await channel.close();
      rethrow;
    }
  }

  void _acceptSnapshot(Object? raw) {
    if (_disposed) return;
    if (raw is! Map ||
        raw['revision'] is! int ||
        (raw['revision'] as int) < 0) {
      _report(const FormatException('Invalid state snapshot'));
      return;
    }
    final revision = raw['revision'] as int;
    if (currentState != null && revision <= currentState!.revision) return;
    currentState = BleSharedSnapshot(revision, raw['value']);
    _snapshots.add(currentState!);
  }

  Future<void> refreshState() async {
    _acceptSnapshot(await request(r'$snapshot', null));
  }

  Future<Object?> request(
    String method,
    Object? payload, {
    int retries = 0,
    String? requestId,
  }) {
    if (!_ready || _channel == null) {
      return Future.error(
        const BleException(BleErrorCode.disconnected, 'Session not ready'),
      );
    }
    return _channel!.request(
      method,
      payload,
      retries: retries,
      requestId: requestId,
    );
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

  Future<Object?> sendAcknowledged(
    Object? payload, {
    int retries = 0,
    String? requestId,
  }) => request(r'$message', payload, retries: retries, requestId: requestId);
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _ready = false;
    await _subscription.cancel();
    await _channel?.close();
    for (final s in _subscriptions) {
      await s.cancel();
    }
    unawaited(_errors.close());
    unawaited(_snapshots.close());
    unawaited(_diagnostics.close());
  }
}

import 'dart:async';
import '../communication.dart';
import '../models.dart';
import '../profile.dart';
import 'default_transport.dart';
import 'transport.dart';

/// One decoded update with its shared field definition.
class BleFieldUpdate {
  /// Associates a value with the definition used to decode it.
  const BleFieldUpdate(this.field, this.value);

  /// Definition identifying the source field and its codec.
  final BleFieldDefinition<dynamic> field;

  /// Decoded value; its type is determined by [field].
  final Object? value;
}

/// Optional fixed-delay reconnection; disabled by default.
class BleReconnectPolicy {
  /// Configures at most [attempts] attempts after an established link is lost.
  const BleReconnectPolicy({
    this.attempts = 0,
    this.delay = const Duration(seconds: 2),
  });

  /// Maximum attempts; zero disables reconnection.
  final int attempts;

  /// Delay before each retry. Manual disconnect cancels pending retries.
  final Duration delay;
}

/// One remote server, with serialized ATT operations and reference-counted watches.
class UniversalBleClient {
  /// Creates a client with an injectable transport, owned until disposal.
  /// Defaults to native Bluetooth, or Web Bluetooth in a supported browser.
  UniversalBleClient({
    BleClientTransport? transport,
    this.timeout = const Duration(seconds: 12),
    this.reconnect = const BleReconnectPolicy(),
  }) : transport = transport ?? createDefaultBleClientTransport() {
    if (timeout <= Duration.zero ||
        reconnect.attempts < 0 ||
        reconnect.delay < Duration.zero) {
      throw ArgumentError('Invalid timeout/reconnect policy');
    }
    _subscriptions.add(this.transport.disconnected.listen((_) => _lost()));
    _subscriptions.add(
      this.transport.adapterStates.listen((s) {
        if (s != BleAdapterState.poweredOn && _scanDone != null) {
          try {
            requireClientReady(s);
          } on BleException catch (error) {
            _transportError(error);
          }
        }
        if (s != BleAdapterState.poweredOn &&
            state != BleConnectionState.disconnected &&
            state != BleConnectionState.disposed) {
          _lost();
        }
      }),
    );
    _subscriptions.add(
      this.transport.notifications.listen(
        _notification,
        onError: _transportError,
      ),
    );
  }

  /// Native or application-supplied transport. Owned by this client.
  final BleClientTransport transport;

  /// Maximum wait for a queued operation once it starts.
  final Duration timeout;

  /// Policy used after unexpected loss of an established connection.
  final BleReconnectPolicy reconnect;
  final _states = StreamController<BleConnectionState>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _diagnostics = StreamController<BleDiagnostic>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _watches = <String, _Watch>{};
  final _fields = <String, BleRemoteCharacteristic>{};
  Future<void> _queue = Future.value();

  /// Current connection status. Treat as read-only; use lifecycle methods.
  BleConnectionState state = BleConnectionState.disconnected;

  /// Negotiated maximum raw write payload. Treat as read-only.
  int maxWriteBytes = 20;
  int _generation = 0;
  int _pending = 0;
  String? _id;
  Timer? _retry;
  Timer? _scanTimer;
  Future<void> _scanOperations = Future.value();
  Completer<void>? _scanDone;
  int _scanGeneration = 0;
  bool _discovering = false;
  Object? _scanError;
  Future<void>? _disposeFuture;
  int _attempt = 0;
  bool _manual = false;
  bool _disposed = false;
  bool _connecting = false;

  /// Lifecycle transitions; subscribe before connecting.
  Stream<BleConnectionState> get stateChanges => _states.stream;

  /// Asynchronous errors; also handle errors from returned operation futures.
  Stream<Object> get errors => _errors.stream;

  /// Operation and queue counters without application payloads.
  Stream<BleDiagnostic> get diagnostics => _diagnostics.stream;

  /// Live native advertisements, or devices selected by the web chooser.
  /// Native advertisements may repeat for one device.
  Stream<BleDiscoveredServer> get discoveredServers => transport.discovered;

  /// Immutable snapshot of the connected server's discovered characteristics.
  List<BleRemoteCharacteristic> get characteristics =>
      List.unmodifiable(_fields.values);

  /// Checks adapter support, permission and power state.
  Future<BleAdapterState> checkSupport() => transport.checkSupport();

  /// Requests client-role Bluetooth permissions through the native backend.
  /// On web this only checks availability; [selectDevice] grants device access.
  Future<BleAdapterState> requestPermissions() =>
      transport.requestPermissions();

  /// Opens the browser's device chooser. Call directly from a button callback,
  /// before awaiting anything else. Returns null if no device is selected.
  ///
  /// [serviceUuids] filters devices by advertised services; list additional
  /// services to access in [optionalServiceUuids]. Selection grants access but
  /// does not connect. Native transports use [discover] and app-owned selection
  /// instead, and report unsupported here. Existing custom transports can opt in
  /// by implementing [BleDeviceSelector]. No background scan is performed.
  Future<BleDiscoveredServer?> selectDevice({
    List<String> serviceUuids = const [],
    List<String> optionalServiceUuids = const [],
  }) {
    if (_disposed) return Future.error(StateError('Client disposed'));
    if (_connecting ||
        state != BleConnectionState.disconnected ||
        _discovering ||
        _scanDone != null) {
      return Future.error(
        const BleException(
          BleErrorCode.busy,
          'Stop discovery and disconnect before selecting a device',
        ),
      );
    }
    final selector = transport;
    if (selector is! BleDeviceSelector) {
      return Future.error(
        const BleException(
          BleErrorCode.unsupported,
          'This transport uses discover() and application-owned device selection',
        ),
      );
    }
    // Do not queue/await this call: requestDevice requires transient activation.
    return (selector as BleDeviceSelector).selectDevice(
      serviceUuids: serviceUuids,
      optionalServiceUuids: optionalServiceUuids,
    );
  }

  void _set(BleConnectionState s) {
    state = s;
    if (!_states.isClosed) _states.add(s);
  }

  void _report(Object e) {
    if (!_errors.isClosed) _errors.add(e);
  }

  Future<T> _run<T>(
    String operation,
    Future<T> Function() action, {
    bool requireReady = true,
  }) {
    if (_disposed) return Future.error(StateError('Client disposed'));
    final generation = _generation;
    if (_pending >= 128) {
      return Future.error(
        const BleException(BleErrorCode.busy, 'Client queue is full'),
      );
    }
    _pending++;
    final result = _queue.then((_) async {
      if (generation != _generation ||
          _disposed ||
          (requireReady && state != BleConnectionState.ready)) {
        throw const BleException(
          BleErrorCode.disconnected,
          'Connection changed',
        );
      }
      try {
        final value = await action().timeout(timeout);
        if (generation != _generation) {
          throw const BleException(
            BleErrorCode.disconnected,
            'Connection changed',
          );
        }
        return value;
      } on TimeoutException catch (e) {
        _generation++;
        _connecting = false;
        _set(BleConnectionState.disconnected);
        try {
          await transport.disconnect().timeout(timeout);
        } catch (_) {
          /* Original timeout is retained. */
        }
        throw BleException(
          BleErrorCode.timeout,
          '$operation timed out; connection closed',
          e,
        );
      }
    });
    _queue = result
        .then<void>(
          (_) {},
          onError: (Object e, StackTrace _) {
            _report(e);
          },
        )
        .whenComplete(() {
          _pending--;
          if (!_diagnostics.isClosed) {
            _diagnostics.add(BleDiagnostic(operation, pending: _pending));
          }
        });
    return result;
  }

  void _transportError(Object error) {
    _report(error);
    if (_scanDone != null) {
      _scanError = error;
      unawaited(stopScan().catchError(_report));
    }
  }

  Future<void> _enqueueScan(Future<void> Function() operation) {
    final result = _scanOperations.then((_) => operation());
    _scanOperations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  /// Scans for [duration], publishing results through [discoveredServers].
  /// A new scan replaces the previous scan. Use [discover] for a bounded list.
  Future<void> startScan({
    List<String> serviceUuids = const [],
    Duration duration = const Duration(seconds: 10),
  }) {
    if (_disposed) return Future.error(StateError('Client disposed'));
    if (duration <= Duration.zero) {
      return Future.error(ArgumentError('Scan duration must be positive'));
    }
    final services = serviceUuids.map(normalizeBleUuid).toList();
    final generation = ++_scanGeneration;
    _scanTimer?.cancel();
    _scanDone?.complete();
    final done = Completer<void>();
    _scanDone = done;
    _scanError = null;
    return _enqueueScan(() async {
      void checkCurrent() {
        if (_disposed || generation != _scanGeneration) {
          throw const BleException(BleErrorCode.disconnected, 'Scan cancelled');
        }
      }

      try {
        checkCurrent();
        await transport.stopScan().timeout(timeout);
        checkCurrent();
        requireClientReady(await checkSupport().timeout(timeout));
        checkCurrent();
        await transport.startScan(services).timeout(timeout);
        checkCurrent();
        _scanTimer = Timer(duration, () {
          unawaited(stopScan().catchError(_report));
        });
      } catch (error) {
        // Even a timed-out start can have acquired a native scan resource.
        try {
          await transport.stopScan().timeout(timeout);
        } catch (_) {
          /* Keep the startup error. */
        }
        if (identical(_scanDone, done)) _scanDone = null;
        if (!done.isCompleted) done.complete();
        rethrow;
      }
    });
  }

  /// Stops discovery and completes any pending [discover] with collected results.
  Future<void> stopScan() {
    ++_scanGeneration;
    _scanTimer?.cancel();
    _scanTimer = null;
    final done = _scanDone;
    _scanDone = null;
    return _enqueueScan(() async {
      try {
        await transport.stopScan().timeout(timeout);
      } catch (error) {
        _scanError = error;
        rethrow;
      } finally {
        if (done != null && !done.isCompleted) done.complete();
      }
    });
  }

  /// Returns the latest result per device after a bounded scan, then stops it.
  ///
  /// Requests permission by default. Set [requestPermissions] to false when the
  /// application manages consent. At most [maxResults] devices are retained;
  /// additional IDs are ignored. Explicit [stopScan] returns results early.
  /// Disposal cancels this operation with [BleErrorCode.disconnected].
  Future<List<BleDiscoveredServer>> discover({
    List<String> serviceUuids = const [],
    Duration duration = const Duration(seconds: 3),
    bool requestPermissions = true,
    int maxResults = 256,
  }) async {
    if (_disposed) throw StateError('Client disposed');
    if (_discovering) {
      throw const BleException(
        BleErrorCode.busy,
        'Discovery is already pending',
      );
    }
    if (duration <= Duration.zero || maxResults < 1 || maxResults > 1024) {
      throw ArgumentError('Invalid discovery limits');
    }
    final services = serviceUuids.map(normalizeBleUuid).toList();
    _discovering = true;
    final found = <String, BleDiscoveredServer>{};
    StreamSubscription<BleDiscoveredServer>? subscription;
    try {
      if (requestPermissions) {
        requireClientReady(await this.requestPermissions().timeout(timeout));
      }
      if (_disposed) {
        throw const BleException(BleErrorCode.disconnected, 'Client disposed');
      }
      subscription = discoveredServers.listen((device) {
        if (found.containsKey(device.id) || found.length < maxResults) {
          found[device.id] = device;
        }
      });
      final starting = startScan(serviceUuids: services, duration: duration);
      final done = _scanDone;
      await starting;
      await done?.future;
      if (_disposed) {
        throw const BleException(BleErrorCode.disconnected, 'Client disposed');
      }
      if (_scanError != null) {
        Error.throwWithStackTrace(_scanError!, StackTrace.current);
      }
      return List.unmodifiable(found.values);
    } finally {
      await subscription?.cancel();
      _discovering = false;
    }
  }

  /// Connects to a discovered device, discovers fields and restores watches.
  /// Rejects concurrent connection attempts; disconnect before changing servers.
  Future<void> connect(String id) {
    if (state != BleConnectionState.disconnected || _connecting) {
      return Future.error(
        const BleException(
          BleErrorCode.busy,
          'Disconnect before connecting again',
        ),
      );
    }
    _manual = false;
    _retry?.cancel();
    _id = id;
    _connecting = true;
    final generation = _generation;
    return _connect(id).whenComplete(() {
      if (generation == _generation) _connecting = false;
    });
  }

  void _checkGeneration(int generation) {
    if (_disposed || generation != _generation) {
      throw const BleException(BleErrorCode.disconnected, 'Connection changed');
    }
  }

  Future<void> _connect(String id) {
    final generation = _generation;
    return _run('connect', () async {
      _connecting = true;
      try {
        await stopScan();
        _checkGeneration(generation);
        final support = await checkSupport();
        _checkGeneration(generation);
        requireClientReady(support);
        _set(BleConnectionState.connecting);
        await transport.connect(id);
        _checkGeneration(generation);
        _set(BleConnectionState.discovering);
        final fields = await transport.discover();
        _checkGeneration(generation);
        _fields.clear();
        for (final field in fields) {
          if (_fields.containsKey(field.key)) {
            throw const BleException(
              BleErrorCode.incompatibleProtocol,
              'Ambiguous characteristic',
            );
          }
          _fields[field.key] = field;
        }
        final maximum = await transport.maximumWriteBytes();
        _checkGeneration(generation);
        maxWriteBytes = maximum.clamp(1, 512);
        _set(BleConnectionState.subscribing);
        for (final watch in _watches.values.toList()) {
          if (!identical(_watches[watch.field.key], watch)) continue;
          _validate(watch.field, BleProperty.notify);
          await transport.subscribe(watch.field.key, true);
          _checkGeneration(generation);
        }
        _attempt = 0;
        _set(BleConnectionState.ready);
      } catch (_) {
        if (generation == _generation && !_disposed) {
          try {
            await transport.disconnect().timeout(timeout);
          } finally {
            if (!_disposed) _set(BleConnectionState.disconnected);
          }
        }
        rethrow;
      } finally {
        if (generation == _generation) _connecting = false;
      }
    }, requireReady: false);
  }

  void _lost() {
    if (_disposed ||
        _manual ||
        state == BleConnectionState.disconnected ||
        state == BleConnectionState.reconnecting) {
      return;
    }
    final wasConnecting = _connecting;
    _generation++;
    _connecting = false;
    _fields.clear();
    _set(BleConnectionState.disconnected);
    if (!wasConnecting) _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_disposed || _manual || _id == null || _attempt >= reconnect.attempts) {
      return;
    }
    _set(BleConnectionState.reconnecting);
    _retry = Timer(reconnect.delay, () async {
      _attempt++;
      try {
        await transport.disconnect().timeout(timeout);
        if (_manual || _disposed) return;
        await _connect(_id!);
      } catch (e) {
        _report(e);
        _scheduleRetry();
      }
    });
  }

  void _validate(BleFieldDefinition<dynamic> field, BleProperty property) {
    if (!field.access.contains(property) ||
        _fields[field.key]?.access.contains(property) != true) {
      throw BleException(
        BleErrorCode.incompatibleProtocol,
        'Missing ${property.name} access for ${field.key}',
      );
    }
  }

  /// Reads and decodes a field using its shared definition.
  Future<T> readValue<T>(BleFieldDefinition<T> field) => _run('read', () async {
    _validate(field, BleProperty.read);
    return field.codec.decode(await transport.read(field.key));
  });

  /// Encodes and writes a field with a response. Oversized raw values fail.
  Future<void> writeValue<T>(BleFieldDefinition<T> field, T value) {
    final bytes = bleBytes(field.codec.encode(value));
    return _run('write', () async {
      _validate(field, BleProperty.write);
      if (bytes.length > maxWriteBytes) {
        throw const BleException(
          BleErrorCode.tooLarge,
          'Use message framing for values exceeding the write limit',
        );
      }
      await transport.write(field.key, bytes);
    });
  }

  void _notification(BleRawNotification event) {
    final watch = _watches[event.key];
    if (watch == null) return;
    try {
      watch.controller.add(watch.field.codec.decode(event.bytes));
    } catch (e, st) {
      watch.controller.addError(e, st);
    }
  }

  /// Establishes the native subscription before returning. Repeated watchers
  /// share one subscription. Cancellation removes it when the last watcher ends.
  Future<Stream<T>> watchValue<T>(BleFieldDefinition<T> field) async {
    late StreamController<T> output;
    StreamSubscription<dynamic>? subscription;
    _Watch? watch;
    var released = false;
    Future<void> release() async {
      if (released) return;
      released = true;
      await subscription?.cancel();
      final current = watch;
      if (current == null) return;
      if (--current.references == 0 &&
          identical(_watches[field.key], current)) {
        _watches.remove(field.key);
        if (state == BleConnectionState.ready && !_disposed) {
          try {
            await _run('unsubscribe', () async {
              if (!_watches.containsKey(field.key)) {
                await transport.subscribe(field.key, false);
              }
            });
          } catch (e) {
            _report(e);
          }
        }
        unawaited(current.controller.close());
      }
    }

    output = StreamController<T>(onCancel: release);
    try {
      await _run('subscribe', () async {
        _validate(field, BleProperty.notify);
        final existing = _watches[field.key];
        if (existing != null && !identical(existing.field.codec, field.codec)) {
          throw ArgumentError('Conflicting codecs for one field');
        }
        watch = existing ?? _Watch(field);
        if (existing != null) existing.references++;
        _watches[field.key] = watch!;
        subscription = watch!.controller.stream.listen(
          (v) => output.add(v as T),
          onError: output.addError,
          onDone: output.close,
        );
        if (existing == null) await transport.subscribe(field.key, true);
      });
      return output.stream;
    } catch (_) {
      await release();
      unawaited(output.close());
      rethrow;
    }
  }

  /// Observes multiple fields through one stream carrying field identity.
  /// Cancel the subscription to release every underlying watch.
  Stream<BleFieldUpdate> watchValues(List<BleFieldDefinition<dynamic>> fields) {
    // Snapshot caller-owned definitions before asynchronous subscription setup.
    final definitions = List<BleFieldDefinition<dynamic>>.of(fields);
    late StreamController<BleFieldUpdate> output;
    final subscriptions = <StreamSubscription<dynamic>>[];
    var cancelled = false, setupDone = false;
    var active = 0;
    void finishIfDone() {
      if (setupDone && active == 0) unawaited(output.close());
    }

    output = StreamController<BleFieldUpdate>(
      onListen: () async {
        try {
          for (final field in definitions) {
            if (cancelled) break;
            final stream = await watchValue(field);
            active++;
            final subscription = stream.listen(
              (value) {
                if (!cancelled) output.add(BleFieldUpdate(field, value));
              },
              onError: output.addError,
              onDone: () {
                active--;
                finishIfDone();
              },
            );
            if (cancelled) {
              await subscription.cancel();
              break;
            }
            subscriptions.add(subscription);
          }
        } catch (error, stack) {
          if (!cancelled) output.addError(error, stack);
          for (final subscription in subscriptions) {
            await subscription.cancel();
          }
          active = 0;
        } finally {
          setupDone = true;
          finishIfDone();
        }
      },
      onCancel: () async {
        cancelled = true;
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        unawaited(output.close());
      },
    );
    return output.stream;
  }

  /// Disconnects intentionally, invalidating queued work and cancelling retries.
  Future<void> disconnect() async {
    _manual = true;
    _connecting = false;
    _generation++;
    _retry?.cancel();
    try {
      await transport.disconnect().timeout(timeout);
    } finally {
      _fields.clear();
      if (!_disposed) _set(BleConnectionState.disconnected);
    }
  }

  /// Permanently releases this client. Concurrent calls share one cleanup future.
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    if (_disposed) return;
    _disposed = true;
    _manual = true;
    _connecting = false;
    _generation++;
    _retry?.cancel();
    _scanTimer?.cancel();
    try {
      try {
        if (_scanDone != null) await stopScan();
        await _scanOperations;
      } finally {
        await transport.dispose();
      }
    } finally {
      for (final s in _subscriptions) {
        await s.cancel();
      }
      for (final w in _watches.values) {
        w.dispose();
      }
      _watches.clear();
      _set(BleConnectionState.disposed);
      unawaited(_states.close());
      unawaited(_errors.close());
      unawaited(_diagnostics.close());
    }
  }
}

class _Watch {
  _Watch(this.field);

  /// Definition identifying the source field and its codec.
  final BleFieldDefinition<dynamic> field;
  final controller = StreamController<dynamic>.broadcast();
  int references = 1;
  void dispose() => unawaited(controller.close());
}

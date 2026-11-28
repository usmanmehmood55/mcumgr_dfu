import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'smp_transport.dart';

/// Minimal, bounded SMP/CBOR client. One transaction per connection; fragmented
/// notifications are reassembled before matching operation/group/sequence/id.
class McuMgrClient {
  McuMgrClient(this.transport);
  final SmpTransport transport;
  StreamSubscription<Uint8List>? _notifications;
  StreamSubscription<SmpConnection>? _connection;
  final List<int> _buffer = [];
  Completer<Map<String, Object?>>? _pending;
  int _generation = -1, _sequence = 0, _expectedSequence = -1, _group = -1, _command = -1, _operation = -1;
  bool _busy = false, _retired = true;
  int get connectionRevision {
    _check();
    return _generation;
  }

  Future<void> open() async {
    if (!_retired || _notifications != null) throw StateError('SMP client must be closed before opening');
    _generation = transport.connection.generation;
    _retired = false;
    _notifications = transport.notifications.listen(_receive, onError: (Object error) => _fail(error));
    _connection = transport.connectionUpdates.listen((connection) {
      if (!connection.isConnected || connection.generation != _generation) {
        _retired = true;
        _buffer.clear();
        _fail(StateError('Device disconnected during firmware operation'));
      }
    });
    try {
      await transport.open();
      _check();
    } catch (_) {
      await close();
      rethrow;
    }
  }

  void _check() {
    if (_retired) throw StateError('Firmware transport is closed; reconnect before retrying');
    final s = transport.connection;
    if (!s.isConnected || s.generation != _generation) throw StateError('Firmware connection changed');
  }

  void _fail(Object error) {
    final p = _pending;
    if (p != null && !p.isCompleted) p.completeError(error);
  }

  void _receive(Uint8List value) {
    final connection = transport.connection;
    if (_retired || !connection.isConnected || connection.generation != _generation) return;
    _buffer.addAll(value);
    if (_buffer.length > 65543) {
      _buffer.clear();
      _fail(const FormatException('SMP response exceeds limit'));
      return;
    }
    while (_buffer.length >= 8) {
      final length = (_buffer[2] << 8) | _buffer[3];
      if (_buffer.length < 8 + length) return;
      final frame = Uint8List.fromList(_buffer.sublist(0, 8 + length));
      _buffer.removeRange(0, 8 + length);
      if (frame[6] != _expectedSequence ||
          ((frame[4] << 8) | frame[5]) != _group ||
          frame[7] != _command ||
          (frame[0] & 7) != _operation + 1) {
        continue;
      }
      try {
        final decoded = SmpCbor.decode(frame.sublist(8));
        if (decoded is! Map) throw const FormatException('SMP response is not a map');
        final response = _stringMap(decoded, 'SMP response');
        final rc = response['rc'];
        final err = response['err'];
        if (rc is num && rc != 0 || err is Map && err['rc'] != 0) {
          throw SmpCommandError(err is Map ? err['rc'] : rc, err is Map ? err['group'] : null);
        }
        final p = _pending;
        if (p != null && !p.isCompleted) p.complete(response);
      } catch (e) {
        _fail(e);
      }
    }
  }

  Future<Map<String, Object?>> request(
    int operation,
    int group,
    int command,
    Map<String, Object?> payload, {
    bool expectDisconnect = false,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (_busy) throw StateError('A firmware command is already in progress');
    _check();
    _busy = true;
    final body = SmpCbor.encode(payload);
    final sequence = _sequence++ & 255;
    _expectedSequence = sequence;
    _group = group;
    _command = command;
    _operation = operation;
    final bytes = Uint8List.fromList([
      operation,
      0,
      body.length >> 8,
      body.length & 255,
      group >> 8,
      group & 255,
      sequence,
      command,
      ...body,
    ]);
    final pending = Completer<Map<String, Object?>>();
    _pending = pending;
    // Install an error listener immediately; disconnect can happen during writes.
    final clock = Stopwatch()..start();
    final response = pending.future.timeout(timeout);
    unawaited(response.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    var writing = true;
    try {
      final chunk = transport.maximumWriteSize;
      if (chunk <= 0) throw StateError('Invalid SMP transport write size');
      for (var at = 0; at < bytes.length; at += chunk) {
        _check();
        final remaining = timeout - clock.elapsed;
        if (remaining <= Duration.zero) throw TimeoutException('Firmware command timed out');
        await transport.write(Uint8List.sublistView(bytes, at, (at + chunk).clamp(0, bytes.length))).timeout(remaining);
      }
      writing = false;
      final result = await response;
      if (!expectDisconnect) _check();
      return result;
    } catch (error) {
      // Only a request that was fully written can explain the disconnect.
      if (expectDisconnect && !writing && !transport.connection.isConnected) return {};
      if (!writing && error is! TimeoutException) rethrow;
      // A timeout cannot cancel a native write or a partially received SMP frame.
      _retired = true;
      _buffer.clear();
      if (transport.connection.isConnected && transport.connection.generation == _generation) {
        try {
          await transport.disconnect();
        } catch (_) {
          // Preserve the original failure. The client remains retired.
        }
      }
      rethrow;
    } finally {
      _busy = false;
      _pending = null;
    }
  }

  Future<List<Map<String, Object?>>> images() async {
    final response = await request(0, 1, 0, {});
    final images = response['images'];
    if (images is! List) throw const FormatException('Missing MCUboot image state');
    return images.map((v) => _stringMap(v, 'MCUboot image state')).toList();
  }

  /// Uploads a signed MCUboot image to slot 1, one SMP request at a time.
  ///
  /// By default each request fits in one transport write. Set
  /// [allowFragmentation] only for targets known to support SMP receive
  /// reassembly; requests then follow the device's reported buffer size,
  /// split across at most 24 writes. A link whose write size cannot fit the
  /// first upload packet always requires reassembly.
  ///
  /// Each request waits up to [requestTimeout] for its acknowledgement. A
  /// request at offset 0 starts a new upload, and the device may erase the
  /// whole secondary slot before answering, so it gets [firstRequestTimeout].
  Future<void> upload(
    Uint8List image, {
    required void Function(double) onProgress,
    required bool Function() cancelled,
    bool allowFragmentation = false,
    Duration requestTimeout = const Duration(seconds: 15),
    Duration firstRequestTimeout = const Duration(seconds: 60),
  }) async {
    if (image.isEmpty) throw ArgumentError('Firmware image is empty');
    void checkCancelled() {
      if (cancelled()) throw StateError('Firmware upload cancelled; the candidate remains unconfirmed');
    }

    checkCancelled();
    final writeSize = transport.maximumWriteSize;
    final minimumPacket = 8 + SmpCbor.encode({'off': 0, 'len': image.length, 'data': Uint8List(32)}).length;
    final parameters = allowFragmentation || writeSize < minimumPacket ? await _uploadParameters() : null;
    // A peer's buffer size describes what it can hold. Bound how many
    // sequential writes one request needs on a link with a small write size.
    const maxUploadFragments = 24;
    final packetSize = parameters == null ? writeSize : parameters.clamp(0, writeSize * maxUploadFragments);
    final digest = Uint8List.fromList(sha256.convert(image).bytes);
    const headerSize = 32;
    final includeDigest =
        image.length >= headerSize &&
        8 +
                SmpCbor.encode({
                  'image': 0,
                  'off': 0,
                  'len': image.length,
                  'sha': digest,
                  'data': Uint8List.sublistView(image, 0, headerSize),
                }).length <=
            packetSize;
    var offset = 0;
    var highWater = 0;
    var rewinds = 0;
    var recoveries = 0;

    while (offset < image.length) {
      checkCancelled();

      Map<String, Object?> payload(int size) => {
        if (offset == 0 && includeDigest) 'image': 0,
        'off': offset,
        if (offset == 0) 'len': image.length,
        if (offset == 0 && includeDigest) 'sha': digest,
        'data': Uint8List.sublistView(image, offset, offset + size),
      };

      var low = 0;
      var high = (image.length - offset).clamp(0, packetSize);
      while (low < high) {
        final mid = (low + high + 1) ~/ 2;
        if (8 + SmpCbor.encode(payload(mid)).length <= packetSize) {
          low = mid;
        } else {
          high = mid - 1;
        }
      }
      if (low == 0 || (offset == 0 && low < headerSize && low < image.length)) {
        throw UnsupportedError('The target needs SMP reassembly at this transport write size');
      }

      // Keep intermediate chunks aligned like the native reference.
      final size = offset + low < image.length && low >= 8 ? low - low % 8 : low;
      final response = await request(2, 1, 1, payload(size), timeout: offset == 0 ? firstRequestTimeout : requestTimeout);
      final next = response['off'];
      if (next is! int || next < 0 || next > image.length || ((offset != 0 || !includeDigest) && next > offset + size)) {
        throw StateError('Invalid firmware upload acknowledgement');
      }
      if (response['match'] == false) throw StateError('Device reported a firmware upload hash mismatch');
      if (next < offset && ++rewinds > 3) throw StateError('Firmware upload repeatedly rewound');
      if (next == offset) {
        if (++recoveries > 3) throw StateError('Firmware upload stalled at offset $next');
      } else {
        recoveries = 0;
      }
      offset = next;
      if (offset > highWater) {
        highWater = offset;
        onProgress(offset / image.length);
      }
    }
  }

  Future<int?> _uploadParameters() async {
    try {
      final response = await request(0, 0, 6, {});
      final size = response['buf_size'];
      return size is int && size >= 8 && size <= 65543 ? size : null;
    } on SmpCommandError catch (error) {
      // Legacy SMP peers omit the parameters command.
      if (error.code == 8 && error.group == null) return null;
      rethrow;
    }
  }

  Future<void> test(Uint8List hash) async {
    await request(2, 1, 0, {'hash': hash, 'confirm': false});
  }

  Future<void> confirm(Uint8List hash) async {
    await request(2, 1, 0, {'hash': hash, 'confirm': true});
  }

  Future<void> reset({Duration timeout = const Duration(seconds: 15)}) async {
    await request(2, 0, 5, {}, expectDisconnect: true, timeout: timeout);
  }

  /// Stops listening and releases SMP resources on the current connection.
  ///
  /// A request in flight fails. If it is still writing, the client also calls
  /// [SmpTransport.disconnect], because a partly written SMP frame cannot be
  /// cancelled and would corrupt the next request on that link.
  Future<void> close() async {
    _retired = true;
    _fail(StateError('Firmware transport closed'));
    await _notifications?.cancel();
    await _connection?.cancel();
    _notifications = null;
    _connection = null;
    _buffer.clear();
    if (transport.connection.isConnected && transport.connection.generation == _generation) {
      await transport.close();
    }
  }
}

Map<String, Object?> _stringMap(Object? value, String what) {
  if (value is! Map || value.keys.any((key) => key is! String)) throw FormatException('$what is not a map with text keys');
  return Map<String, Object?>.from(value);
}

/// A device's non-zero SMP result for a well-formed request.
///
/// [code] is the SMP v1 `rc` or the SMP v2 `err.rc` value. [group] is the
/// SMP v2 `err.group`, or null for SMP v1 errors. The link stays usable.
class SmpCommandError implements Exception {
  SmpCommandError(this.code, this.group);

  final Object? code;
  final Object? group;

  @override
  String toString() => 'SmpCommandError: Device rejected firmware command (group $group, code $code)';
}

/// The CBOR subset used by MCUmgr, including Zephyr indefinite maps/lists.
/// Reject excessive nesting, trailing bytes and malformed lengths.
class SmpCbor {
  static Uint8List encode(Object? value) {
    final out = <int>[];
    void head(int major, int n) {
      if (n < 24) {
        out.add((major << 5) | n);
      } else if (n <= 255) {
        out.addAll([(major << 5) | 24, n]);
      } else if (n <= 65535) {
        out.addAll([(major << 5) | 25, n >> 8, n & 255]);
      } else if (n <= 0xFFFFFFFF) {
        out.addAll([(major << 5) | 26, (n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255]);
      } else {
        // Split before shifting: on the web, shifts truncate to 32 bits.
        final high = n ~/ 0x100000000, low = n % 0x100000000;
        out.addAll([(major << 5) | 27]);
        for (final word in [high, low]) {
          out.addAll([(word >> 24) & 255, (word >> 16) & 255, (word >> 8) & 255, word & 255]);
        }
      }
    }

    void put(Object? v) {
      if (v == null) {
        out.add(0xf6);
      } else if (v is bool) {
        out.add(v ? 0xf5 : 0xf4);
      } else if (v is int) {
        head(v < 0 ? 1 : 0, v < 0 ? -1 - v : v);
      } else if (v is Uint8List) {
        head(2, v.length);
        out.addAll(v);
      } else if (v is String) {
        final b = utf8.encode(v);
        head(3, b.length);
        out.addAll(b);
      } else if (v is List) {
        head(4, v.length);
        for (final item in v) {
          put(item);
        }
      } else if (v is Map) {
        head(5, v.length);
        for (final e in v.entries) {
          put(e.key);
          put(e.value);
        }
      } else {
        throw ArgumentError('Unsupported SMP CBOR value');
      }
    }

    put(value);
    return Uint8List.fromList(out);
  }

  static Object? decode(Uint8List bytes) {
    var offset = 0;
    int byte() {
      if (offset >= bytes.length) throw const FormatException('Truncated CBOR');
      return bytes[offset++];
    }

    Object? get(int depth) {
      if (depth > 16) throw const FormatException('CBOR nesting limit');
      final first = byte(), major = first >> 5, additional = first & 31;
      if (major == 7) {
        if (additional == 20) return false;
        if (additional == 21) return true;
        if (additional == 22) return null;
        throw const FormatException('Unsupported CBOR simple value');
      }
      if (additional == 31 && (major == 4 || major == 5)) {
        final list = <Object?>[];
        final map = <Object?, Object?>{};
        var count = 0;
        while (true) {
          if (offset >= bytes.length) throw const FormatException('Unterminated CBOR container');
          if (bytes[offset] == 0xff) {
            offset++;
            return major == 4 ? list : map;
          }
          if (++count > 65536) throw const FormatException('CBOR length limit');
          final item = get(depth + 1);
          if (major == 4) {
            list.add(item);
          } else {
            if (map.containsKey(item)) throw const FormatException('Duplicate CBOR key');
            // A break here is an incomplete pair, not the end of the map.
            map[item] = get(depth + 1);
          }
        }
      }
      int length;
      if (additional < 24) {
        length = additional;
      } else if (additional >= 24 && additional <= 27) {
        final count = 1 << (additional - 24);
        length = 0;
        for (var i = 0; i < count; i++) {
          length = length * 256 + byte();
        }
      } else {
        throw const FormatException('Unsupported CBOR length encoding');
      }
      if (length < 0 || (major >= 2 && length > 65536)) throw const FormatException('CBOR length limit');
      if (major == 0) return length;
      if (major == 1) return -1 - length;
      if (major == 2 || major == 3) {
        if (offset + length > bytes.length) throw const FormatException('Truncated CBOR bytes');
        final b = bytes.sublist(offset, offset + length);
        offset += length;
        return major == 2 ? b : utf8.decode(b);
      }
      if (major == 4) return List.generate(length, (_) => get(depth + 1));
      if (major == 5) {
        final map = <Object?, Object?>{};
        for (var i = 0; i < length; i++) {
          final key = get(depth + 1);
          if (map.containsKey(key)) throw const FormatException('Duplicate CBOR key');
          map[key] = get(depth + 1);
        }
        return map;
      }
      throw const FormatException('Unsupported CBOR major type');
    }

    final result = get(0);
    if (offset != bytes.length) throw const FormatException('Trailing CBOR');
    return result;
  }
}

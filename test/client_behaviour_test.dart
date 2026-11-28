import 'dart:async';
import 'dart:typed_data';

import 'package:mcumgr_dfu/mcumgr_dfu.dart';
import 'package:test/test.dart';

void main() {
  group('reset', () {
    test('fails when the link drops before the command is fully written', () async {
      final device = _Device(writeSize: 4, onFragment: (device, index) => index == 1 ? device.drop() : null);
      final client = await device.client();
      await expectLater(client.reset(), _fails(McuMgrErrorKind.disconnected));
      expect(device.writes, 1);
    });

    test('succeeds when the device drops the link after a complete command', () async {
      final device = _Device(writeSize: 4)
        ..handler = (device, frame) {
          expect([frame.group, frame.command], [0, 5]);
          device.drop();
          return null;
        };
      final client = await device.client();
      await client.reset();
      expect(device.writes, 3);
    });
  });

  group('image state', () {
    final hash = Uint8List.fromList(List.generate(32, (i) => i));
    Map<String, Object?> image({bool pending = false, bool confirmed = false}) => {
      'slot': 1,
      'hash': hash,
      'pending': pending,
      'confirmed': confirmed,
    };

    test('test() succeeds when the device reports the candidate pending', () async {
      final device =
          _Device()
            ..handler =
                (device, frame) => {
                  'images': [image(pending: true)],
                };
      final client = await device.client();
      await client.test(hash);
    });

    test('test() fails when the device does not mark the candidate pending', () async {
      final device =
          _Device()
            ..handler =
                (device, frame) => {
                  'images': [image()],
                };
      final client = await device.client();
      await expectLater(client.test(hash), _fails(McuMgrErrorKind.testNotApplied));
    });

    test('test() reads the image list back when the reply leaves it out', () async {
      final device =
          _Device()
            ..handler =
                (device, frame) =>
                    (frame.bytes[0] & 0x07) == 2
                        ? <Object?, Object?>{}
                        : {
                          'images': [image(pending: true)],
                        };
      final client = await device.client();
      await client.test(hash);
      expect(device.writes, greaterThanOrEqualTo(2), reason: 'the write, then a read of the image list');
    });

    test('confirm() fails when the device does not report the image confirmed', () async {
      final device =
          _Device()
            ..handler =
                (device, frame) => {
                  'images': [image(pending: true)],
                };
      final client = await device.client();
      await expectLater(client.confirm(hash), _fails(McuMgrErrorKind.confirmNotApplied));
    });

    test('confirm() succeeds when the device reports the image confirmed', () async {
      final device =
          _Device()
            ..handler =
                (device, frame) => {
                  'images': [image(confirmed: true)],
                };
      final client = await device.client();
      await client.confirm(hash);
    });
  });

  group('connection loss', () {
    test('a disconnect during a request retires the client', () async {
      final device =
          _Device()
            ..handler = (device, frame) {
              device.drop();
              return null;
            };
      final client = await device.client();
      await expectLater(client.images(), _fails(McuMgrErrorKind.disconnected));
      final writes = device.writes;
      await expectLater(client.images(), _fails(McuMgrErrorKind.transportClosed));
      expect(device.writes, writes);
    });

    test('a timeout retires the client and disconnects the link', () async {
      final device = _Device()..handler = (device, frame) => null;
      final client = await device.client();
      await expectLater(
        client.request(0, 1, 0, {}, timeout: const Duration(milliseconds: 50)),
        _fails(McuMgrErrorKind.responseTimeout),
      );
      expect(device.disconnects, 1);
      await expectLater(client.images(), _fails(McuMgrErrorKind.transportClosed));
    });

    test('close during a write disconnects the link', () async {
      final gate = Completer<void>();
      final device = _Device(writeSize: 4, onFragment: (device, index) => index == 1 ? gate.future : null);
      final client = await device.client();
      final pending = expectLater(client.images(), _fails(McuMgrErrorKind.transportClosed));
      await Future<void>.delayed(Duration.zero);
      await client.close();
      gate.complete();
      await pending;
      expect(device.disconnects, 1);
    });
  });

  group('device errors', () {
    test('SMP v1 rc is reported as SmpCommandError and keeps the link usable', () async {
      var calls = 0;
      final device =
          _Device()
            ..handler =
                (device, frame) =>
                    ++calls == 1
                        ? {'rc': 3}
                        : {
                          'images': [
                            {'slot': 0},
                          ],
                        };
      final client = await device.client();
      await expectLater(
        client.images(),
        throwsA(isA<SmpCommandError>().having((e) => e.code, 'code', 3).having((e) => e.group, 'group', null)),
      );
      expect(await client.images(), [
        {'slot': 0},
      ]);
    });

    test('SMP v2 err carries the group', () async {
      final device =
          _Device()
            ..handler =
                (device, frame) => {
                  'err': {'group': 1, 'rc': 5},
                };
      final client = await device.client();
      await expectLater(
        client.test(Uint8List(32)),
        throwsA(isA<SmpCommandError>().having((e) => e.code, 'code', 5).having((e) => e.group, 'group', 1)),
      );
    });

    test('an image state with non-text keys is a protocol error', () async {
      final device =
          _Device()
            ..handler =
                (device, frame) => {
                  'images': [
                    {1: 2},
                  ],
                };
      final client = await device.client();
      await expectLater(client.images(), _fails(McuMgrErrorKind.imageStateInvalid));
    });

    test('decodes SMP v1 codes and marks busy or timed-out ones retryable', () {
      expect(SmpCommandError(10, null).v1Result, SmpV1Result.busy);
      expect(SmpCommandError(10, null).retryable, isTrue);
      expect(SmpCommandError(2, null).retryable, isFalse);
      expect(SmpCommandError(10, 1).v1Result, isNull, reason: 'SMP v2 codes belong to their group');
      expect(SmpCommandError(10, 1).retryable, isFalse);
      expect(SmpCommandError(99, null).v1Result, isNull);
      expect('${SmpCommandError(3, null)}', contains('invalidArgument'));
    });

    test('every SMP v1 result has its own code', () {
      expect(SmpV1Result.values.map((result) => result.code).toSet(), hasLength(SmpV1Result.values.length));
    });
  });

  group('upload', () {
    final image = Uint8List.fromList(List.generate(3000, (i) => (i * 7) % 256));

    test('defaults to one write per request without querying parameters', () async {
      final target = _Target(image.length);
      final device = _Device(writeSize: 244)..handler = target.handle;
      final client = await device.client();
      await client.upload(image, onProgress: (_) {}, cancelled: () => false);
      expect(target.parameterQueries, 0);
      expect(target.requestSizes, everyElement(lessThanOrEqualTo(244)));
      expect(target.received.takeBytes(), orderedEquals(image));
    });

    test('falls back to single-write requests for peers without parameters', () async {
      final target = _Target(image.length)..legacy = true;
      final device = _Device(writeSize: 128)..handler = target.handle;
      final client = await device.client();
      await client.upload(image, onProgress: (_) {}, cancelled: () => false, allowFragmentation: true);
      expect(target.parameterQueries, 1);
      expect(target.requestSizes, everyElement(lessThanOrEqualTo(128)));
      expect(target.received.takeBytes(), orderedEquals(image));
    });

    test('resumes from the offset the device reports for a known upload', () async {
      final target = _Target(image.length)..resumeAt = 2000;
      final device = _Device(writeSize: 244)..handler = target.handle;
      final client = await device.client();
      final progress = <double>[];
      await client.upload(image, onProgress: progress.add, cancelled: () => false);
      expect(progress.first, 2000 / image.length);
      expect(progress.last, 1);
      expect(target.offsets.skip(1).first, 2000);
    });

    test('stops when the device keeps acknowledging the same offset', () async {
      final device = _Device(writeSize: 244)..handler = (device, frame) => {'off': 0};
      final client = await device.client();
      await expectLater(client.upload(image, onProgress: (_) {}, cancelled: () => false), _fails(McuMgrErrorKind.uploadStalled));
    });

    test('stops when the device keeps rewinding', () async {
      final device = _Device(writeSize: 244)..handler = (device, frame) => {'off': frame.payload['off'] == 0 ? 200 : 0};
      final client = await device.client();
      await expectLater(client.upload(image, onProgress: (_) {}, cancelled: () => false), _fails(McuMgrErrorKind.uploadRewound));
    });

    test('rejects a hash mismatch', () async {
      final device = _Device(writeSize: 244)..handler = (device, frame) => {'off': image.length, 'match': false};
      final client = await device.client();
      await expectLater(
        client.upload(image, onProgress: (_) {}, cancelled: () => false),
        _fails(McuMgrErrorKind.uploadHashMismatch),
      );
    });

    test('stops when cancelled', () async {
      final target = _Target(image.length);
      final device = _Device(writeSize: 244)..handler = target.handle;
      final client = await device.client();
      var progress = 0.0;
      await expectLater(
        client.upload(image, onProgress: (p) => progress = p, cancelled: () => progress > 0),
        _fails(McuMgrErrorKind.uploadCancelled),
      );
      expect(progress, lessThan(1));
    });

    test('gives the request that starts an upload the longer first-request timeout', () async {
      final target = _Target(image.length);
      final device =
          _Device(writeSize: 244)
            ..handler = target.handle
            ..replyDelay = (frame) => frame.payload['off'] == 0 ? const Duration(milliseconds: 150) : Duration.zero;
      final client = await device.client();
      await client.upload(
        image,
        onProgress: (_) {},
        cancelled: () => false,
        requestTimeout: const Duration(milliseconds: 50),
        firstRequestTimeout: const Duration(milliseconds: 500),
      );
      expect(target.received.takeBytes(), orderedEquals(image));
    });

    test('applies the normal timeout after the first request', () async {
      final target = _Target(image.length);
      final device =
          _Device(writeSize: 244)
            ..handler = target.handle
            ..replyDelay = (frame) => frame.payload['off'] == 0 ? Duration.zero : const Duration(milliseconds: 150);
      final client = await device.client();
      await expectLater(
        client.upload(
          image,
          onProgress: (_) {},
          cancelled: () => false,
          requestTimeout: const Duration(milliseconds: 50),
          firstRequestTimeout: const Duration(milliseconds: 500),
        ),
        _fails(McuMgrErrorKind.responseTimeout),
      );
    });

    test('uploads images shorter than an MCUboot header', () async {
      final tiny = Uint8List.fromList(List.generate(10, (i) => i));
      final target = _Target(tiny.length);
      final device = _Device(writeSize: 244)..handler = target.handle;
      final client = await device.client();
      await client.upload(tiny, onProgress: (_) {}, cancelled: () => false);
      expect(target.received.takeBytes(), orderedEquals(tiny));
    });
  });

  group('SmpCbor', () {
    test('round-trips integers beyond 32 bits', () {
      for (final value in [0xFFFFFFFF, 1 << 32, (1 << 40) + 5, -(1 << 33), 0x7FFFFFFFFFFFFFFF]) {
        expect(SmpCbor.decode(SmpCbor.encode(value)), value, reason: '$value');
      }
      expect(SmpCbor.encode(1 << 32), [0x1b, 0, 0, 0, 1, 0, 0, 0, 0]);
    });

    test('rejects malformed input', () {
      final cases = {
        'trailing bytes': [0x00, 0x00],
        'truncated bytes': [0x42, 0x01],
        'duplicate key': [0xa2, 0x61, 0x61, 0x01, 0x61, 0x61, 0x02],
        'unterminated map': [0xbf, 0x61, 0x61, 0x01],
        'excessive nesting': [...List.filled(18, 0x81), 0x00],
        'unsupported float': [0xf9, 0x3c, 0x00],
      };
      cases.forEach((name, bytes) {
        expect(() => SmpCbor.decode(Uint8List.fromList(bytes)), throwsFormatException, reason: name);
      });
    });

    test('decodes Zephyr indefinite-length containers', () {
      final bytes = Uint8List.fromList([0xbf, 0x61, 0x61, 0x9f, 0x01, 0x02, 0xff, 0xff]);
      expect(SmpCbor.decode(bytes), {
        'a': [1, 2],
      });
    });
  });
}

class _Frame {
  _Frame(this.bytes) : payload = Map<String, Object?>.from(SmpCbor.decode(Uint8List.sublistView(bytes, 8)) as Map);

  final Uint8List bytes;
  final Map<String, Object?> payload;
  int get group => (bytes[4] << 8) | bytes[5];
  int get command => bytes[7];
}

/// A fake SMP peer that reassembles request frames and answers via [handler].
class _Device implements SmpTransport {
  _Device({this.writeSize = 20, this.onFragment});

  final int writeSize;
  final FutureOr<void> Function(_Device device, int index)? onFragment;
  Map<Object?, Object?>? Function(_Device device, _Frame frame)? handler;

  /// Delays each reply, to model a device that is slow to answer.
  Duration Function(_Frame frame)? replyDelay;

  final _updates = StreamController<SmpConnection>.broadcast(sync: true);
  final _notes = StreamController<Uint8List>.broadcast(sync: true);
  final _pending = <int>[];
  var _connection = const SmpConnection(isConnected: true, generation: 1);
  int writes = 0, disconnects = 0;

  Future<McuMgrClient> client() async {
    addTearDown(_updates.close);
    addTearDown(_notes.close);
    final client = McuMgrClient(this);
    await client.open();
    addTearDown(client.close);
    return client;
  }

  void drop() {
    _connection = const SmpConnection(isConnected: false, generation: 1);
    _updates.add(_connection);
  }

  @override
  SmpConnection get connection => _connection;

  @override
  Stream<SmpConnection> get connectionUpdates => _updates.stream;

  @override
  Stream<Uint8List> get notifications => _notes.stream;

  @override
  int get maximumWriteSize => writeSize;

  @override
  Future<void> open() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> disconnect() async {
    disconnects++;
    drop();
  }

  @override
  Future<void> write(Uint8List fragment) async {
    expect(fragment.length, lessThanOrEqualTo(writeSize));
    writes++;
    await onFragment?.call(this, writes);
    if (!_connection.isConnected) throw StateError('Link lost');
    _pending.addAll(fragment);
    if (_pending.length < 8 || _pending.length < 8 + ((_pending[2] << 8) | _pending[3])) return;
    final frame = _Frame(Uint8List.fromList(_pending));
    _pending.clear();
    final response = handler?.call(this, frame);
    if (response == null || !_connection.isConnected) return;
    final body = SmpCbor.encode(response);
    final b = frame.bytes;
    final reply = Uint8List.fromList([b[0] + 1, 0, body.length >> 8, body.length & 255, b[4], b[5], b[6], b[7], ...body]);
    final delay = replyDelay?.call(frame) ?? Duration.zero;
    if (delay == Duration.zero) {
      _notes.add(reply);
    } else {
      Timer(delay, () {
        if (_connection.isConnected && !_notes.isClosed) _notes.add(reply);
      });
    }
  }
}

/// An MCUmgr image-upload target with a 2475-byte receive buffer.
class _Target {
  _Target(this.length);

  final int length;
  bool legacy = false;
  int? resumeAt;
  int _base = 0;
  int parameterQueries = 0;
  final requestSizes = <int>[];
  final offsets = <int>[];
  final received = BytesBuilder();

  Map<Object?, Object?> handle(_Device device, _Frame frame) {
    if (frame.group == 0 && frame.command == 6) {
      parameterQueries++;
      return legacy ? {'rc': 8} : {'buf_size': 2475, 'buf_count': 4};
    }
    expect([frame.group, frame.command], [1, 1]);
    requestSizes.add(frame.bytes.length);
    final offset = frame.payload['off'] as int;
    final data = frame.payload['data'] as Uint8List;
    offsets.add(offset);
    if (offset == 0) {
      expect(frame.payload['len'], length);
      final resume = resumeAt;
      if (resume != null) {
        resumeAt = null;
        _base = resume;
        return {'off': resume};
      }
    } else {
      expect(offset, _base + received.length);
    }
    received.add(data);
    return {'off': offset + data.length};
  }
}

Matcher _fails(McuMgrErrorKind kind) => throwsA(isA<McuMgrError>().having((e) => e.kind, 'kind', kind));

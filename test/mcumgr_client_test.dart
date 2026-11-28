import 'dart:async';
import 'dart:typed_data';

import 'package:mcumgr_dfu/mcumgr_dfu.dart';
import 'package:test/test.dart';

void main() {
  for (final writeSize in [20, 128]) {
    test('sizes firmware requests for a $writeSize-byte transport', () async {
      final image = Uint8List.fromList(List.generate(3000, (i) => i % 256));
      final transport = _UploadTransport(writeSize);
      addTearDown(transport.responses.close);
      final client = McuMgrClient(transport);
      await client.open();
      addTearDown(client.close);

      final progress = <double>[];
      await client.upload(image, onProgress: progress.add, cancelled: () => false);

      expect(transport.image.takeBytes(), orderedEquals(image));
      expect(transport.requestSizes, everyElement(lessThanOrEqualTo(2475)));
      expect(transport.requestSizes, everyElement(lessThanOrEqualTo(writeSize * 24)));
      if (writeSize == 128) expect(transport.requestSizes.first, greaterThan(2400));
      expect(progress.last, 1);
    });
  }

  test('matches a fragmented SMP image-state reply over the public API', () async {
    final transport = _Transport();
    addTearDown(transport.responses.close);
    final client = McuMgrClient(transport);
    await client.open();
    addTearDown(client.close);

    final images = await client.images();
    expect(images.single, {'slot': 0, 'active': true});
    expect(transport.request, [0, 0, 0, 1, 0, 1, 0, 0, 0xa0]);
  });
}

class _Transport implements SmpTransport {
  final responses = StreamController<Uint8List>.broadcast(sync: true);
  late Uint8List request;

  @override
  SmpConnection get connection => const SmpConnection(isConnected: true, generation: 1);

  @override
  Stream<SmpConnection> get connectionUpdates => const Stream.empty();

  @override
  Stream<Uint8List> get notifications => responses.stream;

  @override
  int get maximumWriteSize => 20;

  @override
  Future<void> open() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> write(Uint8List fragment) async {
    request = fragment;
    final body = SmpCbor.encode({
      'images': [
        {'slot': 0, 'active': true},
      ],
    });
    final response = Uint8List.fromList([1, 0, 0, body.length, 0, 1, fragment[6], 0, ...body]);
    responses.add(Uint8List.sublistView(response, 0, 10));
    responses.add(Uint8List.sublistView(response, 10));
  }
}

class _UploadTransport extends _Transport {
  _UploadTransport(this.maximumWriteSize);

  @override
  final int maximumWriteSize;

  final requestSizes = <int>[];
  final image = BytesBuilder();
  final _frame = <int>[];

  @override
  Future<void> write(Uint8List fragment) async {
    expect(fragment.length, lessThanOrEqualTo(maximumWriteSize));
    _frame.addAll(fragment);
    if (_frame.length < 8) return;
    final length = 8 + (_frame[2] << 8) + _frame[3];
    if (_frame.length < length) return;

    final frame = Uint8List.fromList(_frame);
    _frame.clear();
    final group = frame[5];
    final command = frame[7];
    final Map<String, Object?> response;
    if (group == 0 && command == 6) {
      response = {'buf_size': 2475, 'buf_count': 4};
    } else {
      expect([group, command], [1, 1]);
      requestSizes.add(frame.length);
      final payload = SmpCbor.decode(Uint8List.sublistView(frame, 8)) as Map;
      expect(payload['off'], image.length);
      if (image.isEmpty) {
        expect(payload['len'], 3000);
        expect(payload['sha'], hasLength(32));
        expect(payload['data'], hasLength(greaterThanOrEqualTo(32)));
      }
      image.add(payload['data'] as Uint8List);
      response = {'off': image.length};
    }

    final body = SmpCbor.encode(response);
    responses.add(
      Uint8List.fromList([frame[0] + 1, 0, body.length >> 8, body.length & 255, frame[4], group, frame[6], command, ...body]),
    );
  }
}

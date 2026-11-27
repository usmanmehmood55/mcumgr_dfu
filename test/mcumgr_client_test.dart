import 'dart:async';
import 'dart:typed_data';

import 'package:mcumgr_dfu/mcumgr_dfu.dart';
import 'package:test/test.dart';

void main() {
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

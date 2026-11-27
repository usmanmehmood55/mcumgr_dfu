import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mcumgr_dfu/mcumgr_dfu.dart';

String hex(List<int> data) =>
    data.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

void event(String name, [Map<String, Object?> data = const {}]) {
  stdout.writeln(
    jsonEncode({
      'time': DateTime.now().toUtc().toIso8601String(),
      'event': name,
      ...data,
    }),
  );
}

class Relay implements SmpTransport {
  Relay(this.bridge)
    : replies = StreamIterator(
        bridge.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
  final Process bridge;
  final StreamIterator<String> replies;
  final received = StreamController<Uint8List>.broadcast(sync: true);
  final updates = StreamController<SmpConnection>.broadcast(sync: true);
  bool connected = false;
  int generation = 0;

  @override
  SmpConnection get connection =>
      SmpConnection(isConnected: connected, generation: generation);
  @override
  Stream<SmpConnection> get connectionUpdates => updates.stream;
  @override
  Stream<Uint8List> get notifications => received.stream;
  @override
  int get maximumWriteSize => 512;

  Future<void> exchange(Map<String, Object?> request) async {
    bridge.stdin.writeln(jsonEncode(request));
    await bridge.stdin.flush();
    check(await replies.moveNext(), 'UART relay exited');
    final response = jsonDecode(replies.current) as Map;
    if (response['error'] case final String error) throw StateError(error);
    if (response['frame'] case final String encoded) {
      received.add(
        Uint8List.fromList(
          List.generate(
            encoded.length ~/ 2,
            (i) => int.parse(encoded.substring(2 * i, 2 * i + 2), radix: 16),
          ),
        ),
      );
    }
    final next = response['connected'] == true;
    if (next != connected) {
      connected = next;
      if (next) generation++;
      updates.add(connection);
    }
  }

  Future<void> connect() => exchange({'command': 'connect'});
  @override
  Future<void> disconnect() async {
    if (connected) await exchange({'command': 'disconnect'});
  }

  @override
  Future<void> open() async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> write(Uint8List fragment) =>
      exchange({'command': 'write', 'frame': hex(fragment)});
}

Future<void> main(List<String> args) async {
  if (args.length != 8) {
    throw ArgumentError(
      'Expected PYTHON WELLSOLE_ROOT PEER_UART DUT_SIDE DUT_ID PEER_ID CANDIDATE_MANIFEST BASELINE_HASH',
    );
  }
  final manifest = jsonDecode(File(args[6]).readAsStringSync()) as Map;
  check(
    manifest['build_passed'] == true && manifest['side'] == args[3],
    'Wrong or unbuilt candidate',
  );
  final candidate = manifest['image'] as Map;
  final bytes = File(candidate['path'] as String).readAsBytesSync();
  check(
    sha256.convert(bytes).toString() == candidate['file_sha256'],
    'Candidate digest mismatch',
  );
  final hash = candidate['image_hash'] as String;
  final version = (candidate['version'] as List).join('.');
  final process = await Process.start(args.first, [
    '-B',
    'tool/relay_bridge.py',
    ...args.sublist(1, 6),
  ]);
  unawaited(stderr.addStream(process.stderr));
  final relay = Relay(process);
  var client = McuMgrClient(relay);
  try {
    await relay.connect().timeout(const Duration(seconds: 130));
    await client.open();
    Future<Map<String, Object?>> active({
      required bool confirmed,
      String? expectedHash,
    }) async {
      final image = (await client.images()).singleWhere(
        (image) => image['active'] == true,
      );
      final actual = hex(image['hash'] as List<int>);
      final fields = (image['version'] as String)
          .replaceAll('+', '.')
          .split('.');
      final actualVersion = [...fields, if (fields.length == 3) '0'].join('.');
      event('active', {
        'hash': actual,
        'version': actualVersion,
        'confirmed': image['confirmed'],
      });
      check(
        (image['confirmed'] == true) == confirmed,
        'Unexpected confirmation state',
      );
      if (expectedHash != null) {
        check(
          actual == expectedHash && actualVersion == version,
          'Unexpected active candidate',
        );
      }
      return image;
    }

    Future<void> reboot() async {
      event('reset_requested');
      await client.reset(timeout: const Duration(seconds: 60));
      check(!relay.connected, 'DUT remained connected after reset');
      event('remote_disconnected');
      await client.close();
      await relay.connect().timeout(const Duration(seconds: 130));
      event('identity', {'side': args[3], 'factory_id': args[4]});
      client = McuMgrClient(relay);
      await client.open();
    }

    final baseline = await active(confirmed: true);
    check(
      hex(baseline['hash'] as List<int>) == args[7],
      'Unexpected baseline image',
    );
    var runningCase = 'corrupt';
    try {
      if (Platform.environment['HIL_RELAY_CASE'] != 'valid') {
        event('case_start', {'case': runningCase, 'transport': 'dk_relay'});
        final damaged = Uint8List.fromList(bytes);
        final header = ByteData.sublistView(damaged);
        final headerSize = header.getUint16(8, Endian.little);
        final signedEnd =
            headerSize +
            header.getUint16(10, Endian.little) +
            header.getUint32(12, Endian.little);
        damaged[headerSize] ^= 1;
        final alteredHash =
            sha256.convert(damaged.sublist(0, signedEnd)).toString();
        await client.upload(
          damaged,
          cancelled: () => false,
          allowFragmentation: false,
          onProgress: (_) {},
        );
        final damagedSlot = (await client.images()).singleWhere(
          (item) =>
              item['active'] != true &&
              [hash, alteredHash].contains(hex(item['hash'] as List<int>)),
        );
        final damagedHash = damagedSlot['hash'] as Uint8List;
        await client.test(damagedHash);
        final scheduled = (await client.images()).singleWhere(
          (item) => hex(item['hash'] as List<int>) == hex(damagedHash),
        );
        check(
          scheduled['pending'] == true && scheduled['active'] != true,
          'Corrupt artifact was not scheduled for a test boot',
        );
        event('corrupt_test_selected', {'hash': hex(damagedHash)});
        await reboot();
        check(
          hex((await active(confirmed: true))['hash'] as List<int>) == args[7],
          'Corrupt artifact changed the active image',
        );
        event('case_pass', {'case': runningCase, 'transport': 'dk_relay'});
        if (Platform.environment['HIL_RELAY_CASE'] == 'corrupt') return;
      }

      runningCase = 'interrupted';
      event('case_start', {'case': runningCase, 'transport': 'dk_relay'});
      var partial = 0.0;
      try {
        await client.upload(
          bytes,
          cancelled: () => partial >= .25,
          allowFragmentation: false,
          onProgress: (progress) => partial = progress,
        );
        throw StateError('Upload completed before interruption');
      } on StateError catch (error) {
        if (!error.message.toString().startsWith('Firmware upload cancelled')) {
          rethrow;
        }
      }
      check(
        partial >= .25 && partial < 1,
        'Missing partial upload acknowledgement',
      );
      event('interrupted_at', {'offset': (partial * bytes.length).round()});
      await client.close();
      await relay.disconnect();
      await relay.connect().timeout(const Duration(seconds: 130));
      event('identity', {'side': args[3], 'factory_id': args[4]});
      client = McuMgrClient(relay);
      await client.open();
      check(
        hex((await active(confirmed: true))['hash'] as List<int>) == args[7],
        'Baseline changed during interruption',
      );

      Future<void> upload({bool recovery = false}) async {
        var last = -1;
        await client.upload(
          bytes,
          cancelled: () => false,
          allowFragmentation: false,
          onProgress: (progress) {
            final off = (progress * bytes.length).round();
            if (last == -1 && recovery) {
              event('first_recovery_ack', {'offset': off});
            }
            if (off ~/ 65536 != last || progress == 1) {
              last = off ~/ 65536;
              event('upload_ack', {'offset': off, 'bytes': bytes.length});
            }
          },
        );
      }

      await upload(recovery: true);
      await reboot();
      check(
        hex((await active(confirmed: true))['hash'] as List<int>) == args[7],
        'Baseline changed after unselected upload',
      );
      event('case_pass', {'case': runningCase, 'transport': 'dk_relay'});
      runningCase = 'rollback';
      event('case_start', {'case': runningCase, 'transport': 'dk_relay'});

      final imageHash = Uint8List.fromList(
        List.generate(
          32,
          (i) => int.parse(hash.substring(2 * i, 2 * i + 2), radix: 16),
        ),
      );
      Future<bool> candidateStaged() async => (await client.images()).any(
        (item) =>
            item['active'] != true && hex(item['hash'] as List<int>) == hash,
      );
      Future<void> testBoot() async {
        check(await candidateStaged(), 'Expected inactive candidate absent');
        await client.test(imageHash);
        await reboot();
        final probation = Stopwatch()..start();
        var reads = 0;
        do {
          await active(confirmed: false, expectedHash: hash);
          reads++;
          if (probation.elapsed < const Duration(seconds: 10)) {
            await Future<void>.delayed(const Duration(seconds: 2));
          }
        } while (probation.elapsed < const Duration(seconds: 10) || reads < 3);
      }

      await testBoot();
      await reboot();
      check(
        hex((await active(confirmed: true))['hash'] as List<int>) == args[7],
        'Rollback did not restore baseline',
      );
      event('case_pass', {'case': runningCase, 'transport': 'dk_relay'});

      runningCase = 'success';
      event('case_start', {'case': runningCase, 'transport': 'dk_relay'});
      if (!await candidateStaged()) await upload();
      await testBoot();
      await client.confirm(imageHash);
      await active(confirmed: true, expectedHash: hash);
      await reboot();
      await active(confirmed: true, expectedHash: hash);
      event('case_pass', {'case': runningCase, 'transport': 'dk_relay'});
    } catch (error) {
      event('case_fail', {'case': runningCase, 'error': error.toString()});
      rethrow;
    }
  } finally {
    await client.close();
    try {
      await relay.disconnect().timeout(const Duration(seconds: 20));
    } finally {
      await process.stdin.close();
      await relay.replies.cancel();
      await relay.received.close();
      await relay.updates.close();
      process.kill();
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mcumgr_dfu/mcumgr_dfu.dart';
import 'package:universal_ble/universal_ble.dart';

const smp = '8d53dc1d-1db7-4cd3-868b-8a527460aa84';
const characteristic = 'da2e7828-fbce-4e01-ae9e-261174997c48';
const commissioning = '00000000-0000-0000-0000-00000000000b';
const factory = String.fromEnvironment('DUT_FACTORY_ID');
const side = String.fromEnvironment('DUT_SIDE');
const manifestPath = String.fromEnvironment('CANDIDATE_MANIFEST');
const selection = String.fromEnvironment('OTA_CASE', defaultValue: 'suite');
const expectedBaseline = String.fromEnvironment('BASELINE_HASH');

String hex(List<int> data) =>
    data.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

const eventLog = String.fromEnvironment('EVENT_LOG');

void evidence(String event, [Map<String, Object?> data = const {}]) {
  final line = jsonEncode({
    'time': DateTime.now().toUtc().toIso8601String(),
    'event': event,
    ...data,
  });
  if (eventLog.isEmpty) {
    // ignore: avoid_print
    print(line);
  } else {
    File(
      eventLog,
    ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  }
}

class BleTransport implements SmpTransport {
  BleTransport(this.id, this.generation) {
    subscription = UniversalBle.connectionStream(id).listen((connected) {
      connectedState = connected;
      changes.add(connection);
    });
  }

  final String id;
  final int generation;
  bool connectedState = true;
  int writeSize = 20;
  int? cap;
  int writes = 0;
  bool failFollower = false;
  late final StreamSubscription<bool> subscription;
  final changes = StreamController<SmpConnection>.broadcast();

  @override
  SmpConnection get connection =>
      SmpConnection(isConnected: connectedState, generation: generation);
  @override
  Stream<SmpConnection> get connectionUpdates => changes.stream;
  @override
  Stream<Uint8List> get notifications => UniversalBle.characteristicValueStream(
    id,
    characteristic,
    serviceId: smp,
  );
  @override
  int get maximumWriteSize => cap ?? writeSize;
  @override
  Future<void> open() async {
    await UniversalBle.discoverServices(id);
    await UniversalBle.subscribeNotifications(id, smp, characteristic);
    writeSize = ((await UniversalBle.requestMtu(id, 517)) - 3).clamp(20, 512);
    evidence('transport', {'write_size': writeSize, 'generation': generation});
  }

  @override
  Future<void> write(Uint8List fragment) async {
    writes++;
    if (failFollower && writes == 3) {
      throw StateError('injected follower write failure');
    }
    await UniversalBle.write(
      id,
      smp,
      characteristic,
      fragment,
      withoutResponse: true,
    );
  }

  @override
  Future<void> close() => UniversalBle.unsubscribe(id, smp, characteristic);
  @override
  Future<void> disconnect() async {
    if (connectedState) {
      await UniversalBle.disconnect(id);
      connectedState = false;
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await subscription.cancel();
    await changes.close();
  }
}

class Bench {
  Bench(this.image, this.imageHash, this.version);
  final Uint8List image;
  final String imageHash;
  final String version;
  late String baselineHash, baselineVersion;
  String? id;
  int generation = 0;
  BleTransport? transport;
  McuMgrClient? smpClient;
  McuMgrClient get client => smpClient!;

  Future<void> attach() async {
    final deadline = Stopwatch()..start();
    Object? lastFailure;
    while (deadline.elapsed < const Duration(seconds: 100)) {
      final devices = <String>{if (id != null) id!};
      final seen = UniversalBle.scanStream.listen((device) {
        for (final record in device.manufacturerDataList) {
          final payload = record.payload;
          if (record.companyId == 0xffff &&
              payload.length == 10 &&
              payload[0] == 1 &&
              payload[1] == (side == 'left' ? 2 : 1) &&
              hex(payload.sublist(2)) == factory.toLowerCase()) {
            devices.add(device.deviceId);
          }
        }
      });
      try {
        await UniversalBle.startScan();
        await Future<void>.delayed(const Duration(seconds: 3));
      } finally {
        await UniversalBle.stopScan();
        await seen.cancel();
      }
      evidence('scan', {'matched': devices.length});
      for (final candidate in devices) {
        try {
          await UniversalBle.connect(
            candidate,
            timeout: const Duration(seconds: 6),
          );
          await UniversalBle.discoverServices(candidate);
          final status = await UniversalBle.read(
            candidate,
            commissioning,
            commissioning,
            timeout: const Duration(seconds: 5),
          );
          expect(status.length, anyOf(12, 21));
          if (hex(status.sublist(4, 12)) != factory.toLowerCase()) {
            await UniversalBle.disconnect(candidate);
            continue;
          }
          expect(status[0], 1);
          expect(status[1], side == 'left' ? 2 : 1);
          expect(status[2], 0);
          expect(status[3] & 1, 0);
          transport = BleTransport(candidate, ++generation);
          smpClient = McuMgrClient(transport!);
          await client.open();
          id = candidate;
          evidence('identity', {
            'side': side,
            'factory_id': factory,
            'ble_id': id,
          });
          return;
        } on Exception catch (error) {
          evidence('connect_error', {'error': error.toString()});
          lastFailure = error;
          await detach();
          await UniversalBle.disconnect(candidate).catchError((Object _) {});
        }
      }
    }
    throw StateError('DUT $factory unavailable: $lastFailure');
  }

  Future<void> detach() async {
    try {
      await smpClient?.close();
    } finally {
      await transport?.dispose();
      smpClient = null;
      transport = null;
    }
  }

  Future<Map<String, Object?>> active({
    String? hash,
    String? version,
    required bool confirmed,
  }) async {
    final active =
        (await client.images())
            .where((image) => image['active'] == true)
            .single;
    final actualHash = hex(active['hash'] as List<int>);
    final parts = (active['version'] as String).replaceAll('+', '.').split('.');
    final actualVersion = [...parts, if (parts.length == 3) '0'].join('.');
    evidence('active', {
      'hash': actualHash,
      'version': actualVersion,
      'confirmed': active['confirmed'] == true,
    });
    if (hash != null) expect(actualHash, hash);
    if (version != null) expect(actualVersion, version);
    expect(active['confirmed'] == true, confirmed);
    return {...active, 'hash': actualHash, 'version': actualVersion};
  }

  Future<void> baseline() async =>
      active(hash: baselineHash, version: baselineVersion, confirmed: true);

  Future<void> reboot() async {
    final gone = transport!.connectionUpdates
        .firstWhere((event) => !event.isConnected)
        .timeout(const Duration(seconds: 30));
    unawaited(gone.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    evidence('reset_requested');
    await client.reset();
    await gone;
    evidence('remote_disconnected');
    await detach();
    await attach();
  }

  Future<void> upload(
    Uint8List bytes, {
    bool interrupt = false,
    bool resumed = false,
    void Function(int)? acknowledged,
  }) async {
    var progress = 0.0;
    var lastLogged = -1;
    final clock = Stopwatch()..start();
    final count = transport!.writes;
    try {
      await client.upload(
        bytes,
        allowFragmentation: true,
        cancelled: () => interrupt && progress >= .25,
        onProgress: (next) {
          final offset = (next * bytes.length).round();
          acknowledged?.call(offset);
          if (progress == 0 && resumed) {
            evidence('first_recovery_ack', {'offset': offset});
          }
          progress = next;
          if (offset ~/ 65536 != lastLogged || next == 1) {
            lastLogged = offset ~/ 65536;
            evidence('upload_ack', {'offset': offset, 'bytes': bytes.length});
          }
        },
      );
    } on McuMgrError catch (error) {
      if (!interrupt || progress < .25 || progress >= 1 || error.kind != McuMgrErrorKind.uploadCancelled) {
        rethrow;
      }
    }
    expect(interrupt ? progress >= .25 && progress < 1 : progress == 1, isTrue);
    evidence('transfer', {
      'seconds': clock.elapsedMilliseconds / 1000,
      'writes': transport!.writes - count,
      'write_size': transport!.maximumWriteSize,
      'acknowledged_bytes': (progress * bytes.length).round(),
    });
  }

  Future<void> select(String hash) async {
    final bytes = Uint8List.fromList(
      List.generate(
        32,
        (i) => int.parse(hash.substring(i * 2, i * 2 + 2), radix: 16),
      ),
    );
    await client.test(bytes);
    final selected =
        (await client.images())
            .where((image) => hex(image['hash'] as List<int>) == hash)
            .single;
    expect(selected['pending'], true);
    expect(selected['active'], isNot(true));
  }

  Future<void> probation() async {
    final revision = client.connectionRevision;
    final clock = Stopwatch()..start();
    var polls = 0;
    do {
      await active(hash: imageHash, version: version, confirmed: false);
      expect(client.connectionRevision, revision);
      polls++;
      if (clock.elapsed < const Duration(seconds: 10)) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    } while (clock.elapsed < const Duration(seconds: 10) || polls < 3);
    evidence('probation', {
      'polls': polls,
      'seconds': clock.elapsedMilliseconds / 1000,
    });
  }

  Future<void> corrupt() async {
    final bad = Uint8List.fromList(image);
    final fields = ByteData.sublistView(bad);
    final header = fields.getUint16(8, Endian.little);
    final signedEnd =
        header +
        fields.getUint16(10, Endian.little) +
        fields.getUint32(12, Endian.little);
    bad[header] ^= 1;
    final alteredHash = sha256.convert(bad.sublist(0, signedEnd)).toString();
    await upload(bad);
    final found =
        (await client.images())
            .where(
              (i) =>
                  i['active'] != true &&
                  [
                    imageHash,
                    alteredHash,
                  ].contains(hex(i['hash'] as List<int>)),
            )
            .single;
    await select(hex(found['hash'] as List<int>));
    await reboot();
    await baseline();
  }

  Future<void> interrupted() async {
    await upload(image, interrupt: true);
    await detach();
    await attach();
    await baseline();
    await upload(image, resumed: true);
    await reboot();
    await baseline();
  }

  Future<void> fragmentedEcho() async {
    final link = transport!;
    final start = link.writes;
    link.cap = 20;
    try {
      final token = List.filled(6, 'nrf52840-smp-echo-').join();
      final response = await client.request(2, 0, 0, {'d': token});
      expect(response['r'], token);
      expect(link.writes - start, greaterThan(1));
      evidence('fragmented_echo', {
        'write_size': 20,
        'writes': link.writes - start,
      });
    } finally {
      link.cap = null;
    }
  }

  Future<void> fragmentFailure() async {
    transport!.cap = 20;
    transport!.writes = 0;
    transport!.failFollower = true;
    await expectLater(
      upload(image),
      throwsA(
        isA<McuMgrError>()
            .having((error) => error.kind, 'kind', McuMgrErrorKind.writeFailed)
            .having((error) => '${error.cause}', 'cause', contains('injected follower write failure')),
      ),
    );
    expect(transport!.connectedState, false);
    final writes = transport!.writes;
    await expectLater(
      client.reset(),
      throwsA(isA<McuMgrError>().having((error) => error.kind, 'kind', McuMgrErrorKind.transportClosed)),
    );
    expect(transport!.writes, writes);
    await detach();
    await attach();
    await baseline();
  }

  Future<void> uploadWithRecovery() async {
    final elapsed = Stopwatch()..start();
    var acknowledged = 0;
    var lastRecoveryOffset = -1;
    var retriesWithoutProgress = 0;
    for (var attempt = 0; ; attempt++) {
      try {
        await upload(
          image,
          resumed: attempt > 0,
          acknowledged: (offset) {
            if (offset > acknowledged) acknowledged = offset;
          },
        );
        return;
      } catch (error) {
        if (transport!.connectedState && !(error is McuMgrError && (error.kind == McuMgrErrorKind.writeTimeout || error.kind == McuMgrErrorKind.responseTimeout))) rethrow;
        if (acknowledged > lastRecoveryOffset) {
          lastRecoveryOffset = acknowledged;
          retriesWithoutProgress = 0;
        } else if (++retriesWithoutProgress >= 3) {
          rethrow;
        }
        if (elapsed.elapsed >= const Duration(minutes: 15)) rethrow;
        evidence('upload_link_lost', {
          'offset': acknowledged,
          'attempt': attempt + 1,
          'error': error.toString(),
        });
        await detach();
        await attach();
        await baseline();
      }
    }
  }

  Future<void> activate({required bool confirm}) async {
    await uploadWithRecovery();
    await baseline();
    await select(imageHash);
    await reboot();
    await probation();
    if (confirm) {
      final hash =
          (await client.images()).singleWhere(
                (i) => i['active'] == true,
              )['hash']
              as Uint8List;
      await client.confirm(hash);
      await active(hash: imageHash, version: version, confirmed: true);
    }
    await reboot();
    if (confirm) {
      await active(hash: imageHash, version: version, confirmed: true);
    } else {
      await baseline();
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('SMP DFU over real BLE', (tester) async {
    await tester.runAsync(() async {
      expect(factory, matches(RegExp(r'^[0-9a-fA-F]{16}$')));
      expect(side, anyOf('left', 'right'));
      final manifest = jsonDecode(File(manifestPath).readAsStringSync()) as Map;
      expect(manifest['build_passed'], true);
      expect(manifest['side'], side);
      final candidate = manifest['image'] as Map;
      final image = File(candidate['path'] as String).readAsBytesSync();
      expect(sha256.convert(image).toString(), candidate['file_sha256']);
      evidence('candidate', {
        'side': side,
        ...Map<String, Object?>.from(candidate),
      });
      final bench = Bench(
        image,
        candidate['image_hash'] as String,
        (candidate['version'] as List).join('.'),
      );
      evidence('requesting_bluetooth_permission');
      await UniversalBle.requestPermissions();
      evidence('bluetooth_permission_ready');
      try {
        await bench.attach();
        final baseline = await bench.active(confirmed: true);
        bench.baselineHash = baseline['hash'] as String;
        bench.baselineVersion = baseline['version'] as String;
        if (expectedBaseline.isNotEmpty) {
          expect(bench.baselineHash, expectedBaseline);
        }
        if (selection != 'transport' &&
            selection != 'fragmented_echo' &&
            selection != 'fragment_failure') {
          expect(bench.baselineHash, isNot(bench.imageHash));
          final installed =
              bench.baselineVersion.split('.').map(int.parse).toList();
          final offered = bench.version.split('.').map(int.parse).toList();
          expect(installed.take(2), offered.take(2));
          expect(installed[3], offered[3]);
          expect(offered[2], greaterThan(installed[2]));
        }
        final cases = {
          'corrupt': bench.corrupt,
          'interrupted': bench.interrupted,
          'fragmented_echo': bench.fragmentedEcho,
          'fragment_failure': bench.fragmentFailure,
          'rollback': () => bench.activate(confirm: false),
          'success': () => bench.activate(confirm: true),
        };
        expect(
          selection == 'suite' ||
              selection == 'transport' ||
              cases.containsKey(selection),
          true,
        );
        for (final entry in cases.entries) {
          if (selection == 'transport') {
            if (!['fragmented_echo', 'fragment_failure'].contains(entry.key)) {
              continue;
            }
          } else if (selection != 'suite' && selection != entry.key) {
            continue;
          }
          evidence('case_start', {'case': entry.key});
          try {
            await entry.value();
            evidence('case_pass', {'case': entry.key});
          } catch (error) {
            evidence('case_fail', {
              'case': entry.key,
              'error': error.toString(),
            });
            rethrow;
          }
        }
      } finally {
        await bench.detach();
      }
    });
    final error = tester.takeException();
    if (error != null) throw error;
  }, timeout: const Timeout(Duration(minutes: 75)));
}

// Chrome Web Bluetooth harness for mcumgr_dfu. Driven by tool/chrome_runner.dart:
// the runner serves this app and the candidate, answers the device chooser, and
// calls window.hilStart() / window.hilPick() with a user gesture. Evidence is
// printed to the console as one JSON object per line, in the same schema as
// integration_test/ota_test.dart, so collect_evidence.py can summarize it.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:mcumgr_dfu/mcumgr_dfu.dart';
import 'package:universal_ble/universal_ble.dart';

const smp = '8d53dc1d-1db7-4cd3-868b-8a527460aa84';
const chr = 'da2e7828-fbce-4e01-ae9e-261174997c48';
const commissioning = '00000000-0000-0000-0000-00000000000b';

/// Scenarios; collect_evidence.py knows how many reboots each expects.
const cases = {'probe', 'reconnect', 'upload', 'rollback', 'success'};

void Function()? onTap;

final view = ValueNotifier<List<String>>(const []);

void evidence(String event, [Map<String, Object?> data = const {}]) {
  final line = jsonEncode({'time': DateTime.now().toUtc().toIso8601String(), 'event': event, ...data});
  print(line);
  view.value = [...view.value, line];
  // tool/serve_harness.py appends these to a file; other servers ignore them.
  unawaited(http.post(Uri.base.resolve('/evidence'), body: line).then<void>((_) {}, onError: (Object _) {}));
}

String hex(List<int> data) => data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String text) =>
    Uint8List.fromList(List.generate(text.length ~/ 2, (i) => int.parse(text.substring(i * 2, i * 2 + 2), radix: 16)));

String normalizeVersion(String version) {
  final parts = version.replaceAll('+', '.').split('.');
  return [...parts, if (parts.length == 3) '0'].join('.');
}

void check(bool valid, String message) {
  if (!valid) throw StateError(message);
}

/// Run settings from the page URL, set by the runner.
class Config {
  Config(Map<String, String> query)
    : factory = (query['factory'] ?? '').toLowerCase(),
      side = query['side'] ?? '',
      baseline = (query['baseline'] ?? '').toLowerCase(),
      scenarios = (query['case'] ?? 'success').split(','),
      idle = Duration(seconds: int.parse(query['idle'] ?? '180')),
      writeSizes = (query['write'] ?? '180').split(',').map(int.parse).toList(),
      pipelines = (query['pipeline'] ?? '1').split(',').map(int.parse).toList(),
      fragment = query['fragment'] != '0',
      reconnect = Duration(seconds: int.parse(query['reconnect'] ?? '90')),
      repick = query['repick'] != '0' {
    check(RegExp(r'^[0-9a-f]{16}$').hasMatch(factory), 'factory must be 16 hex digits');
    check(side == 'left' || side == 'right', 'side must be left or right');
    check(scenarios.every(cases.contains), 'case must be a comma list of $cases');
    check(writeSizes.every((size) => size >= 20 && size <= 512), 'write sizes must be 20..512');
    check(pipelines.every((depth) => depth >= 1 && depth <= 16), 'pipeline depths must be 1..16');
  }

  final String factory, side, baseline;
  final List<String> scenarios;
  final Duration idle;

  /// Probe sweeps every write size × pipeline depth; other cases use the first.
  final List<int> writeSizes, pipelines;
  int get writeSize => writeSizes.first;
  int get pipeline => pipelines.first;
  final bool fragment, repick;
  final Duration reconnect;

  Map<String, Object?> toJson() => {
    'factory_id': factory,
    'side': side,
    'baseline': baseline,
    'cases': scenarios,
    'idle_seconds': idle.inSeconds,
    'write_sizes': writeSizes,
    'pipelines': pipelines,
    'fragment': fragment,
    'reconnect_seconds': reconnect.inSeconds,
    'repick': repick,
  };
}

class WebLink implements SmpTransport {
  WebLink(this.id, this.generation, this.writeSize, this.pipeline) {
    subscription = UniversalBle.connectionStream(id).listen((state) {
      connected = state;
      updates.add(connection);
    });
  }

  final String id;
  final int generation;
  int writeSize;

  /// Writes allowed in flight. Above 1, writes rotate across universal_ble
  /// queue IDs so they are not serialized behind each other's promises.
  int pipeline;
  final inFlight = Queue<Future<void>>();
  Object? failure;
  bool connected = true;
  int writes = 0;
  final writeTime = Stopwatch();
  final updates = StreamController<SmpConnection>.broadcast(sync: true);
  late final StreamSubscription<bool> subscription;

  @override
  SmpConnection get connection => SmpConnection(isConnected: connected, generation: generation);
  @override
  Stream<SmpConnection> get connectionUpdates => updates.stream;
  @override
  int get maximumWriteSize => writeSize;
  @override
  Stream<Uint8List> get notifications => UniversalBle.characteristicValueStream(id, chr, serviceId: smp);
  @override
  Future<void> open() => UniversalBle.subscribeNotifications(id, smp, chr);
  @override
  Future<void> close() => UniversalBle.unsubscribe(id, smp, chr);

  @override
  Future<void> write(Uint8List fragment) async {
    if (failure case final error?) throw error;
    writes++;
    writeTime.start();
    try {
      if (pipeline <= 1) {
        await UniversalBle.write(id, smp, chr, fragment, withoutResponse: true);
        return;
      }
      inFlight.add(
        UniversalBle.write(
          id,
          smp,
          chr,
          fragment,
          withoutResponse: true,
          queueId: 'smp-$id-${writes % pipeline}',
        ).catchError((Object error) => failure ??= error),
      );
      while (inFlight.length >= pipeline) {
        await inFlight.removeFirst();
      }
      if (failure case final error?) throw error;
    } finally {
      writeTime.stop();
    }
  }

  @override
  Future<void> disconnect() async {
    if (connected) await UniversalBle.disconnect(id);
    connected = false;
  }

  Future<void> dispose() async {
    await subscription.cancel();
    await updates.close();
  }
}

class Bench {
  Bench(this.config);

  final Config config;
  String? id;
  WebLink? link;
  McuMgrClient? smpClient;
  int generation = 0, picks = 0;
  Completer<String>? picking;
  late Uint8List image;
  late String imageHash, version;
  String? baselineHash, baselineVersion;

  McuMgrClient get client => smpClient ?? (throw StateError('Not attached'));

  /// Waits for the runner to call window.hilPick() with a user gesture.
  Future<String> requestPick(String reason) {
    final pending = picking ??= Completer<String>();
    evidence('pick_required', {'reason': reason});
    return pending.future;
  }

  /// Called from JavaScript inside a user gesture.
  void pick() {
    final pending = picking;
    if (pending == null) return;
    UniversalBle.requestDevice(
          scanFilter: ScanFilter(
            withManufacturerData: [
              ManufacturerDataFilter(companyIdentifier: 0xffff, payloadPrefix: unhex('0102${config.factory}')),
            ],
          ),
          platformConfig: PickerPlatformConfig(web: WebOptions(optionalServices: [smp, commissioning])),
        )
        .then((device) {
          evidence('picked', {'ble_id': device.deviceId, 'picks': ++picks});
          picking = null;
          pending.complete(device.deviceId);
        })
        .catchError((Object error) {
          evidence('pick_failed', {'error': error.toString()});
          picking = null;
          pending.completeError(error);
        });
  }

  Future<void> attach() async {
    var deadline = DateTime.now().add(config.reconnect);
    var reconnectPicks = 0;
    while (true) {
      final device = id ??= await requestPick('initial');
      try {
        await UniversalBle.connect(device, timeout: const Duration(seconds: 25));
        final services = await UniversalBle.discoverServices(device, timeout: const Duration(seconds: 20));
        final status = await UniversalBle.read(device, commissioning, commissioning, timeout: const Duration(seconds: 15));
        if ((status.length != 12 && status.length != 21) ||
            status[0] != 1 ||
            status[1] != (config.side == 'left' ? 2 : 1) ||
            status[2] != 0 ||
            (status[3] & 1) != 0 ||
            hex(status.sublist(4, 12)) != config.factory) {
          throw FormatException('Wrong DUT identity ${hex(status)}');
        }
        link = WebLink(device, ++generation, config.writeSize, config.pipeline);
        smpClient = McuMgrClient(link!);
        await client.open();
        evidence('transport', {'write_size': config.writeSize, 'generation': generation, 'services': services.length});
        evidence('identity', {'side': config.side, 'factory_id': config.factory, 'ble_id': device});
        return;
      } catch (error) {
        if (error is FormatException) rethrow;
        evidence('connect_error', {'error': error.toString()});
        await detach();
        await UniversalBle.disconnect(device).catchError((Object _) {});
        if (DateTime.now().isAfter(deadline)) {
          if (!config.repick || ++reconnectPicks > 3) rethrow;
          id = await requestPick('reconnect');
          deadline = DateTime.now().add(config.reconnect);
          continue;
        }
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
  }

  Future<void> detach() async {
    try {
      await smpClient?.close();
    } catch (_) {
      // The link is already gone.
    } finally {
      await link?.dispose();
      smpClient = null;
      link = null;
    }
  }

  Future<Map<String, Object?>> active({String? hash, String? version, required bool confirmed}) async {
    final active = (await client.images()).singleWhere((i) => i['active'] == true);
    final actualHash = hex(active['hash'] as List<int>);
    final actualVersion = normalizeVersion(active['version'] as String);
    final isConfirmed = active['confirmed'] == true;
    evidence('active', {'hash': actualHash, 'version': actualVersion, 'confirmed': isConfirmed});
    if (hash != null) check(actualHash == hash, 'Active hash $actualHash, expected $hash');
    if (version != null) check(actualVersion == version, 'Active version $actualVersion, expected $version');
    check(isConfirmed == confirmed, 'Active confirmed $isConfirmed, expected $confirmed');
    return {...active, 'hash': actualHash, 'version': actualVersion};
  }

  Future<void> baseline() => active(hash: baselineHash, version: baselineVersion, confirmed: true);

  Future<void> reboot() async {
    final gone = link!.connectionUpdates.firstWhere((s) => !s.isConnected).timeout(const Duration(seconds: 35));
    unawaited(gone.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    evidence('reset_requested');
    await client.reset();
    await gone;
    evidence('remote_disconnected');
    await detach();
    await Future<void>.delayed(const Duration(seconds: 3));
    await attach();
  }

  Future<void> loadCandidate() async {
    final manifest = jsonDecode((await http.get(Uri.base.resolve('/candidate.json'))).body) as Map;
    final response = await http.get(Uri.base.resolve('/candidate.bin'));
    check(response.statusCode == 200, 'Candidate download failed: ${response.statusCode}');
    image = response.bodyBytes;
    check(sha256.convert(image).toString() == manifest['file_sha256'], 'Candidate digest mismatch');
    imageHash = manifest['image_hash'] as String;
    version = (manifest['version'] as List).join('.');
    evidence('candidate', {'bytes': image.length, 'image_hash': imageHash, 'version': version});
  }

  /// Measures upload throughput for every write size and pipeline depth by
  /// uploading 32 KB of the candidate to the secondary slot and cancelling.
  /// The device acknowledges only bytes it received intact, and a partial
  /// upload never changes which image boots.
  Future<void> probe() async {
    const window = 32768;
    var failures = 0;
    for (final size in config.writeSizes) {
      for (final depth in config.pipelines) {
        if (link == null) await attach();
        link!
          ..writeSize = size
          ..pipeline = depth;
        var first = -1, last = 0, writesAtFirst = 0, awaitAtFirst = 0;
        final clock = Stopwatch();
        try {
          try {
            await client.upload(
              image,
              allowFragmentation: config.fragment,
              cancelled: () => first >= 0 && last - first >= window,
              onProgress: (progress) {
                last = (progress * image.length).round();
                if (first < 0) {
                  // The first acknowledgement may resume an earlier partial upload.
                  first = last;
                  writesAtFirst = link!.writes;
                  awaitAtFirst = link!.writeTime.elapsedMilliseconds;
                  clock.start();
                }
              },
            );
          } on McuMgrError catch (error) {
            if (error.kind != McuMgrErrorKind.uploadCancelled) rethrow;
          }
          final writes = link!.writes - writesAtFirst;
          final ms = clock.elapsedMilliseconds;
          evidence('throughput', {
            'write_size': size,
            'pipeline': depth,
            'ok': true,
            'bytes': last - first,
            'ms': ms,
            'writes': writes,
            'ms_per_write': writes == 0 ? null : ms / writes,
            'write_await_ms_per_write': writes == 0 ? null : (link!.writeTime.elapsedMilliseconds - awaitAtFirst) / writes,
            'bytes_per_s': ms == 0 ? null : ((last - first) * 1000 / ms).round(),
            'from_offset': first,
          });
        } catch (error) {
          failures++;
          evidence('throughput', {'write_size': size, 'pipeline': depth, 'ok': false, 'error': error.toString()});
          await detach();
          await UniversalBle.disconnect(id!).catchError((Object _) {});
          await Future<void>.delayed(const Duration(seconds: 5));
        }
      }
    }
    check(failures < config.writeSizes.length * config.pipelines.length, 'Every probe combination failed');
  }

  Future<void> upload() async {
    final elapsed = Stopwatch()..start();
    var acknowledged = 0, lastRecoveryOffset = -1, retriesWithoutProgress = 0;
    for (var attempt = 0; ; attempt++) {
      final current = link!;
      final writes = current.writes;
      final writeMs = current.writeTime.elapsedMilliseconds;
      final clock = Stopwatch()..start();
      var bucket = -1;
      try {
        await client.upload(
          image,
          allowFragmentation: config.fragment,
          cancelled: () => false,
          onProgress: (progress) {
            final offset = (progress * image.length).round();
            if (attempt > 0 && offset > 0 && bucket < 0) evidence('first_recovery_ack', {'offset': offset});
            acknowledged = offset > acknowledged ? offset : acknowledged;
            if (offset ~/ 32768 != bucket || progress == 1) {
              bucket = offset ~/ 32768;
              evidence('upload_ack', {'offset': offset, 'bytes': image.length});
            }
          },
        );
        evidence('transfer', {
          'seconds': clock.elapsedMilliseconds / 1000,
          'writes': current.writes - writes,
          'write_size': config.writeSize,
          'write_await_seconds': (current.writeTime.elapsedMilliseconds - writeMs) / 1000,
          'acknowledged_bytes': image.length,
          'attempts': attempt + 1,
          'total_seconds': elapsed.elapsedMilliseconds / 1000,
        });
        return;
      } catch (error) {
        if (current.connected && !(error is McuMgrError && (error.kind == McuMgrErrorKind.writeTimeout || error.kind == McuMgrErrorKind.responseTimeout))) rethrow;
        if (acknowledged > lastRecoveryOffset) {
          lastRecoveryOffset = acknowledged;
          retriesWithoutProgress = 0;
        } else if (++retriesWithoutProgress >= 3) {
          rethrow;
        }
        if (elapsed.elapsed >= const Duration(minutes: 15)) rethrow;
        evidence('upload_link_lost', {'offset': acknowledged, 'attempt': attempt + 1, 'error': error.toString()});
        await detach();
        await attach();
        await baseline();
      }
    }
  }

  Future<void> activate({required bool confirm}) async {
    await upload();
    await baseline();
    final staged = (await client.images()).singleWhere((i) => i['active'] != true && hex(i['hash'] as List<int>) == imageHash);
    await client.test(staged['hash'] as Uint8List);
    final selected = (await client.images()).singleWhere((i) => hex(i['hash'] as List<int>) == imageHash);
    check(selected['pending'] == true, 'Candidate is not pending after test');
    await reboot();
    final clock = Stopwatch()..start();
    var polls = 0;
    do {
      await active(hash: imageHash, version: version, confirmed: false);
      polls++;
      if (clock.elapsed < const Duration(seconds: 10)) await Future<void>.delayed(const Duration(seconds: 2));
    } while (clock.elapsed < const Duration(seconds: 10) || polls < 3);
    evidence('probation', {'polls': polls, 'seconds': clock.elapsedMilliseconds / 1000});
    if (confirm) {
      await client.confirm(unhex(imageHash));
      await active(hash: imageHash, version: version, confirmed: true);
    }
    await reboot();
    if (confirm) {
      await active(hash: imageHash, version: version, confirmed: true);
    } else {
      await baseline();
    }
  }

  /// Reboots after [Config.idle] connected and idle, so Chrome has not seen an
  /// advertisement for that long, then requires a reconnect without a new
  /// chooser selection. This is the condition that failed after test reboots.
  Future<void> reconnect() async {
    final before = picks;
    evidence('idle', {'seconds': config.idle.inSeconds});
    final clock = Stopwatch()..start();
    while (clock.elapsed < config.idle) {
      await Future<void>.delayed(const Duration(seconds: 20));
      await active(hash: baselineHash, version: baselineVersion, confirmed: true);
    }
    final rebooted = Stopwatch()..start();
    await reboot();
    await baseline();
    evidence('reconnected', {'seconds_after_reset': rebooted.elapsedMilliseconds / 1000, 'new_picks': picks - before});
    check(picks == before, 'Reconnect needed ${picks - before} new chooser selection(s)');
  }

  Future<void> run() async {
    var passed = false;
    evidence('config', config.toJson());
    final proto = (globalContext['BluetoothDevice'] as JSObject?)?['prototype'] as JSObject?;
    evidence('web_features', {'watch_advertisements': proto?.has('watchAdvertisements') ?? false});
    try {
      if (config.scenarios.any((s) => s != 'reconnect')) await loadCandidate();
      await attach();
      final installed = await active(confirmed: true);
      baselineHash = installed['hash'] as String;
      baselineVersion = installed['version'] as String;
      if (config.baseline.isNotEmpty) {
        check(baselineHash == config.baseline, 'Baseline $baselineHash, expected ${config.baseline}');
      }
      for (final scenario in config.scenarios) {
        if (scenario != 'probe' && scenario != 'reconnect') check(baselineHash != imageHash, 'Candidate is already active');
        evidence('case_start', {'case': scenario});
        try {
          await switch (scenario) {
            'probe' => probe(),
            'reconnect' => reconnect(),
            'upload' => upload(),
            'rollback' => activate(confirm: false),
            _ => activate(confirm: true),
          };
          evidence('case_pass', {'case': scenario});
        } catch (error) {
          evidence('case_fail', {'case': scenario, 'error': error.toString()});
          rethrow;
        }
      }
      passed = true;
    } catch (error, stack) {
      evidence('error', {'error': error.toString(), 'stack': stack.toString().split('\n').take(8).join('\n')});
    } finally {
      await detach();
      evidence('done', {'status': passed ? 'pass' : 'fail', 'picks': picks});
    }
  }
}

void main() {
  Config config;
  try {
    config = Config(Uri.base.queryParameters);
  } catch (error) {
    evidence('error', {'error': error.toString()});
    evidence('done', {'status': 'fail', 'picks': 0});
    runApp(const Harness());
    return;
  }
  final bench = Bench(config);
  var started = false;
  globalContext['hilStart'] =
      (() {
        if (started) return;
        started = true;
        unawaited(bench.run());
      }).toJS;
  globalContext['hilPick'] = bench.pick.toJS;
  // Manual use: the first tap opens the chooser and starts the run; later
  // taps answer re-pick requests. Both happen inside the tap's user gesture.
  onTap = () {
    if (!started) {
      bench.picking ??= Completer<String>();
      bench.pick();
      started = true;
      unawaited(bench.run());
    } else {
      bench.pick();
    }
  };
  runApp(const Harness());
  WidgetsBinding.instance.addPostFrameCallback((_) => evidence('ready'));
}

class Harness extends StatelessWidget {
  const Harness({super.key});

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: const Color(0xfff8f9fa),
      child: DefaultTextStyle(
        style: const TextStyle(color: Color(0xff212529), fontSize: 13, fontFamily: 'monospace'),
        child: ValueListenableBuilder(
          valueListenable: view,
          builder:
              (context, lines, _) => ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  GestureDetector(
                    onTap: () => onTap?.call(),
                    child: const ColoredBox(
                      color: Color(0xffd6e4fb),
                      child: Padding(padding: EdgeInsets.all(12), child: Text('Start / pick device')),
                    ),
                  ),
                  for (final line in lines) Text(line),
                ],
              ),
        ),
      ),
    ),
  );
}

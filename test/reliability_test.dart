import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_remote/core/capabilities.dart';
import 'package:universal_remote/core/remote_controller.dart';
import 'package:universal_remote/core/remote_key.dart';
import 'package:universal_remote/core/tv_device.dart';
import 'package:universal_remote/core/tv_protocol.dart';
import 'package:universal_remote/features/activity.dart';
import 'package:universal_remote/services/serial_executor.dart';
import 'package:universal_remote/services/lan_address.dart';
import 'package:universal_remote/services/wake_service.dart';
import 'package:universal_remote/storage/device_store.dart';

class MemoryVault implements TokenVault {
  final values = <String, String>{};
  bool fail = false;
  @override
  Future<String?> read(String id) async => values[id];
  @override
  Future<void> write(String id, String token) async {
    if (fail) throw StateError('locked');
    values[id] = token;
  }

  @override
  Future<void> delete(String id) async {
    values.remove(id);
  }
}

class FakeProtocol extends TvProtocol {
  FakeProtocol(super.device);
  bool connected = false, failSend = false;
  int connects = 0, sends = 0;
  final sent = <RemoteKey>[];
  @override
  Set<RemoteKey> get supportedKeys => {
    RemoteKey.power,
    RemoteKey.home,
    RemoteKey.mute,
    RemoteKey.powerOff,
  };
  @override
  bool get requiresPairing => false;
  @override
  bool get isConnected => connected;
  @override
  RemoteCapabilities get capabilities =>
      const RemoteCapabilities(acknowledgesKeys: true, audioState: true);
  bool muted = false;
  int volume = 20;
  @override
  Future<AudioState> readAudio() async =>
      AudioState(muted: muted, volume: volume);
  @override
  Future<void> setMuted(bool value) async {
    muted = value;
  }

  @override
  Future<PairingResult> pair() async {
    device = device.copyWith(pairingToken: 'test');
    return PairingResult(PairingStatus.success, device: device);
  }

  @override
  Future<void> connect() async {
    connects++;
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    connected = false;
  }

  @override
  Future<void> sendKey(RemoteKey key) async {
    sends++;
    sent.add(key);
    if (failSend) throw TimeoutException('lost reply');
  }

  @override
  Future<bool> ping() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const device = TvDevice(
    id: 'roku-test',
    name: 'Test',
    host: '192.168.1.20',
    brand: TvBrand.roku,
  );
  late DeviceStore store;
  late MemoryVault vault;
  late FakeProtocol protocol;
  late RemoteController controller;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    vault = MemoryVault();
    store = DeviceStore(await SharedPreferences.getInstance(), vault: vault);
    await store.initialize();
    protocol = FakeProtocol(device);
    controller = RemoteController(store, factory: (_) => protocol);
  });
  tearDown(() => controller.dispose());
  test('pairing opens control session before reporting connected', () async {
    await controller.pairAndSave(device);
    expect(protocol.connects, 1);
    expect(protocol.connected, true);
    expect(controller.state, RemoteConnectionState.connected);
  });
  test('uncertain power is never replayed', () async {
    await controller.pairAndSave(device);
    protocol.failSend = true;
    expect(await controller.sendKey(RemoteKey.power), false);
    expect(protocol.sends, 1);
    expect(controller.lastResult!.delivery, Delivery.uncertain);
    protocol.failSend = false;
    expect(await controller.sendKey(RemoteKey.home), true);
    expect(protocol.connects, 2);
    expect(protocol.sends, 2);
  });
  test('serial executor preserves order and survives errors', () async {
    final queue = SerialExecutor();
    final log = <int>[];
    final gate = Completer<void>();
    final a = queue.run(() async {
      await gate.future;
      log.add(1);
    });
    final b = queue.run(() async {
      log.add(2);
      throw StateError('expected');
    });
    final expected = expectLater(b, throwsStateError);
    final c = queue.run(() async {
      log.add(3);
    });
    expect(log, isEmpty);
    gate.complete();
    await a;
    await expected;
    await c;
    expect(log, [1, 2, 3]);
  });
  test('token migration writes vault then removes plaintext', () async {
    final prefs = store.preferences;
    await prefs.setStringList('paired_devices_v1', [
      '{"id":"x","name":"TV","host":"192.168.1.2","brand":"lg","pairingToken":"secret"}',
    ]);
    await store.initialize();
    expect(vault.values['x'], 'secret');
    expect(
      prefs.getStringList('paired_devices_v1')!.single,
      isNot(contains('secret')),
    );
    expect(store.loadAll().single.pairingToken, 'secret');
  });
  test('vault failure preserves legacy credential for retry', () async {
    final prefs = store.preferences;
    await prefs.setStringList('paired_devices_v1', [
      '{"id":"x","name":"TV","host":"192.168.1.2","brand":"lg","pairingToken":"secret"}',
    ]);
    vault.fail = true;
    await expectLater(store.initialize(), throwsStateError);
    expect(
      prefs.getStringList('paired_devices_v1')!.single,
      contains('secret'),
    );
  });
  test('quiet restoration skips externally changed volume', () async {
    await controller.pairAndSave(device);
    await controller.quietMoment();
    expect(protocol.muted, true);
    protocol.volume = 30;
    await controller.quietMoment();
    expect(protocol.muted, true);
    expect(controller.quietActive, false);
    expect(controller.lastResult!.delivery, Delivery.uncertain);
  });
  test('quiet restoration verifies original mute state', () async {
    await controller.pairAndSave(device);
    await controller.quietMoment();
    await controller.quietMoment();
    expect(protocol.muted, false);
    expect(controller.lastResult!.delivery, Delivery.verified);
  });
  test('cancel activity during wait prevents following key', () async {
    await controller.pairAndSave(device);
    final run = controller.runActivity(
      const Activity(
        id: 'a',
        name: 'Test',
        steps: [
          ActivityStep(deviceId: 'roku-test', kind: StepKind.wait, value: '1'),
          ActivityStep(
            deviceId: 'roku-test',
            kind: StepKind.key,
            value: 'power',
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    controller.cancelActivity();
    await run;
    expect(protocol.sends, 0);
  });
  test('background cancels foreground sleep timer', () async {
    await controller.pairAndSave(device);
    controller.scheduleSleep(const Duration(seconds: 30));
    expect(controller.sleepAt, isNotNull);
    controller.onBackground();
    expect(controller.sleepAt, isNull);
  });
  test('report does not contain credentials or network identifiers', () async {
    await controller.pairAndSave(device);
    final report = controller.compatibilityReport();
    expect(report, isNot(contains('192.168.1.20')));
    expect(report, isNot(contains('roku-test')));
    expect(report, isNot(contains('"test"')));
  });
  test('queued tap never moves to a different TV', () async {
    const other = TvDevice(
      id: 'other',
      name: 'Other TV',
      host: '192.168.1.21',
      brand: TvBrand.roku,
    );
    final otherProtocol = FakeProtocol(other);
    controller.dispose();
    controller = RemoteController(
      store,
      factory: (d) => d.id == device.id ? protocol : otherProtocol,
    );
    await controller.pairAndSave(device);
    final selecting = controller.select(other);
    final staleTap = controller.sendKey(RemoteKey.power);
    await selecting;
    expect(await staleTap, false);
    expect(otherProtocol.sends, 0);
    expect(protocol.sends, 0);
  });
  test('background invalidates commands waiting in queue', () async {
    await controller.pairAndSave(device);
    final tap = controller.sendKey(RemoteKey.power);
    controller.onBackground();
    expect(await tap, false);
    expect(protocol.sends, 0);
  });
  test('cancelled activity does not append a completed wait', () async {
    await controller.pairAndSave(device);
    final run = controller.runActivity(
      const Activity(
        id: 'cancel',
        name: 'Cancel',
        steps: [
          ActivityStep(deviceId: 'roku-test', kind: StepKind.wait, value: '1'),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    controller.cancelActivity();
    await run;
    expect(controller.activityLog, hasLength(1));
    expect(controller.activityLog.single, startsWith('Stopped.'));
  });
  test('endpoint validation rejects redirects outside device', () {
    expect(
      isDeviceEndpoint(Uri.parse('http://192.168.1.2/desc'), '192.168.1.2'),
      true,
    );
    expect(
      isDeviceEndpoint(Uri.parse('http://169.254.169.254/'), '192.168.1.2'),
      false,
    );
    expect(isPrivateV4('8.8.8.8'), false);
    expect(isPrivateV4('172.16.0.1'), true);
  });
  test('Wake packet has six FF bytes and sixteen MAC repetitions', () {
    final bytes = WakeService.packet('AA:BB:CC:DD:EE:FF');
    expect(bytes.length, 102);
    expect(bytes.take(6), List.filled(6, 255));
    expect(bytes.sublist(6, 12), [170, 187, 204, 221, 238, 255]);
    expect(() => WakeService.packet('bad'), throwsArgumentError);
  });
}

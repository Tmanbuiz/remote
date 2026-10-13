import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_remote/core/remote_controller.dart';
import 'package:universal_remote/core/remote_key.dart';
import 'package:universal_remote/core/tv_device.dart';
import 'package:universal_remote/core/tv_protocol.dart';
import 'package:universal_remote/storage/device_store.dart';
import 'package:universal_remote/ui/pairing_code_dialog.dart';

class PairingFixture extends TvProtocol {
  PairingFixture(super.device);
  int closes = 0, pins = 0;
  @override
  bool isConnected = false;
  @override
  bool get requiresPairing => true;
  @override
  Set<RemoteKey> get supportedKeys => {RemoteKey.volumeDown};
  @override
  int get pairingCodeLength => 6;
  @override
  bool get pairingCodeIsHex => true;
  @override
  Future<PairingResult> pair() async =>
      const PairingResult(PairingStatus.pinRequired);
  @override
  Future<PairingResult> submitPin(String pin) async {
    pins++;
    isConnected = true;
    device = device.copyWith(pairingToken: 'fixture-paired');
    return PairingResult(PairingStatus.success, device: device);
  }

  @override
  Future<void> connect() async {
    isConnected = true;
  }

  @override
  Future<void> disconnect() async {
    closes++;
    isConnected = false;
  }

  @override
  Future<void> sendKey(RemoteKey key) async {}
  @override
  Future<bool> ping() async => isConnected;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const tv = TvDevice(
    id: 'test',
    name: 'TV',
    host: '192.168.1.25',
    brand: TvBrand.androidTv,
  );
  test(
    'controller retains the exact pending adapter until PIN is submitted',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = await DeviceStore.open();
      final adapter = PairingFixture(tv);
      var creations = 0;
      final controller = RemoteController(
        store,
        protocolBuilder: (_) {
          creations++;
          return adapter;
        },
      );
      expect(
        (await controller.pairAndSave(tv)).status,
        PairingStatus.pinRequired,
      );
      expect(adapter.closes, 0);
      expect(controller.pairingCodeLength, 6);
      expect(controller.savedDevices, isEmpty);
      expect((await controller.submitPairingPin('A1B2C3')).isSuccess, isTrue);
      expect(creations, 1);
      expect(controller.activeDevice!.isPaired, isTrue);
      expect(store.loadAll().single.id, tv.id);
      controller.dispose();
    },
  );
  test(
    'cancel closes the pending session and saves no paired device',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = await DeviceStore.open();
      final adapter = PairingFixture(tv);
      final controller = RemoteController(
        store,
        protocolBuilder: (_) => adapter,
      );
      await controller.pairAndSave(tv);
      await controller.cancelPairing();
      expect(adapter.closes, 1);
      expect(store.loadAll(), isEmpty);
      expect((await controller.submitPairingPin('A1B2C3')).isSuccess, isFalse);
      controller.dispose();
    },
  );
  testWidgets(
    'PIN dialog accepts Android hex codes, reports retry and offers cancel',
    (tester) async {
      String? submitted;
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<PairingResult>(
                  context: context,
                  builder: (_) => PairingCodeDialog(
                    tvName: 'TV',
                    length: 6,
                    hex: true,
                    submit: (pin) async {
                      submitted = pin;
                      attempts++;
                      return const PairingResult(
                        PairingStatus.pinRequired,
                        message: 'Check the TV code',
                      );
                    },
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'a1b2c3');
      await tester.pump();
      await tester.tap(find.text('Pair'));
      await tester.pumpAndSettle();
      expect(submitted, 'A1B2C3');
      expect(attempts, 1);
      expect(find.text('Check the TV code'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(PairingCodeDialog), findsNothing);
    },
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:universal_remote/core/remote_key.dart';
import 'package:universal_remote/core/tv_device.dart';
import 'package:universal_remote/core/tv_protocol.dart';
import 'package:universal_remote/protocols/roku_protocol.dart';

void main() {
  group('RemoteKey', () {
    test('digit() maps 0-9 onto the digit constants', () {
      expect(RemoteKey.digit(0), RemoteKey.digit0);
      expect(RemoteKey.digit(7), RemoteKey.digit7);
      expect(RemoteKey.digit(9), RemoteKey.digit9);
    });

    test('digitValue round-trips, and is null for non-digits', () {
      for (var n = 0; n <= 9; n++) {
        expect(RemoteKey.digit(n).digitValue, n);
      }
      expect(RemoteKey.power.isDigit, isFalse);
      expect(RemoteKey.power.digitValue, isNull);
    });
  });

  group('TvDevice', () {
    const device = TvDevice(
      id: 'samsung-abc',
      name: 'Living Room',
      host: '192.168.1.40',
      brand: TvBrand.samsung,
      port: 8002,
      pairingToken: 'tok-123',
    );

    test('survives a JSON round-trip with its pairing token intact', () {
      final restored = TvDevice.fromJson(device.toJson());
      expect(restored.id, device.id);
      expect(restored.brand, TvBrand.samsung);
      expect(restored.pairingToken, 'tok-123');
      expect(restored.isPaired, isTrue);
    });

    test('an unknown brand string degrades instead of throwing', () {
      final json = device.toJson()..['brand'] = 'toshiba';
      expect(TvDevice.fromJson(json).brand, TvBrand.unknown);
    });

    test('is unpaired when the token is absent or empty', () {
      const noToken = TvDevice(
        id: 'x',
        name: 'x',
        host: 'x',
        brand: TvBrand.roku,
      );
      expect(noToken.isPaired, isFalse);
      expect(noToken.copyWith().isPaired, isFalse);
    });
  });

  group('RokuProtocol', () {
    const device = TvDevice(
      id: 'roku-1',
      name: 'Roku',
      host: '10.0.0.5',
      brand: TvBrand.roku,
    );

    test('sends the ECP key name as a POST to /keypress/<Name>', () async {
      final requests = <http.Request>[];
      final client = MockClient((req) async {
        requests.add(req);
        return http.Response('', 200);
      });

      final roku = RokuProtocol(device, client: client);
      await roku.sendKey(RemoteKey.volumeUp);

      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
      expect(
        requests.single.url.toString(),
        'http://10.0.0.5:8060/keypress/VolumeUp',
      );
    });

    test('refuses a key it has no mapping for', () async {
      final roku = RokuProtocol(
        device,
        client: MockClient((_) async => http.Response('', 200)),
      );
      expect(
        () => roku.sendKey(RemoteKey.red),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('sendText emits one Lit_ request per character, URL-encoded', () async {
      final urls = <String>[];
      final client = MockClient((req) async {
        urls.add(req.url.toString());
        return http.Response('', 200);
      });

      await RokuProtocol(device, client: client).sendText('a b');

      expect(urls, [
        'http://10.0.0.5:8060/keypress/Lit_a',
        'http://10.0.0.5:8060/keypress/Lit_%20',
        'http://10.0.0.5:8060/keypress/Lit_b',
      ]);
    });

    test('a non-2xx reply becomes a transport exception', () async {
      final roku = RokuProtocol(
        device,
        client: MockClient((_) async => http.Response('nope', 503)),
      );
      expect(
        () => roku.sendKey(RemoteKey.home),
        throwsA(isA<RemoteTransportException>()),
      );
    });

    test('pair() reads the device name and model out of the ECP XML', () async {
      const xml = '''
<device-info>
  <serial-number>SN12345</serial-number>
  <user-device-name>Bedroom TV</user-device-name>
  <model-name>Roku Express</model-name>
  <wifi-mac>aa:bb:cc:dd:ee:ff</wifi-mac>
</device-info>''';

      final roku = RokuProtocol(
        device,
        client: MockClient((_) async => http.Response(xml, 200)),
      );

      final result = await roku.pair();
      expect(result.isSuccess, isTrue);
      expect(result.device!.name, 'Bedroom TV');
      expect(result.device!.model, 'Roku Express');
      expect(result.device!.macAddress, 'aa:bb:cc:dd:ee:ff');
      // Roku needs no token, but must still read as paired to the UI.
      expect(result.device!.isPaired, isTrue);
    });

    test('pair() fails cleanly when nothing answers on 8060', () async {
      final roku = RokuProtocol(
        device,
        client: MockClient((_) async => http.Response('', 404)),
      );
      final result = await roku.pair();
      expect(result.isSuccess, isFalse);
      expect(result.status, PairingStatus.failed);
    });
  });
}

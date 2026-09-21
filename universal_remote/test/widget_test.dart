import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:universal_remote/core/remote_key.dart';
import 'package:universal_remote/core/tv_device.dart';
import 'package:universal_remote/core/tv_protocol.dart';
import 'package:universal_remote/protocols/roku_ecp2_session.dart';
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

  group('ECP-2 authentication', () {
    // The load-bearing test in this file. This challenge/response pair was
    // captured from a real official-app handshake, so it pins both the SHA-1
    // construction and the exact AUTH_KEY bytes. If this passes, the Dart port
    // authenticates byte-for-byte like the Java original that is known to work
    // against real hardware.
    test('matches the captured handshake vector', () {
      expect(
        RokuEcp2Session.authResponseFor('3KwH7h3HTmxFziLtrzVg5w=='),
        '6yYiyDKcbca3qwig1hylU0dHqUQ=',
      );
    });

    test('a different challenge produces a different response', () {
      expect(
        RokuEcp2Session.authResponseFor('AAAAAAAAAAAAAAAAAAAAAA=='),
        isNot('6yYiyDKcbca3qwig1hylU0dHqUQ='),
      );
    });
  });

  group('ECP-2 status handling', () {
    // Power keys answer 202, so a 200-only check makes the power button look
    // broken when the TV actually obeyed it.
    test('accepts any 2xx, rejects everything else', () {
      expect(RokuEcp2Session.accepted('200'), isTrue);
      expect(RokuEcp2Session.accepted('202'), isTrue);
      expect(RokuEcp2Session.accepted('204'), isTrue);
      expect(RokuEcp2Session.accepted('400'), isFalse);
      expect(RokuEcp2Session.accepted('403'), isFalse);
      expect(RokuEcp2Session.accepted(null), isFalse);
      expect(RokuEcp2Session.accepted('OK'), isFalse);
      expect(RokuEcp2Session.accepted(''), isFalse);
    });
  });

  group('Channel ids', () {
    test('accepts streaming ids and TV inputs, rejects junk', () {
      expect(RokuEcp2Session.isChannelId('12'), isTrue);
      expect(RokuEcp2Session.isChannelId('tvinput.hdmi1'), isTrue);
      expect(RokuEcp2Session.isChannelId('some-id_9'), isTrue);
      expect(RokuEcp2Session.isChannelId(''), isFalse);
      expect(RokuEcp2Session.isChannelId(null), isFalse);
      expect(RokuEcp2Session.isChannelId('bad id'), isFalse);
      expect(RokuEcp2Session.isChannelId('../etc'), isFalse);
      expect(RokuEcp2Session.isChannelId('x' * 41), isFalse);
    });
  });

  group('Channel list parsing', () {
    const realistic = '''
<apps>
  <app id="12" type="appl" version="5.1.9">Netflix</app>
  <app id="13" type="appl" version="13.1.2">Prime Video</app>
  <app id="837" type="appl" version="2.7.1">YouTube</app>
  <app id="tvinput.hdmi1" type="tvin" version="1.0.0">HDMI 1</app>
</apps>''';

    test('reads ids, names and input flags', () {
      final channels = RokuEcp2Session.parseChannels(realistic);
      expect(channels, hasLength(4));
      expect(channels[0].id, '12');
      expect(channels[0].name, 'Netflix');
      expect(channels[0].isInput, isFalse);
      expect(channels.last.id, 'tvinput.hdmi1');
      expect(channels.last.name, 'HDMI 1');
      expect(channels.last.isInput, isTrue);
    });

    test('normalises the non-breaking spaces Roku pads names with', () {
      final channels = RokuEcp2Session.parseChannels(
        '<apps><app id="1" type="appl">Prime Video</app></apps>',
      );
      expect(channels.single.name, 'Prime Video');
    });

    test('rejects a document that is not a channel list', () {
      expect(
        () => RokuEcp2Session.parseChannels('<html><body>nope</body></html>'),
        throwsA(isA<RemoteTransportException>()),
      );
    });

    // This input arrives base64-wrapped over the network; a doctype is the
    // entity-expansion vector and no real TV sends one.
    test('refuses an inline DOCTYPE', () {
      expect(
        () => RokuEcp2Session.parseChannels(
          '<!DOCTYPE apps [<!ENTITY x "boom">]><apps></apps>',
        ),
        throwsA(isA<RemoteTransportException>()),
      );
    });

    test('skips entries with an unusable id', () {
      final channels = RokuEcp2Session.parseChannels(
        '<apps><app id="bad id" type="appl">Nope</app>'
        '<app id="99" type="appl">Fine</app></apps>',
      );
      expect(channels, hasLength(1));
      expect(channels.single.id, '99');
    });
  });

  group('RokuProtocol discovery over HTTP', () {
    const device = TvDevice(
      id: 'roku-1',
      name: 'Roku',
      host: '10.0.0.5',
      brand: TvBrand.roku,
    );

    // device-info stays readable even when "Control by mobile apps" is Limited,
    // which is exactly why discovery still uses HTTP while commands do not.
    test('pair() reads the name and model out of the ECP XML', () async {
      const xml = '''
<device-info>
  <serial-number>SN12345</serial-number>
  <user-device-name>Bedroom TV</user-device-name>
  <model-name>TCL Roku TV</model-name>
  <wifi-mac>aa:bb:cc:dd:ee:ff</wifi-mac>
</device-info>''';

      final roku = RokuProtocol(
        device,
        client: MockClient((_) async => http.Response(xml, 200)),
      );

      final result = await roku.pair();
      expect(result.isSuccess, isTrue);
      expect(result.device!.name, 'Bedroom TV');
      expect(result.device!.model, 'TCL Roku TV');
      expect(result.device!.macAddress, 'aa:bb:cc:dd:ee:ff');
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

    test('ping() reports reachability from device-info', () async {
      final up = RokuProtocol(
        device,
        client: MockClient((_) async => http.Response('<device-info/>', 200)),
      );
      expect(await up.ping(), isTrue);

      final down = RokuProtocol(
        device,
        client: MockClient((_) async => http.Response('', 500)),
      );
      expect(await down.ping(), isFalse);
    });

    test('refuses a key it has no mapping for', () {
      final roku = RokuProtocol(
        device,
        client: MockClient((_) async => http.Response('', 200)),
      );
      expect(
        () => roku.sendKey(RemoteKey.red),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('commands fail closed when no ECP-2 session is open', () {
      final roku = RokuProtocol(
        device,
        client: MockClient((_) async => http.Response('', 200)),
      );
      expect(roku.isConnected, isFalse);
      expect(
        () => roku.sendKey(RemoteKey.home),
        throwsA(isA<RemoteTransportException>()),
      );
    });
  });
}

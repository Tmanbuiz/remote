import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_remote/core/protocol_factory.dart';
import 'package:universal_remote/core/remote_key.dart';
import 'package:universal_remote/core/tv_device.dart';
import 'package:universal_remote/discovery/platform_discovery.dart';
import 'package:universal_remote/protocols/android_tv_protocol.dart';
import 'package:universal_remote/protocols/android_tv_wire.dart';
import 'package:universal_remote/protocols/protobuf_wire.dart';
import 'package:universal_remote/protocols/tv_certificate.dart';
import 'package:universal_remote/protocols/vidaa_protocol.dart';
import 'package:universal_remote/protocols/vidaa_wire.dart';

void main() {
  group('Android TV wire interoperability', () {
    test('VolumeDown matches the Remote v2 short-key protobuf packet', () {
      expect(AndroidTvWire.key(25), [0x52, 4, 8, 25, 16, 3]);
    });
    test('pairing options negotiate six hexadecimal symbols as input', () {
      expect(AndroidTvWire.pairingOptions(),
        [8, 2, 16, 200, 1, 162, 1, 8, 10, 4, 8, 3, 16, 6, 24, 1]);
    });
    test('PIN secret matches independent Python/cryptography fixture', () {
      final client = File('test/fixtures/android-client.pem').readAsStringSync();
      final server = File('test/fixtures/android-server.pem').readAsStringSync();
      final secret = AndroidTvWire.secret('beb34c', client, server);
      expect(secret.map((x) => x.toRadixString(16).padLeft(2, '0')).join(),
        'beff893cf9c77d16547e2a04fb9f2014508dbaa8fddc0c33665f9ab3b2d2bf97');
      expect(certificateRsa(client).modulus.bitLength, 2048);
    });
    test('wrong TV/code checksum is rejected before transmitting a secret', () {
      final client = File('test/fixtures/android-client.pem').readAsStringSync();
      final server = File('test/fixtures/android-server.pem').readAsStringSync();
      expect(() => AndroidTvWire.secret('00B34C', client, server), throwsFormatException);
      expect(() => AndroidTvWire.secret('12345Z', client, server), throwsFormatException);
    });
    test('frames handle split varint, split payload and coalesced messages', () {
      final parser = ProtoFrames();
      final large = List<int>.filled(130, 7);
      final framed = Proto.frame(large);
      expect(parser.add(framed.sublist(0, 1)), isEmpty);
      expect(parser.add(framed.sublist(1, 17)), isEmpty);
      final received = parser.add([...framed.sublist(17), ...Proto.frame([8, 1])]);
      expect(received, [large, [8, 1]]);
    });
    test('oversized frames and truncated protobuf fields are rejected', () {
      expect(() => ProtoFrames().add(Proto.varint(ProtoFrames.maximumSize + 1)), throwsFormatException);
      expect(() => ProtoFrames().add([128, 128, 128, 128, 128]), throwsFormatException);
      expect(() => Proto.decode([10, 5, 1]), throwsFormatException);
      expect(() => Proto.decode([0]), throwsFormatException);
    });
    test('text uses TV IME counters and preserves Unicode', () {
      final fields = Proto.nested(Proto.decode(AndroidTvWire.text('Dára', 12, 4)), 21);
      expect(Proto.integer(fields, 1), 12);
      expect(Proto.integer(fields, 2), 4);
      final edit = Proto.nested(fields, 3);
      expect(Proto.string(Proto.nested(edit, 2), 3), 'Dára');
    });
  });

  group('VIDAA firmware profiles', () {
    test('transport version selects legacy, middle and modern boundaries', () {
      expect(VidaaWire.profile(2999), VidaaProfile.legacy);
      expect(VidaaWire.profile(3000), VidaaProfile.middle);
      expect(VidaaWire.profile(3289), VidaaProfile.middle);
      expect(VidaaWire.profile(3290), VidaaProfile.modern);
      expect(VidaaWire.profile(null), VidaaProfile.modern);
    });
    test('credentials match independently computed upstream vectors', () {
      const uuid = '02:12:34:56:78:90';
      for (final profile in VidaaProfile.values) {
        final c = VidaaWire.credentials(uuid, profile, 1700000000);
        expect(c.clientId, r'02:12:34:56:78:90$his$52A0DF_vidaacommon_001');
        expect(c.username, profile == VidaaProfile.legacy
          ? r'his$1700000000' : r'his$6239759786369374312');
        expect(c.password, profile == VidaaProfile.modern
          ? 'E4B16BE39DA56468522CACF7411FB50F' : '30CC23251954D2B965504DC81E944805');
      }
    });
    test('PIN is a JSON integer and success must be an explicit result', () {
      expect(VidaaWire.pinPayload('0012'), '{"authNum":12}');
      expect(() => VidaaWire.pinPayload('12'), throwsFormatException);
      expect(VidaaWire.pinAccepted({'result': 1}), isTrue);
      expect(VidaaWire.pinAccepted({'result': 0}), isFalse);
      expect(VidaaWire.pinAccepted({'result': '1'}), isFalse);
      expect(VidaaWire.pinAccepted(null), isFalse);
    });
    test('token expiry uses issuance time and firmware durations', () {
      final tokens = VidaaWire.tokens({'accesstoken': 'test-token',
        'accesstoken_time': 1700000000, 'accesstoken_duration_day': 7}, DateTime.utc(2026));
      expect(tokens!['accessExpiresAt'], 1700604800000);
      expect(VidaaWire.tokens({'refreshtoken': 'no-access'}, DateTime.utc(2026)), isNull);
    });
    test('relative volume commands use the platform key names', () {
      expect(VidaaProtocol.keyNames[RemoteKey.volumeDown], 'KEY_VOLUMEDOWN');
      expect(AndroidTvProtocol.keyCodes[RemoteKey.volumeDown], 25);
      expect(VidaaProtocol.keyNames.containsKey(RemoteKey.powerOn), isFalse);
    });
  });

  group('platform identification and saved compatibility information', () {
    test('descriptor finds transport versions from XML fields or descriptions', () {
      const xml = '<root><device><manufacturer>Hisense</manufacturer><UDN>uuid:tv</UDN>'
        '<friendlyName>Living room</friendlyName><modelName>58 TV</modelName>'
        '<modelDescription>transport_protocol=3293</modelDescription>'
        '<softwareVersion>V100.09.60M.Q0611</softwareVersion></device></root>';
      final tv = PlatformDiscovery.vidaaDescriptor(xml, '192.168.1.25')!;
      expect(tv.brand, TvBrand.vidaa);
      expect(tv.protocolVersion, 3293);
      expect(tv.firmwareVersion, 'V100.09.60M.Q0611');
      expect(tv.id, 'uuid:tv');
      expect(PlatformDiscovery.vidaaDescriptor(
        '<root><transport_protocol>3000</transport_protocol></root>', '192.168.1.25')!.protocolVersion, 3000);
      expect(PlatformDiscovery.vidaaDescriptor('<root><manufacturer>Printer</manufacturer></root>', '192.168.1.25'), isNull);
    });
    test('manual address validation explains URLs, ports and multicast', () {
      expect(PlatformDiscovery.host(' 192.168.1.25 '), '192.168.1.25');
      for (final bad in ['http://192.168.1.25', '192.168.1.25:8060', '239.0.0.1', '']) {
        expect(() => PlatformDiscovery.host(bad), throwsFormatException);
      }
    });
    test('old TV records remain readable; firmware is retained after rename', () {
      final old = TvDevice.fromJson({'id': 'r', 'name': 'TV', 'host': '192.168.1.25', 'brand': 'roku'});
      expect(old.firmwareVersion, isNull);
      final newTv = old.copyWith(firmwareVersion: 'Q0611', protocolVersion: 3290);
      expect(TvDevice.fromJson(newTv.copyWith(nickname: 'Room').toJson()).firmwareVersion, 'Q0611');
      expect(newTv.copyWith(pairingToken: 'marker').copyWith(clearPairingToken: true).isPaired, isFalse);
    });
    test('both new platforms have adapters; unrelated unsupported brands stay unsupported', () {
      expect(ProtocolFactory.supported, containsAll([TvBrand.androidTv, TvBrand.vidaa]));
      expect(ProtocolFactory.supported, isNot(contains(TvBrand.appleTv)));
    });
  });
}

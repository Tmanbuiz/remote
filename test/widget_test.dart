import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_remote/core/home_monitor.dart';
import 'package:universal_remote/protocols/mic_monitor.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:universal_remote/core/remote_key.dart';
import 'package:universal_remote/protocols/audio_relay.dart';
import 'package:universal_remote/protocols/private_listening.dart';
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

  group('TV inputs', () {
    // Verified against a TCL Roku TV: `launch` with a tvinput.* id answers 403
    // Forbidden and the TV does not switch, while `key-press InputHDMI1`
    // answers 200 and it does. query-apps lists inputs and channels together
    // with nothing to distinguish how they must be selected.
    test('maps HDMI inputs onto their key names', () {
      expect(RokuEcp2Session.inputKeyFor('tvinput.hdmi1'), 'InputHDMI1');
      expect(RokuEcp2Session.inputKeyFor('tvinput.hdmi2'), 'InputHDMI2');
      expect(RokuEcp2Session.inputKeyFor('tvinput.hdmi4'), 'InputHDMI4');
    });

    test('maps the tuner and composite inputs', () {
      expect(RokuEcp2Session.inputKeyFor('tvinput.tuner'), 'InputTuner');
      expect(RokuEcp2Session.inputKeyFor('tvinput.dtv'), 'InputTuner');
      expect(RokuEcp2Session.inputKeyFor('tvinput.av1'), 'InputAV1');
    });

    test('returns null for real channels, which launch normally', () {
      expect(RokuEcp2Session.inputKeyFor('12'), isNull);
      expect(RokuEcp2Session.inputKeyFor('837'), isNull);
    });

    test('returns null for an input it does not recognise', () {
      expect(RokuEcp2Session.inputKeyFor('tvinput.hdmi9'), isNull);
      expect(RokuEcp2Session.inputKeyFor('tvinput.mystery'), isNull);
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
group('Renaming a TV', () {
    const reported = TvDevice(
      id: 'serial-1',
      name: '70" Hisense Roku TV',
      host: '10.0.0.213',
      brand: TvBrand.roku,
    );

    test('displayName falls back to the name the set reports', () {
      expect(reported.displayName, '70" Hisense Roku TV');
    });

    test('a nickname takes precedence, trimmed', () {
      final named = reported.copyWith(nickname: '  living room TV  ');
      expect(named.displayName, 'living room TV');
      // The reported name is kept, not overwritten.
      expect(named.name, '70" Hisense Roku TV');
    });

    test('whitespace alone is not a name', () {
      expect(reported.copyWith(nickname: '   ').displayName, '70" Hisense Roku TV');
    });

    test('clearNickname restores the reported name', () {
      final named = reported.copyWith(nickname: 'bedroom TV');
      expect(named.copyWith(clearNickname: true).displayName, '70" Hisense Roku TV');
    });

    test('copyWith leaves an existing nickname alone', () {
      final named = reported.copyWith(nickname: 'bedroom TV');
      expect(named.copyWith(host: '10.0.0.9').displayName, 'bedroom TV');
    });

    test('the nickname survives a JSON round trip', () {
      final named = reported.copyWith(nickname: 'family room');
      expect(TvDevice.fromJson(named.toJson()).displayName, 'family room');
    });

    test('a record saved before renaming existed still loads', () {
      final legacy = {
        'id': 'serial-1',
        'name': '43" Hisense Roku TV',
        'host': '10.0.0.152',
        'brand': 'roku',
      };
      expect(TvDevice.fromJson(legacy).displayName, '43" Hisense Roku TV');
    });
  });
group('Audio relay', () {
    test('the relay and a direct listener agree on the RTP port', () {
      // The TV only ever sends to this port, so the relay has to claim the
      // same one the direct path uses.
      expect(AudioRelay.rtpPort, PrivateListening.rtpPort);
    });

    test('registration does not collide with audio', () {
      expect(AudioRelay.controlPort, isNot(AudioRelay.rtpPort));
    });

    test('a relay forwards nothing until someone registers', () async {
      final relay = AudioRelay();
      expect(relay.isRunning, isFalse);
      expect(relay.hasListener, isFalse);
      expect(relay.packetsForwarded, 0);
      expect(relay.lanEndpoint, isNull);
      // Stopping one that never started is what a cancelled toggle does.
      await relay.stop();
      expect(relay.isRunning, isFalse);
    });

    test('relaying off this phone needs this phone on the TV network', () async {
      final relay = AudioRelay();
      await expectLater(
        relay.start('203.0.113.10'),
        throwsA(isA<StateError>()),
      );
    });

    test('the keepalive packets are the ones the TV accepts', () {
      // Built by the relay from the same helpers the direct path uses, so a
      // change to one can never silently diverge from the other.
      expect(PrivateListening.buildApp('VDLY', 500000).length, 16);
      expect(PrivateListening.buildReceiverReport().length, 32);
      expect(PrivateListening.buildReceiverReport()[1], 201);
    });
  });

  group('Listen to home framing', () {
    Uint8List pcmBytes(List<int> samples) {
      final data = ByteData(samples.length * 2);
      for (var i = 0; i < samples.length; i++) {
        data.setInt16(i * 2, samples[i], Endian.little);
      }
      return data.buffer.asUint8List();
    }

    test('a 20 ms frame at 16 kHz is 320 samples and 960 RTP ticks', () {
      // Opus RTP always runs a 48 kHz clock, whatever rate was encoded.
      expect(MicStream.frameSamples, 320);
      expect(MicStream.rtpTimestampStep, 960);
    });

    test('the framer emits only complete frames and carries the rest', () {
      final framer = PcmFramer(frameSamples: 4);
      expect(framer.add(pcmBytes([1, 2, 3])), isEmpty);
      expect(framer.buffered, 3);

      final frames = framer.add(pcmBytes([4, 5, 6, 7, 8, 9]));
      expect(frames.map((f) => f.toList()), [
        [1, 2, 3, 4],
        [5, 6, 7, 8],
      ]);
      expect(framer.buffered, 1);
    });

    test('a sample split across two chunks is rejoined, signs intact', () {
      final framer = PcmFramer(frameSamples: 2);
      final bytes = pcmBytes([-2, 300]);
      // Cut through the middle of the second sample.
      expect(framer.add(bytes.sublist(0, 3)), isEmpty);
      final frames = framer.add(bytes.sublist(3));
      expect(frames.single.toList(), [-2, 300]);
    });

    test('RTP built by the talker is read back by the listener', () {
      final packetizer = RtpPacketizer(ssrc: 0xDEADBEEF);
      final payload = Uint8List.fromList(List.generate(40, (i) => i + 1));
      final packet = packetizer.wrap(payload);

      expect(packet.length, 52);
      expect(packet[0] >> 6, 2); // RTP version
      expect(packet[1] & 0x7F, MicStream.payloadType);
      // The listener's parser treats the marker bit as padding, so it must
      // never be set or the Opus frame would be trimmed.
      expect(packet[1] & 0x80, 0);
      expect(PrivateListening.rtpPayload(packet), payload);
    });

    test('sequence and timestamp advance by one frame per packet', () {
      final packetizer = RtpPacketizer(ssrc: 1);
      final first = packetizer.wrap(Uint8List(3));
      final second = packetizer.wrap(Uint8List(3));
      expect(RtpPacketizer.sequenceOf(second), RtpPacketizer.sequenceOf(first) + 1);
      expect(packetizer.nextTimestamp, 2 * MicStream.rtpTimestampStep);
    });

    test('sequence and timestamp wrap instead of overflowing', () {
      final packetizer = RtpPacketizer(ssrc: 1, sequence: 0xFFFF, timestamp: 0xFFFFFFFF);
      packetizer.wrap(Uint8List(1));
      expect(packetizer.nextSequence, 0);
      expect(packetizer.nextTimestamp, MicStream.rtpTimestampStep - 1);
    });

    test('stale and duplicate packets are not newer, wrap-around is', () {
      expect(RtpPacketizer.isNewer(5, null), isTrue);
      expect(RtpPacketizer.isNewer(6, 5), isTrue);
      expect(RtpPacketizer.isNewer(5, 5), isFalse);
      expect(RtpPacketizer.isNewer(4, 5), isFalse);
      expect(RtpPacketizer.isNewer(0, 0xFFFF), isTrue);
    });

    test('the talker announces the format the listener will decode', () {
      final format = MicStream.parseAnnouncement(MicStream.announcement);
      expect(format?.sampleRate, 16000);
      expect(format?.channels, 1);
    });

    test('anything that is not an announcement is ignored', () {
      expect(MicStream.parseAnnouncement('URRELAY1'), isNull);
      expect(MicStream.parseAnnouncement('192.168.1.5:6970'), isNull);
      expect(MicStream.parseAnnouncement('URMIC001:abc:1'), isNull);
      expect(MicStream.parseAnnouncement('URMIC001:16000:9'), isNull);
    });

    test('the monitor never collides with the TV relay', () {
      expect(MicStream.controlPort, isNot(AudioRelay.controlPort));
      expect(MicStream.controlPort, isNot(AudioRelay.rtpPort));
      expect(MicStream.hello, isNot(AudioRelay.hello));
    });

    test('the notification says whether anyone is listening', () {
      expect(
        HomeMonitor.notificationText(hasListener: true),
        'Microphone on — streaming to your other device',
      );
      expect(
        HomeMonitor.notificationText(hasListener: false),
        contains('waiting'),
      );
    });
  });

  group('Listen to home handshake', () {
    // The real Opus library only exists inside a built app, so the encoder is
    // replaced by one that tags each frame with its first sample. Everything
    // else — sockets, registration, framing, RTP — is the real thing.
    Uint8List fakeOpus(Int16List pcm) =>
        Uint8List.fromList([pcm.first & 0xFF, (pcm.first >> 8) & 0xFF, 0xAA]);

    Uint8List frameOf(int value) {
      final data = ByteData(MicStream.frameSamples * 2);
      for (var i = 0; i < MicStream.frameSamples; i++) {
        data.setInt16(i * 2, value, Endian.little);
      }
      return data.buffer.asUint8List();
    }

    late MicTalker talker;
    late StreamController<Uint8List> mic;
    late RawDatagramSocket client;
    late List<Uint8List> received;

    setUp(() async {
      mic = StreamController<Uint8List>();
      talker = MicTalker(
        controlPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        encoder: fakeOpus,
      );
      await talker.start(mic.stream);
      client = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      received = [];
      client.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = client.receive();
        if (datagram != null) received.add(datagram.data);
      });
    });

    tearDown(() async {
      client.close();
      await talker.stop();
      await mic.close();
    });

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 80));

    test('a talker sends nothing until someone registers', () async {
      expect(talker.hasListener, isFalse);
      mic.add(frameOf(7));
      await settle();
      expect(talker.packetsSent, 0);
      expect(received, isEmpty);
    });

    test('registering is answered with the stream format', () async {
      client.send(MicStream.hello.codeUnits, InternetAddress.loopbackIPv4, talker.boundPort);
      await settle();

      expect(talker.hasListener, isTrue);
      expect(String.fromCharCodes(received.single), MicStream.announcement);
    });

    test('a stranger\'s datagram does not register anyone', () async {
      client.send('hello?'.codeUnits, InternetAddress.loopbackIPv4, talker.boundPort);
      client.send(AudioRelay.hello.codeUnits, InternetAddress.loopbackIPv4, talker.boundPort);
      await settle();

      expect(talker.hasListener, isFalse);
      expect(received, isEmpty);
    });

    test('once registered, microphone frames arrive as ordered RTP', () async {
      client.send(MicStream.hello.codeUnits, InternetAddress.loopbackIPv4, talker.boundPort);
      await settle();
      received.clear();

      mic.add(frameOf(11));
      mic.add(frameOf(22));
      await settle();

      expect(talker.packetsSent, 2);
      expect(received, hasLength(2));
      final first = received[0];
      final second = received[1];
      expect(RtpPacketizer.sequenceOf(second), RtpPacketizer.sequenceOf(first) + 1);
      // The payload the listener would hand to its Opus decoder.
      expect(PrivateListening.rtpPayload(first), [11, 0, 0xAA]);
      expect(PrivateListening.rtpPayload(second), [22, 0, 0xAA]);
    });

    test('chunks that straddle frames still produce whole frames', () async {
      client.send(MicStream.hello.codeUnits, InternetAddress.loopbackIPv4, talker.boundPort);
      await settle();
      received.clear();

      final bytes = frameOf(5);
      mic.add(bytes.sublist(0, 101));
      mic.add(bytes.sublist(101));
      await settle();

      expect(received, hasLength(1));
    });

    test('stopping closes the port and forgets the listener', () async {
      client.send(MicStream.hello.codeUnits, InternetAddress.loopbackIPv4, talker.boundPort);
      await settle();
      expect(talker.hasListener, isTrue);

      await talker.stop();
      expect(talker.isRunning, isFalse);
      expect(talker.hasListener, isFalse);
      expect(talker.boundPort, 0);
    });

    test('an idle listener reports nothing heard', () async {
      // Registering needs the native Opus library, so the unreachable-talker
      // path is covered by the on-device smoke test; this checks idle state.
      final listener = MicListener();
      expect(listener.isRunning, isFalse);
      expect(listener.isHearing, isFalse);
      await listener.stop();
    });
  });
}

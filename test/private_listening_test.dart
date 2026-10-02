import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_remote/protocols/private_listening.dart';

/// Builds an RTP packet so the header parsing can be exercised without a TV.
Uint8List rtp({
  int version = 2,
  int csrcCount = 0,
  bool extension = false,
  int extensionWords = 0,
  int paddingBytes = 0,
  List<int> payload = const [1, 2, 3, 4],
}) {
  final bytes = <int>[];
  var first = (version << 6) | csrcCount;
  if (extension) first |= 0x10;
  bytes.add(first);
  bytes.add(paddingBytes > 0 ? 0x80 : 0x00);
  bytes.addAll(List.filled(10, 0)); // sequence, timestamp, ssrc
  bytes.addAll(List.filled(csrcCount * 4, 0));
  if (extension) {
    bytes.addAll([0, 0, (extensionWords >> 8) & 0xFF, extensionWords & 0xFF]);
    bytes.addAll(List.filled(extensionWords * 4, 0));
  }
  bytes.addAll(payload);
  if (paddingBytes > 0) {
    bytes.addAll(List.filled(paddingBytes - 1, 0));
    bytes.add(paddingBytes);
  }
  return Uint8List.fromList(bytes);
}

void main() {
  group('RTP payload extraction', () {
    test('strips the 12-byte header', () {
      expect(PrivateListening.rtpPayload(rtp()), [1, 2, 3, 4]);
    });

    test('accepts the maximum 15 CSRC entries', () {
      expect(PrivateListening.rtpPayload(rtp(csrcCount: 15)), [1, 2, 3, 4]);
    });

    test('accounts for CSRC entries', () {
      expect(PrivateListening.rtpPayload(rtp(csrcCount: 3)), [1, 2, 3, 4]);
    });

    test('skips a header extension', () {
      expect(
        PrivateListening.rtpPayload(rtp(extension: true, extensionWords: 2)),
        [1, 2, 3, 4],
      );
    });

    test('removes trailing padding', () {
      expect(PrivateListening.rtpPayload(rtp(paddingBytes: 4)), [1, 2, 3, 4]);
    });

    // Any broadcast-heavy network delivers stray datagrams to an open port;
    // these must be dropped rather than fed to the decoder.
    test('rejects malformed or foreign datagrams', () {
      expect(PrivateListening.rtpPayload(Uint8List.fromList([1, 2, 3])), isNull);
      expect(PrivateListening.rtpPayload(rtp(version: 1)), isNull);
      // 15 CSRCs is legal, so the invalid case is one that claims them
      // without carrying them.
      expect(
        PrivateListening.rtpPayload(
          Uint8List.fromList([0x8F, 0x00, ...List.filled(10, 0)]),
        ),
        isNull,
      );
      // Claims a 99-word extension without carrying one.
      expect(
        PrivateListening.rtpPayload(
          Uint8List.fromList([0x90, 0x00, ...List.filled(10, 0), 0, 0, 0, 99]),
        ),
        isNull,
      );
    });

    test('rejects padding that would consume the payload', () {
      final bad = Uint8List.fromList([0x80, 0x80, ...List.filled(10, 0), 99]);
      expect(PrivateListening.rtpPayload(bad), isNull);
    });
  });

  group('RTCP keepalive packets', () {
    // These must match the reference client byte for byte. The identifier is
    // zero rather than our own SSRC, and the report carries no reception data.
    test('APP packet carries a zero identifier, name and value', () {
      final packet = PrivateListening.buildApp('VDLY', 500000);
      expect(packet.length, 16);
      expect(packet[0], 0x80, reason: 'version 2, no padding, subtype 0');
      expect(packet[1], 204, reason: 'packet type 204 is APP');
      expect((packet[2] << 8) | packet[3], 3, reason: '4 words minus one');
      expect(packet.sublist(4, 8), [0, 0, 0, 0], reason: 'identifier is zero');
      expect(String.fromCharCodes(packet.sublist(8, 12)), 'VDLY');
      expect(packet.sublist(12, 16), [0x00, 0x07, 0xA1, 0x20]);
    });

    test('CVER carries the client version the TV expects', () {
      final packet = PrivateListening.buildApp('CVER', 808464434);
      expect(String.fromCharCodes(packet.sublist(8, 12)), 'CVER');
      // 808464434 is 0x30303032, which is the ASCII text "0002" — the client
      // version as a string, which is why the TV reports client-versions as one.
      expect(packet.sublist(12, 16), [0x30, 0x30, 0x30, 0x32]);
      expect(String.fromCharCodes(packet.sublist(12, 16)), '0002');
    });

    test('the receiver report is the fixed 32-byte packet', () {
      final report = PrivateListening.buildReceiverReport();
      expect(report.length, 32);
      expect(report[0], 0x81, reason: 'version 2, one report block');
      expect(report[1], 201, reason: 'packet type 201 is a receiver report');
      expect((report[2] << 8) | report[3], 7, reason: '8 words minus one');
      expect(report.sublist(4), everyElement(0), reason: 'the rest stays zero');
    });
  });

  group('constants', () {
    // The TV sends only to these ports; they are not negotiable.
    test('match the ports Roku actually uses', () {
      expect(PrivateListening.rtpPort, 6970);
      expect(PrivateListening.rtcpPort, 5150);
      expect(PrivateListening.sampleRate, 48000);
      expect(PrivateListening.channels, 2);
    });
  });
}

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

  group('RTCP receiver report', () {
    // The TV stops streaming unless these keep arriving and describe its own
    // stream, so both the shape and the contents matter.
    test('carries a header and exactly one report block', () {
      final report = PrivateListening.buildReceiverReport(
        ourSsrc: 0x11223344,
        senderSsrc: 0xAABBCCDD,
        highestSequence: 0x1234,
      );
      expect(report.length, 32);
      expect(report[0] >> 6, 2, reason: 'RTP version 2');
      expect(report[0] & 0x1F, 1, reason: 'exactly one reception report block');
      expect(report[1], 201, reason: 'packet type 201 is a receiver report');
      expect((report[2] << 8) | report[3], 7, reason: '8 words minus one');
    });

    test('names our SSRC and the stream being reported on', () {
      final report = PrivateListening.buildReceiverReport(
        ourSsrc: 0x11223344,
        senderSsrc: 0xAABBCCDD,
        highestSequence: 0x1234,
      );
      expect(report.sublist(4, 8), [0x11, 0x22, 0x33, 0x44]);
      expect(report.sublist(8, 12), [0xAA, 0xBB, 0xCC, 0xDD]);
      expect(report.sublist(16, 20), [0x00, 0x00, 0x12, 0x34]);
    });

    test('encodes loss counts across the three-byte field', () {
      final report = PrivateListening.buildReceiverReport(
        ourSsrc: 1,
        senderSsrc: 2,
        highestSequence: 3,
        fractionLost: 0x40,
        cumulativeLost: 0x010203,
      );
      expect(report[12], 0x40);
      expect(report.sublist(13, 16), [0x01, 0x02, 0x03]);
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

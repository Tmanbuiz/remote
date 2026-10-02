import 'package:flutter_test/flutter_test.dart';
import 'package:universal_remote/core/wake_on_lan.dart';

void main() {
  group('WakeOnLan magic packet', () {
    test('is 102 bytes: six 0xFF then the MAC sixteen times', () {
      final packet = WakeOnLan.magicPacket('AA:BB:CC:DD:EE:FF')!;
      expect(packet.length, 102);
      expect(packet.sublist(0, 6), everyElement(0xFF));
      for (var repeat = 0; repeat < 16; repeat++) {
        expect(
          packet.sublist(6 + repeat * 6, 6 + repeat * 6 + 6),
          [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF],
          reason: 'repetition $repeat should carry the MAC',
        );
      }
    });

    test('accepts the separators TVs actually report', () {
      const expected = [0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E];
      for (final mac in ['00:1a:2b:3c:4d:5e', '00-1A-2B-3C-4D-5E', '001a2b3c4d5e']) {
        expect(WakeOnLan.parseMac(mac), expected, reason: mac);
      }
    });

    test('rejects anything that is not six hex octets', () {
      for (final mac in [null, '', 'not-a-mac', 'AA:BB:CC:DD:EE', 'AA:BB:CC:DD:EE:FF:00', 'ZZ:BB:CC:DD:EE:FF']) {
        expect(WakeOnLan.parseMac(mac), isNull, reason: '$mac');
        expect(WakeOnLan.magicPacket(mac), isNull, reason: '$mac');
      }
    });

    // An unknown MAC deserialises as all zeroes; broadcasting that wakes
    // nothing and would make the UI claim it had done something.
    test('rejects an all-zero MAC', () {
      expect(WakeOnLan.parseMac('00:00:00:00:00:00'), isNull);
      expect(WakeOnLan.magicPacket('00-00-00-00-00-00'), isNull);
    });

    test('wake() reports failure without sending when the MAC is unusable', () async {
      expect(await WakeOnLan.wake(null), isFalse);
      expect(await WakeOnLan.wake('nonsense'), isFalse);
    });
  });
}

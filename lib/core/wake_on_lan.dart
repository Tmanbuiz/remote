import 'dart:io';
import 'dart:typed_data';

/// Wake-on-LAN.
///
/// A TV that is genuinely off has no network stack, so no amount of ECP or
/// WebSocket traffic will reach it — the only thing that wakes it is a magic
/// packet, which the network adapter itself answers while the set sleeps.
///
/// Roku sets with "Fast TV Start" enabled stay reachable in standby and can be
/// woken with a PowerOn key instead; this is the fallback for everything else.
class WakeOnLan {
  const WakeOnLan._();

  /// Builds the 102-byte magic packet: six 0xFF bytes, then the MAC sixteen
  /// times. Returns null when [mac] is not six hex octets.
  static Uint8List? magicPacket(String? mac) {
    final octets = parseMac(mac);
    if (octets == null) return null;
    final packet = Uint8List(6 + 16 * 6);
    for (var i = 0; i < 6; i++) {
      packet[i] = 0xFF;
    }
    for (var repeat = 0; repeat < 16; repeat++) {
      for (var i = 0; i < 6; i++) {
        packet[6 + repeat * 6 + i] = octets[i];
      }
    }
    return packet;
  }

  /// Accepts `AA:BB:CC:DD:EE:FF`, `aa-bb-cc-dd-ee-ff` and `aabbccddeeff`.
  static List<int>? parseMac(String? mac) {
    if (mac == null) return null;
    final cleaned = mac.replaceAll(RegExp(r'[:\-\.\s]'), '');
    if (cleaned.length != 12) return null;
    final octets = <int>[];
    for (var i = 0; i < 12; i += 2) {
      final value = int.tryParse(cleaned.substring(i, i + 2), radix: 16);
      if (value == null) return null;
      octets.add(value);
    }
    // All-zero is what an unknown MAC decodes to; waking it is meaningless.
    if (octets.every((o) => o == 0)) return null;
    return octets;
  }

  /// Broadcasts the packet. Ports 9 and 7 are both used in the wild and some
  /// sets only listen on one, so send to both rather than guess.
  ///
  /// Returns false only when the MAC is unusable or the socket cannot be
  /// opened; a true result means the packet left the phone, which is as much
  /// as wake-on-LAN can ever confirm.
  static Future<bool> wake(String? mac, {String broadcast = '255.255.255.255'}) async {
    final packet = magicPacket(mac);
    if (packet == null) return false;
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      final target = InternetAddress(broadcast);
      for (final port in const [9, 7]) {
        // Repeat each send: a single UDP datagram onto a busy Wi-Fi link is
        // easily dropped, and the packet is idempotent.
        for (var attempt = 0; attempt < 3; attempt++) {
          socket.send(packet, target, port);
        }
      }
      return true;
    } on SocketException {
      return false;
    } finally {
      socket?.close();
    }
  }
}

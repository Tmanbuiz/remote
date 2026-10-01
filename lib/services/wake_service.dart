import 'dart:io';

import 'lan_address.dart';

class WakeService {
  static List<int> packet(String mac) {
    final normalized = mac.replaceAll(RegExp('[:-]'), '');
    if (!RegExp(r'^[0-9a-fA-F]{12}$').hasMatch(normalized)) {
      throw ArgumentError('A valid TV MAC address is required');
    }
    final bytes = [
      for (var i = 0; i < 12; i += 2)
        int.parse(normalized.substring(i, i + 2), radix: 16),
    ];
    return [...List.filled(6, 255), for (var i = 0; i < 16; i++) ...bytes];
  }

  static Future<void> send(String host, String mac) async {
    if (!isPrivateV4(host)) throw ArgumentError('Use a local TV address');
    final bytes = packet(mac);
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      socket.broadcastEnabled = true;
      socket.send(bytes, InternetAddress(host), 9);
      socket.send(bytes, InternetAddress('255.255.255.255'), 9);
    } finally {
      socket.close();
    }
  }
}

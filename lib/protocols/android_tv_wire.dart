import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'protobuf_wire.dart';
import 'tv_certificate.dart';

class AndroidTvWire {
  static List<int> pairing(int tag, List<int> body) => [
    ...Proto.number(1, 2),
    ...Proto.number(2, 200),
    ...Proto.bytes(tag, body),
  ];
  static List<int> requestPairing() => pairing(10, [
    ...Proto.text(1, 'atvremote'),
    ...Proto.text(2, 'WianTribe Remote'),
  ]);
  static List<int> pairingOptions() => pairing(20, [
    ...Proto.bytes(1, [...Proto.number(1, 3), ...Proto.number(2, 6)]),
    ...Proto.number(3, 1),
  ]);
  static List<int> pairingConfiguration() => pairing(30, [
    ...Proto.bytes(1, [...Proto.number(1, 3), ...Proto.number(2, 6)]),
    ...Proto.number(2, 1),
  ]);

  static Uint8List secret(String pin, String clientPem, String serverPem) {
    final normalized = pin.trim().toUpperCase();
    if (!RegExp(r'^[0-9A-F]{6}$').hasMatch(normalized)) {
      throw const FormatException(
        'Enter the six-character code shown on the TV.',
      );
    }
    final client = certificateRsa(clientPem);
    final server = certificateRsa(serverPem);
    List<int> bigBytes(BigInt n) {
      var hex = n.toRadixString(16);
      if (hex.length.isOdd) hex = '0$hex';
      return [
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ];
    }

    final hash = Uint8List.fromList(
      sha256.convert([
        ...bigBytes(client.modulus),
        ...bigBytes(client.exponent),
        ...bigBytes(server.modulus),
        ...bigBytes(server.exponent),
        int.parse(normalized.substring(2, 4), radix: 16),
        int.parse(normalized.substring(4, 6), radix: 16),
      ]).bytes,
    );
    if (hash.first != int.parse(normalized.substring(0, 2), radix: 16)) {
      throw const FormatException('The pairing code does not match this TV.');
    }
    return hash;
  }

  static List<int> key(int code) =>
      Proto.bytes(10, [...Proto.number(1, code), ...Proto.number(2, 3)]);
  static List<int> configuration(int features) => Proto.bytes(1, [
    ...Proto.number(1, features),
    ...Proto.bytes(2, [
      ...Proto.number(3, 1),
      ...Proto.text(4, '1'),
      ...Proto.text(5, 'com.wiantribe.universal_remote'),
      ...Proto.text(6, '1.1.0'),
    ]),
  ]);
  static List<int> text(String text, int counter, int field) {
    if (text.isEmpty || text.length > 4096) {
      throw const FormatException('Enter up to 4096 characters.');
    }
    return Proto.bytes(21, [
      ...Proto.number(1, counter),
      ...Proto.number(2, field),
      ...Proto.bytes(3, [
        ...Proto.number(1, 1),
        ...Proto.bytes(2, [
          ...Proto.number(1, text.length - 1),
          ...Proto.number(2, text.length - 1),
          ...Proto.text(3, text),
        ]),
      ]),
    ]);
  }
}

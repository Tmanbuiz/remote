import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import '../storage/credential_store.dart';

class ClientIdentity {
  const ClientIdentity(this.certificate, this.privateKey);
  final String certificate;
  final String privateKey;

  SecurityContext context() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certificate))
    ..usePrivateKeyBytes(utf8.encode(privateKey));

  static Future<ClientIdentity> load(CredentialStore store) async {
    final saved = await readOrCreateCredential(store, 'android-tv:identity',
        () => Isolate.run(_generate));
    return ClientIdentity(saved['certificate'] as String, saved['privateKey'] as String);
  }

  static Map<String, dynamic> _generate() {
    final pair = CryptoUtils.generateRSAKeyPair();
    final private = pair.privateKey as RSAPrivateKey;
    final public = pair.publicKey as RSAPublicKey;
    final csr = X509Utils.generateRsaCsrPem(
      {'CN': 'WianTribe Remote'}, private, public);
    return {
      'certificate': X509Utils.generateSelfSignedCertificate(private, csr, 3650),
      'privateKey': CryptoUtils.encodeRSAPrivateKeyToPem(private),
    };
  }
}

Uint8List certificateDer(String pem) => base64Decode(pem
    .replaceAll(RegExp(r'-----[^-]+-----'), '').replaceAll(RegExp(r'\s'), ''));
String certificateFingerprint(String pem) => sha256.convert(certificateDer(pem)).toString();

/// Extract the RSA SubjectPublicKeyInfo without accepting arbitrary ASN.1 trees.
/// Android's pairing secret binds both certificates to the displayed code.
({BigInt modulus, BigInt exponent}) certificateRsa(String pem) {
  final cert = _Der.children(certificateDer(pem));
  if (cert.isEmpty) throw const FormatException('Invalid certificate');
  final tbs = _Der.children(cert.first.content);
  final index = tbs.first.tag == 0xa0 ? 6 : 5;
  if (tbs.length <= index) throw const FormatException('No certificate public key');
  final spki = _Der.children(tbs[index].content);
  if (spki.length != 2 || spki[1].tag != 3 || spki[1].content.first != 0) {
    throw const FormatException('Unsupported certificate public key');
  }
  final rsa = _Der.children(spki[1].content.sublist(1));
  if (rsa.length != 2 || rsa.any((x) => x.tag != 2)) {
    throw const FormatException('Android TV requires an RSA certificate');
  }
  BigInt integer(List<int> bytes) => BigInt.parse(
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(), radix: 16);
  return (modulus: integer(rsa[0].content), exponent: integer(rsa[1].content));
}

class _Der {
  const _Der(this.tag, this.content);
  final int tag;
  final Uint8List content;

  static List<_Der> children(List<int> encoded) {
    // Input is an encoded sequence for certificates/SPKI/RSA, or the content
    // of the TBSCertificate sequence after its wrapper was removed.
    var bytes = Uint8List.fromList(encoded);
    if (bytes.isNotEmpty && bytes.first == 0x30) {
      final wrapper = _read(bytes, 0);
      if (wrapper.next == bytes.length) bytes = wrapper.value.content;
    }
    final out = <_Der>[];
    var pos = 0;
    while (pos < bytes.length) {
      final item = _read(bytes, pos);
      out.add(item.value); pos = item.next;
    }
    return out;
  }

  static ({_Der value, int next}) _read(Uint8List b, int p) {
    if (p + 2 > b.length) throw const FormatException('Truncated DER');
    final tag = b[p++];
    var length = b[p++];
    if (length >= 128) {
      final count = length & 127;
      if (count == 0 || count > 4 || p + count > b.length) {
        throw const FormatException('Invalid DER length');
      }
      length = 0;
      for (var i = 0; i < count; i++) { length = (length << 8) | b[p++]; }
    }
    if (p + length > b.length) throw const FormatException('Truncated DER value');
    return (value: _Der(tag, Uint8List.sublistView(b, p, p + length)), next: p + length);
  }
}

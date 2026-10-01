import 'dart:io';

bool isPrivateV4(String host) {
  final address = InternetAddress.tryParse(host);
  if (address == null || address.type != InternetAddressType.IPv4) return false;
  final p = address.rawAddress;
  return p[0] == 10 ||
      (p[0] == 192 && p[1] == 168) ||
      (p[0] == 172 && p[1] >= 16 && p[1] <= 31);
}

/// Description/pointer endpoints must stay on the device that advertised them.
bool isDeviceEndpoint(Uri uri, String host) =>
    isPrivateV4(host) &&
    uri.host == host &&
    const ['http', 'https', 'ws', 'wss'].contains(uri.scheme) &&
    uri.userInfo.isEmpty;

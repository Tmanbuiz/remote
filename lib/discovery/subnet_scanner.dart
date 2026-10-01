import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/tv_device.dart';
import '../services/lan_address.dart';

/// Finds TVs by probing every address on the local /24 directly.
///
/// This exists because of an iOS platform restriction, not as an optimisation.
/// Since iOS 14, sending to a multicast group (which is exactly what SSDP's
/// 239.255.255.250 is) requires the `com.apple.developer.networking.multicast`
/// entitlement, which Apple grants only by special application. Without it
/// multicast datagrams are silently dropped — no error, no results — so an
/// SSDP-only app finds nothing at all on iPhone.
///
/// Plain unicast TCP/HTTP to a LAN address needs only the ordinary Local
/// Network permission, which the user grants from a normal system prompt. So on
/// iOS this scanner is the primary discovery path, and SSDP is the bonus.
///
/// 254 addresses times three ports would be slow done naively, so probes run in
/// bounded parallel batches with short timeouts.
class SubnetScanner {
  SubnetScanner({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// How many probes are in flight at once. Too high and iOS starts refusing
  /// sockets; too low and a sweep takes half a minute.
  static const int _concurrency = 32;

  static const Duration _probeTimeout = Duration(milliseconds: 600);

  /// The IPv4 address of the phone's own Wi-Fi interface, or null when not on
  /// Wi-Fi at all.
  static Future<String?> localAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          final ip = addr.address;
          // Only private ranges are worth sweeping; a public address means
          // cellular, where there is no TV to find.
          if ((iface.name.startsWith('en') ||
                  iface.name.startsWith('wlan') ||
                  iface.name.startsWith('wl')) &&
              isPrivateV4(ip)) {
            return ip;
          }
        }
      }
    } catch (_) {
      // Permission denied or no interfaces — treated as "not on Wi-Fi".
    }
    return null;
  }

  /// Sweeps the /24 the phone sits on. Returns every set that answered.
  Future<List<TvDevice>> scan({
    void Function(int done, int total)? onProgress,
  }) async {
    final local = await localAddress();
    if (local == null) return const [];

    final prefix = local.substring(0, local.lastIndexOf('.'));
    final selfOctet = int.tryParse(local.split('.').last);

    final hosts = <String>[
      for (var i = 1; i <= 254; i++)
        if (i != selfOctet) '$prefix.$i',
    ];

    final found = <TvDevice>[];
    var done = 0;

    for (var i = 0; i < hosts.length; i += _concurrency) {
      final batch = hosts.skip(i).take(_concurrency);
      final results = await Future.wait(batch.map(probeHost));
      for (final device in results) {
        if (device != null) found.add(device);
      }
      done += batch.length;
      onProgress?.call(done, hosts.length);
    }

    return found;
  }

  /// Checks one address for each brand's control port, cheapest first.
  Future<TvDevice?> probeHost(String host) async {
    if (!isPrivateV4(host)) return null;
    // A closed TCP port answers fast, so gate the HTTP probes behind a plain
    // socket check rather than paying an HTTP timeout per brand per host.
    if (await _isPortOpen(host, 8060)) {
      final roku = await _probeRoku(host);
      if (roku != null) return roku;
    }
    if (await _isPortOpen(host, 8001)) {
      final samsung = await _probeSamsung(host);
      if (samsung != null) return samsung;
    }
    // An open port alone cannot establish that a device is an LG TV.
    // LG is identified through its SSDP description or explicit manual setup.
    return null;
  }

  static Future<bool> _isPortOpen(String host, int port) async {
    try {
      final socket = await Socket.connect(host, port, timeout: _probeTimeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<TvDevice?> _probeRoku(String host) async {
    try {
      final res = await _client
          .get(Uri.parse('http://$host:8060/query/device-info'))
          .timeout(const Duration(seconds: 2));
      if (res.statusCode != 200) return null;

      String tag(String name) =>
          RegExp('<$name>([^<]*)</$name>')
              .firstMatch(res.body)
              ?.group(1)
              ?.trim() ??
          '';

      final name = [
        tag('user-device-name'),
        tag('friendly-device-name'),
      ].firstWhere((s) => s.isNotEmpty, orElse: () => 'Roku ($host)');

      return TvDevice(
        id: tag('serial-number').isNotEmpty
            ? 'roku-${tag('serial-number')}'
            : 'roku-$host',
        name: name,
        host: host,
        brand: TvBrand.roku,
        port: 8060,
        model: tag('model-name'),
        macAddress: tag('wifi-mac').isNotEmpty
            ? tag('wifi-mac')
            : tag('ethernet-mac'),
      );
    } catch (_) {
      return null;
    }
  }

  Future<TvDevice?> _probeSamsung(String host) async {
    try {
      final res = await _client
          .get(Uri.parse('http://$host:8001/api/v2/'))
          .timeout(const Duration(seconds: 2));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body);
      final info = body is Map ? body['device'] : null;
      if (info is! Map || info['id'] == null || info['modelName'] == null)
        return null;
      return TvDevice(
        id: 'samsung-${info['id']}',
        name: info['name']?.toString() ?? 'Samsung TV ($host)',
        host: host,
        brand: TvBrand.samsung,
        port: 8002,
        model: info['modelName']?.toString(),
        macAddress: info['wifiMac']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }
}

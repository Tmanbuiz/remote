import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/tv_device.dart';
import 'subnet_scanner.dart';

/// A raw SSDP reply, before we decide what kind of set sent it.
class SsdpResponse {
  SsdpResponse(this.address, this.headers);

  final InternetAddress address;
  final Map<String, String> headers;

  String? operator [](String key) => headers[key.toUpperCase()];
}

/// Finds TVs by UDP multicast, then confirms each one over HTTP.
///
/// SSDP alone is not enough to identify a set: plenty of devices answer
/// `ssdp:all` with headers that name no brand. So discovery runs in two stages
/// — multicast to find candidates, then a targeted probe of the ports each
/// brand is known to listen on.
class SsdpDiscovery {
  SsdpDiscovery({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static final InternetAddress _multicast = InternetAddress('239.255.255.250');
  static const int _ssdpPort = 1900;

  /// Roku answers its own search target and nothing else answers it, which
  /// makes `roku:ecp` a perfectly reliable identifier.
  static const List<String> _searchTargets = [
    'roku:ecp',
    'urn:dial-multiscreen-org:service:dial:1',
    'urn:schemas-upnp-org:device:MediaRenderer:1',
    'ssdp:all',
  ];

  /// Sweeps the LAN and returns every set it could positively identify.
  ///
  /// [timeout] bounds the whole sweep: SSDP has no "done" signal, so we listen
  /// for a fixed window and report whatever arrived.
  Future<List<TvDevice>> discover({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final responses = await _sweep(timeout);

    final found = <String, TvDevice>{};
    await Future.wait(responses.map((r) async {
      final device = await _identify(r);
      if (device != null) {
        // Keyed by id so a set answering several search targets lands once.
        found.putIfAbsent(device.id, () => device);
      }
    }));

    return found.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  Future<List<SsdpResponse>> _sweep(Duration timeout) async {
    RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (e) {
      throw StateError('Could not open a UDP socket for discovery: $e');
    }

    socket.broadcastEnabled = true;
    // TTL 4 covers a home LAN including a mesh hop or two without leaking.
    socket.multicastHops = 4;

    final seen = <String, SsdpResponse>{};
    final done = Completer<void>();

    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final headers = _parseHeaders(utf8.decode(datagram.data, allowMalformed: true));
      if (headers.isEmpty) return;
      final key = '${datagram.address.address}|${headers['USN'] ?? headers['ST'] ?? ''}';
      seen[key] = SsdpResponse(datagram.address, headers);
    }, onError: (_) {}, onDone: () {
      if (!done.isCompleted) done.complete();
    });

    for (final target in _searchTargets) {
      final message = 'M-SEARCH * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 3\r\n'
          'ST: $target\r\n\r\n';
      try {
        socket.send(utf8.encode(message), _multicast, _ssdpPort);
      } catch (_) {
        // A target that cannot be sent is not fatal; the others still run.
      }
      // Staggered so a burst of four datagrams does not get dropped by the AP.
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }

    await Future<void>.delayed(timeout);
    socket.close();
    if (!done.isCompleted) done.complete();

    return seen.values.toList();
  }

  static Map<String, String> _parseHeaders(String raw) {
    final lines = const LineSplitter().convert(raw);
    if (lines.isEmpty) return const {};
    // Only replies are interesting; NOTIFY announcements are handled the same
    // way but M-SEARCH responses start with the status line.
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      headers[line.substring(0, idx).trim().toUpperCase()] =
          line.substring(idx + 1).trim();
    }
    return headers;
  }

  /// Turns a candidate into a [TvDevice], or null if it is not a TV we drive.
  Future<TvDevice?> _identify(SsdpResponse r) async {
    final host = r.address.address;
    final st = (r['ST'] ?? '').toLowerCase();
    final server = (r['SERVER'] ?? '').toLowerCase();
    final usn = r['USN'] ?? host;

    if (st.contains('roku') || server.contains('roku')) {
      return _probeRoku(host, usn);
    }

    // Manufacturer only shows up reliably in the description XML, so fetch it
    // when the headers are inconclusive.
    final location = r['LOCATION'];
    String descriptionName = '';
    String descriptionMaker = '';
    if (location != null) {
      final desc = await _fetchDescription(location);
      if (desc != null) {
        descriptionName = desc.$1;
        descriptionMaker = desc.$2.toLowerCase();
      }
    }

    final haystack = '$server $descriptionMaker';
    if (haystack.contains('hisense') || haystack.contains('vidaa') || haystack.contains('toshiba')) {
      // Hisense is a manufacturer, not a platform. Prefer Roku/Android control
      // services before falling back to a VIDAA descriptor.
      final roku = await _probeRoku(host, usn);
      if (roku != null) return roku;
      return SubnetScanner(client: _client).probeHost(host);
    }

    if (haystack.contains('samsung')) {
      return _probeSamsung(host, usn, descriptionName);
    }
    if (haystack.contains('lg') || haystack.contains('webos')) {
      return TvDevice(
        id: usn,
        name: descriptionName.isEmpty ? 'LG TV ($host)' : descriptionName,
        host: host,
        brand: TvBrand.lg,
        port: 3000,
      );
    }
    if (haystack.contains('sony') || haystack.contains('bravia')) {
      return TvDevice(
        id: usn,
        name: descriptionName.isEmpty ? 'Sony TV ($host)' : descriptionName,
        host: host,
        brand: TvBrand.sony,
        port: 80,
      );
    }
    if (haystack.contains('vizio')) {
      return TvDevice(
        id: usn,
        name: descriptionName.isEmpty ? 'Vizio TV ($host)' : descriptionName,
        host: host,
        brand: TvBrand.vizio,
        port: 7345,
      );
    }

    // Unidentified by headers — try the Roku probe anyway, since an unbranded
    // MediaRenderer reply is a common way Roku TVs show up.
    return _probeRoku(host, usn);
  }

  Future<TvDevice?> _probeRoku(String host, String usn) async {
    try {
      final res = await _client
          .get(Uri.parse('http://$host:8060/query/device-info'))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) return null;
      String tag(String name) {
        final m = RegExp('<$name>([^<]*)</$name>').firstMatch(res.body);
        return m?.group(1)?.trim() ?? '';
      }

      final name = tag('user-device-name').isNotEmpty
          ? tag('user-device-name')
          : (tag('friendly-device-name').isNotEmpty
              ? tag('friendly-device-name')
              : 'Roku ($host)');

      return TvDevice(
        id: tag('serial-number').isNotEmpty ? 'roku-${tag('serial-number')}' : usn,
        name: name,
        host: host,
        brand: TvBrand.roku,
        port: 8060,
        model: tag('model-name'),
        macAddress: tag('wifi-mac').isNotEmpty ? tag('wifi-mac') : tag('ethernet-mac'),
      );
    } catch (_) {
      return null;
    }
  }

  Future<TvDevice?> _probeSamsung(String host, String usn, String fallbackName) async {
    try {
      final res = await _client
          .get(Uri.parse('http://$host:8001/api/v2/'))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body);
      final info = body is Map ? body['device'] : null;
      final name = info is Map
          ? (info['name']?.toString() ?? fallbackName)
          : fallbackName;
      return TvDevice(
        id: info is Map && info['id'] != null ? 'samsung-${info['id']}' : usn,
        name: name.isEmpty ? 'Samsung TV ($host)' : name,
        host: host,
        brand: TvBrand.samsung,
        port: 8002,
        model: info is Map ? info['modelName']?.toString() : null,
        macAddress: info is Map ? info['wifiMac']?.toString() : null,
      );
    } catch (_) {
      // Pre-2016 sets have no /api/v2 endpoint but still answer SSDP.
      return TvDevice(
        id: usn,
        name: fallbackName.isEmpty ? 'Samsung TV ($host)' : fallbackName,
        host: host,
        brand: TvBrand.samsung,
        port: 8002,
      );
    }
  }

  /// Returns `(friendlyName, manufacturer)` from a UPnP description document.
  Future<(String, String)?> _fetchDescription(String location) async {
    try {
      final res = await _client
          .get(Uri.parse(location))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) return null;
      String tag(String name) {
        final m = RegExp('<$name>([^<]*)</$name>', caseSensitive: false)
            .firstMatch(res.body);
        return m?.group(1)?.trim() ?? '';
      }

      return (tag('friendlyName'), tag('manufacturer'));
    } catch (_) {
      return null;
    }
  }
}


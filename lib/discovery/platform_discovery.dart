import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';

import '../core/tv_device.dart';

class PlatformDiscovery {
  static const androidServices = [
    '_androidtvremote2._tcp.local',
    '_androidtvremote._tcp.local',
  ];

  static Future<List<TvDevice>> mdns() async {
    final client = MDnsClient();
    final found = <String, TvDevice>{};
    const channel = MethodChannel('com.wiantribe.remote/discovery');
    try {
      if (Platform.isAndroid) {
        try {
          await channel.invokeMethod<void>('acquireMulticast');
        } catch (_) {}
      }
      await client.start();
      await Future.wait(
        androidServices.map((service) async {
          await for (final ptr in client.lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer(service),
            timeout: const Duration(seconds: 3),
          )) {
            if (found.length >= 24) break;
            await for (final srv in client.lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(ptr.domainName),
              timeout: const Duration(seconds: 2),
            )) {
              if (srv.port != 6466) continue;
              await for (final ip in client.lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(srv.target),
                timeout: const Duration(seconds: 1),
              )) {
                final host = ip.address.address;
                found[host] = TvDevice(
                  id: 'android-$host',
                  name: ptr.domainName.split('._').first,
                  host: host,
                  brand: TvBrand.androidTv,
                  port: 6466,
                  protocolVersion: 2,
                );
              }
            }
          }
        }),
      ).timeout(const Duration(seconds: 7));
    } catch (_) {
      // Unicast probing/manual addresses remain usable when multicast is blocked.
    } finally {
      client.stop();
      if (Platform.isAndroid) {
        try {
          await channel.invokeMethod<void>('releaseMulticast');
        } catch (_) {}
      }
    }
    return found.values.toList();
  }

  static TvDevice? vidaaDescriptor(String xml, String host) {
    String value(String tag) =>
        RegExp(
          '<(?:[\\w-]+:)?$tag(?:\\s[^>]*)?>([^<]*)</',
          caseSensitive: false,
        ).firstMatch(xml)?.group(1)?.trim() ??
        '';
    final maker = value('manufacturer');
    final description = value('modelDescription');
    final text = '$maker $description ${value('modelName')}'.toLowerCase();
    final protocolMatch = RegExp(
      r'transport_protocol(?:\s*[=:]\s*|[^>]*>\s*)(\d+)',
      caseSensitive: false,
    ).firstMatch(xml);
    final protocol = int.tryParse(protocolMatch?.group(1) ?? '');
    if (!text.contains('hisense') &&
        !text.contains('vidaa') &&
        !text.contains('toshiba') &&
        protocol == null) {
      return null;
    }
    final id = value('UDN');
    final friendly = value('friendlyName');
    final firmware = value('softwareVersion');
    return TvDevice(
      id: id.isEmpty ? 'vidaa-$host' : id,
      name: friendly.isEmpty ? 'VIDAA TV ($host)' : friendly,
      host: host,
      brand: TvBrand.vidaa,
      port: 36669,
      model: value('modelName').isEmpty ? null : value('modelName'),
      protocolVersion: protocol,
      firmwareVersion: firmware.isEmpty ? null : firmware,
    );
  }

  static Future<TvDevice> vidaa(http.Client client, String host) async {
    try {
      final request = http.Request(
        'GET',
        Uri.http('$host:38400', '/MediaServer/rendererdevicedesc.xml'),
      )..followRedirects = false;
      final streamed = await client
          .send(request)
          .timeout(const Duration(seconds: 2));
      final response = await http.Response.fromStream(streamed)
          .timeout(const Duration(seconds: 2));
      if (response.statusCode == 200 && response.bodyBytes.length <= 65536) {
        final parsed = vidaaDescriptor(response.body, host);
        if (parsed != null) return parsed;
      }
    } catch (_) {
      /* Some firmware omits the descriptor service. */
    }
    return TvDevice(
      id: 'vidaa-$host',
      name: 'VIDAA TV ($host)',
      host: host,
      brand: TvBrand.vidaa,
      port: 36669,
    );
  }

  static String host(String value) {
    final input = value.trim();
    final address = InternetAddress.tryParse(input);
    if (address == null ||
        address.type != InternetAddressType.IPv4 ||
        address.isMulticast ||
        address.address == '0.0.0.0' ||
        address.address == '255.255.255.255') {
      throw const FormatException(
        'Enter the TV IPv4 address, such as 192.168.1.20, without http:// or a port.',
      );
    }
    return address.address;
  }
}

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/remote_key.dart';
import '../core/tv_protocol.dart';

/// Roku's External Control Protocol: unauthenticated HTTP on port 8060.
///
/// No pairing, no session, no token — every command is a standalone POST. This
/// is the simplest remote protocol of any TV brand, which is why it doubles as
/// the reference implementation for the others.
class RokuProtocol extends TvProtocol {
  RokuProtocol(super.device, {http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;
  bool _reachable = false;

  static const int defaultPort = 8060;

  int get _port => device.port ?? defaultPort;
  Uri _uri(String path) => Uri.parse('http://${device.host}:$_port$path');

  /// ECP key names. Roku ignores unknown names silently, so the map is the only
  /// guard against typos reaching the wire.
  static const Map<RemoteKey, String> _keyNames = {
    RemoteKey.power: 'Power',
    RemoteKey.powerOn: 'PowerOn',
    RemoteKey.powerOff: 'PowerOff',
    RemoteKey.up: 'Up',
    RemoteKey.down: 'Down',
    RemoteKey.left: 'Left',
    RemoteKey.right: 'Right',
    RemoteKey.select: 'Select',
    RemoteKey.back: 'Back',
    RemoteKey.home: 'Home',
    RemoteKey.info: 'Info',
    RemoteKey.volumeUp: 'VolumeUp',
    RemoteKey.volumeDown: 'VolumeDown',
    RemoteKey.mute: 'VolumeMute',
    RemoteKey.channelUp: 'ChannelUp',
    RemoteKey.channelDown: 'ChannelDown',
    RemoteKey.play: 'Play',
    RemoteKey.pause: 'Play', // ECP has one toggle, not separate transport keys.
    RemoteKey.playPause: 'Play',
    RemoteKey.rewind: 'Rev',
    RemoteKey.fastForward: 'Fwd',
    RemoteKey.input: 'InputHDMI1',
  };

  @override
  Set<RemoteKey> get supportedKeys => _keyNames.keys.toSet();

  @override
  bool get requiresPairing => false;

  @override
  bool get isConnected => _reachable;

  @override
  Future<PairingResult> pair() async {
    // Nothing to pair, but confirm the set is really a Roku before we claim it.
    final info = await fetchDeviceInfo();
    if (info == null) {
      return const PairingResult(
        PairingStatus.failed,
        message: 'No Roku responded on port 8060',
      );
    }
    final named = device.copyWith(
      name: info['user-device-name'] ?? info['friendly-device-name'] ?? device.name,
      model: info['model-name'],
      macAddress: info['wifi-mac'] ?? info['ethernet-mac'],
      // A non-empty token keeps `isPaired` true so the UI treats it as ready.
      pairingToken: 'ecp-open',
    );
    device = named;
    return PairingResult(PairingStatus.success, device: named);
  }

  @override
  Future<void> connect() async {
    _reachable = await ping();
    if (!_reachable) {
      throw RemoteTransportException('Roku at ${device.host} did not respond');
    }
  }

  @override
  Future<void> disconnect() async {
    _reachable = false;
  }

  @override
  Future<void> sendKey(RemoteKey key) async {
    final name = _keyNames[key];
    if (name == null) {
      throw UnsupportedError('Roku has no mapping for $key');
    }
    await _post('/keypress/$name');
  }

  @override
  Future<void> sendText(String text) async {
    // ECP takes one character per request as `Lit_<urlencoded>`.
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      await _post('/keypress/Lit_${Uri.encodeComponent(ch)}');
    }
  }

  /// Launches an installed channel by its ECP app id.
  Future<void> launchApp(String appId) => _post('/launch/$appId');

  /// Installed channels as `{appId: name}`, parsed out of the ECP app list.
  Future<Map<String, String>> fetchApps() async {
    final res = await _client.get(_uri('/query/apps'));
    if (res.statusCode != 200) return {};
    final apps = <String, String>{};
    final pattern = RegExp(r'<app id="([^"]+)"[^>]*>([^<]*)</app>');
    for (final m in pattern.allMatches(res.body)) {
      apps[m.group(1)!] = m.group(2)!.trim();
    }
    return apps;
  }

  /// The `/query/device-info` XML, flattened to a tag→text map.
  Future<Map<String, String>?> fetchDeviceInfo() async {
    try {
      final res = await _client
          .get(_uri('/query/device-info'))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) return null;
      final info = <String, String>{};
      final pattern = RegExp(r'<([a-zA-Z0-9\-]+)>([^<]*)</\1>');
      for (final m in pattern.allMatches(res.body)) {
        info[m.group(1)!] = const HtmlEscape().convert(m.group(2)!.trim());
      }
      return info;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> ping() async {
    try {
      final res = await _client
          .get(_uri('/query/device-info'))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> _post(String path) async {
    try {
      final res = await _client
          .post(_uri(path))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode >= 400) {
        throw RemoteTransportException('Roku rejected $path (${res.statusCode})');
      }
    } on RemoteTransportException {
      rethrow;
    } catch (e) {
      throw RemoteTransportException('Roku request $path failed: $e');
    }
  }
}

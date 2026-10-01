import 'package:http/http.dart' as http;

import '../core/remote_key.dart';
import '../core/capabilities.dart';
import '../core/tv_protocol.dart';
import 'roku_ecp2_session.dart';

/// Roku TVs and streaming players.
///
/// Split transport, for a reason worth knowing: **commands go over ECP-2**
/// (see [RokuEcp2Session]) while **discovery stays on plain HTTP**. Roku's
/// "Control by mobile apps" setting has a Limited mode that returns 403 for
/// `POST /keypress/...` and `/query/apps` but still serves
/// `/query/device-info`. A remote built on the HTTP endpoints alone works on a
/// permissive TV and fails on a default one, which is the worst kind of bug —
/// it passes every mocked test and dies on real hardware.
class RokuProtocol extends TvProtocol {
  RokuProtocol(super.device, {http.Client? client, RokuEcp2Session? session})
    : _client = client ?? http.Client(),
      _session = session ?? RokuEcp2Session();

  final http.Client _client;
  final RokuEcp2Session _session;

  static const int defaultPort = 8060;

  int get _port => device.port ?? defaultPort;
  Uri _uri(String path) => Uri.parse('http://${device.host}:$_port$path');

  /// ECP key names, identical on both transports.
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

    // ECP exposes one transport toggle rather than separate play and pause.
    RemoteKey.playPause: 'Play',
    RemoteKey.rewind: 'Rev',
    RemoteKey.fastForward: 'Fwd',
  };

  @override
  Set<RemoteKey> get supportedKeys => _keyNames.keys.toSet();

  @override
  RemoteCapabilities get capabilities => const RemoteCapabilities(
    text: true,
    apps: true,
    search: true,
    acknowledgesKeys: true,
    wake: true,
  );
  @override
  Future<List<RemoteApp>> listApps() async => (await fetchChannels())
      .map(
        (a) => RemoteApp(
          a.id,
          a.name,
          isInput: a.isInput || a.id.startsWith('tvinput.'),
        ),
      )
      .toList();
  @override
  Future<void> openApp(String id) => launchChannel(id);
  @override
  Future<void> search(String text) async {
    await openSearch();
    await sendText(text);
  }

  @override
  bool get requiresPairing => false;

  @override
  bool get isConnected => _session.isOpen;

  /// Roku has no pairing step; this confirms the set is really a Roku and
  /// enriches the record from `/query/device-info`, which stays readable even
  /// when app control is limited.
  @override
  Future<PairingResult> pair() async {
    final info = await fetchDeviceInfo();
    if (info == null) {
      return const PairingResult(
        PairingStatus.failed,
        message: 'No Roku responded on port 8060',
      );
    }
    final named = device.copyWith(
      name:
          info['user-device-name'] ??
          info['friendly-device-name'] ??
          device.name,
      model: info['model-name'],
      macAddress: info['wifi-mac'] ?? info['ethernet-mac'],
      // No token exists, but the UI treats a non-empty value as "ready".
      pairingToken: 'ecp2',
    );
    device = named;
    return PairingResult(PairingStatus.success, device: named);
  }

  @override
  Future<void> connect() => _session.open(device.host);

  @override
  Future<void> disconnect() => _session.close();

  @override
  Future<void> sendKey(RemoteKey key) async {
    final name = _keyNames[key];
    if (name == null) {
      throw UnsupportedError('Roku has no mapping for $key');
    }
    await _session.press(name);
  }

  /// Types into whatever field the TV has focused, one `Lit_` key per
  /// character. Characters outside printable ASCII are percent-encoded, which
  /// is what the TV expects.
  @override
  Future<void> sendText(String text) async {
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      final literal = (rune >= 0x20 && rune < 0x7F)
          ? ch
          : Uri.encodeComponent(ch);
      await _session.press('Lit_$literal');
    }
  }

  /// Opens the TV's own search screen.
  Future<void> openSearch() => _session.press('Search');

  /// Installed channels and TV inputs, live from the set.
  Future<List<RokuChannel>> fetchChannels() => _session.channels();

  /// Opens a channel or input by its Roku id.
  Future<void> launchChannel(String channelId) => _session.launch(channelId);

  /// The `/query/device-info` XML, flattened to a tag→text map.
  Future<Map<String, String>?> fetchDeviceInfo() async {
    try {
      final res = await _client
          .get(_uri('/query/device-info'))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) return null;
      final info = <String, String>{};
      for (final m in RegExp(
        r'<([a-zA-Z0-9\-]+)>([^<]*)</\1>',
      ).allMatches(res.body)) {
        info[m.group(1)!] = m.group(2)!.trim();
      }
      return info;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> ping() async {
    if (_session.isOpen) return true;
    try {
      final res = await _client
          .get(_uri('/query/device-info'))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

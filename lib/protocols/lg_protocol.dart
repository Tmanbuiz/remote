import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:web_socket_channel/io.dart';

import '../core/remote_key.dart';
import '../core/capabilities.dart';
import '../services/lan_address.dart';
import '../core/tv_protocol.dart';

/// LG webOS, over the SSAP protocol.
///
/// webOS splits the remote across **two** sockets, which is the single most
/// surprising thing about this protocol:
///
/// * The main SSAP socket (port 3000) carries volume, media transport, power
///   and app launches as JSON request/response.
/// * D-pad arrows, OK, BACK and HOME are *not* SSAP requests. They go to a
///   separate "pointer input" socket whose path the TV only reveals when asked,
///   and which speaks a plain newline-delimited text format instead of JSON.
///
/// So [_openPointerSocket] runs lazily on the first directional key.
class LgProtocol extends TvProtocol {
  LgProtocol(super.device, {this.appName = 'Universal Remote'});

  final String appName;

  IOWebSocketChannel? _channel;
  IOWebSocketChannel? _pointer;
  StreamSubscription<dynamic>? _sub;
  Completer<PairingResult>? _pairing;
  bool _connected = false;
  bool _establishTrust = false;
  int _nextId = 0;

  final Map<String, Completer<Map<String, dynamic>>> _pending = {};

  static const int insecurePort = 3000;
  static const int securePort = 3001;

  /// Keys the pointer socket handles, by its own button names.
  static const Map<RemoteKey, String> _pointerButtons = {
    RemoteKey.up: 'UP',
    RemoteKey.down: 'DOWN',
    RemoteKey.left: 'LEFT',
    RemoteKey.right: 'RIGHT',
    RemoteKey.select: 'ENTER',
    RemoteKey.back: 'BACK',
    RemoteKey.home: 'HOME',
    RemoteKey.exit: 'EXIT',
    RemoteKey.menu: 'MENU',
    RemoteKey.info: 'INFO',
    RemoteKey.channelUp: 'CHANNELUP',
    RemoteKey.channelDown: 'CHANNELDOWN',
    RemoteKey.digit0: '0',
    RemoteKey.digit1: '1',
    RemoteKey.digit2: '2',
    RemoteKey.digit3: '3',
    RemoteKey.digit4: '4',
    RemoteKey.digit5: '5',
    RemoteKey.digit6: '6',
    RemoteKey.digit7: '7',
    RemoteKey.digit8: '8',
    RemoteKey.digit9: '9',
    RemoteKey.red: 'RED',
    RemoteKey.green: 'GREEN',
    RemoteKey.yellow: 'YELLOW',
    RemoteKey.blue: 'BLUE',
  };

  /// Keys that are ordinary SSAP requests on the main socket.
  static const Map<RemoteKey, String> _ssapUris = {
    RemoteKey.volumeUp: 'ssap://audio/volumeUp',
    RemoteKey.volumeDown: 'ssap://audio/volumeDown',
    RemoteKey.play: 'ssap://media.controls/play',
    RemoteKey.pause: 'ssap://media.controls/pause',
    RemoteKey.stop: 'ssap://media.controls/stop',
    RemoteKey.rewind: 'ssap://media.controls/rewind',
    RemoteKey.fastForward: 'ssap://media.controls/fastForward',
    RemoteKey.powerOff: 'ssap://system/turnOff',
    RemoteKey.power: 'ssap://system/turnOff',
  };

  /// The permission list the TV shows the user on the pairing prompt. Asking
  /// for less than the app uses means silent failures later.
  Map<String, dynamic> get _manifest => {
    'manifestVersion': 1,
    'appVersion': '1.0',
    'signed': {
      'created': '20260101',
      'appId': 'com.wiantribe.universalremote',
      'vendorId': 'com.wiantribe',
      'localizedAppNames': {'': appName},
      'permissions': [
        'TEST_SECURE',
        'CONTROL_INPUT_TEXT',
        'CONTROL_MOUSE_AND_KEYBOARD',
        'READ_INSTALLED_APPS',
        'CONTROL_POWER',
        'CONTROL_DISPLAY',
        'CONTROL_AUDIO',
        'CONTROL_INPUT_MEDIA_PLAYBACK',
        'CONTROL_INPUT_TV',
        'READ_CURRENT_CHANNEL',
        'LAUNCH',
      ],
      'serial': 'universal-remote-0001',
    },
    'permissions': [
      'CONTROL_INPUT_TEXT',
      'CONTROL_MOUSE_AND_KEYBOARD',
      'CONTROL_POWER',
      'CONTROL_AUDIO',
      'CONTROL_INPUT_MEDIA_PLAYBACK',
      'CONTROL_INPUT_TV',
      'READ_INSTALLED_APPS',
      'READ_CURRENT_CHANNEL',
      'LAUNCH',
    ],
  };

  @override
  Set<RemoteKey> get supportedKeys => {
    ..._pointerButtons.keys,
    ..._ssapUris.keys,
    RemoteKey.mute,
  };

  @override
  RemoteCapabilities get capabilities => const RemoteCapabilities(
    text: true,
    apps: true,
    audioState: true,
    wake: true,
  );
  @override
  Future<List<RemoteApp>> listApps() async => (await fetchApps()).entries
      .map((e) => RemoteApp(e.key, e.value))
      .toList();
  @override
  Future<void> openApp(String id) => launchApp(id);
  @override
  Future<AudioState> readAudio() async {
    final p = await _request('ssap://audio/getStatus');
    if (p['mute'] is! bool || p['volume'] is! num)
      throw RemoteTransportException('TV did not return audio state');
    return AudioState(
      muted: p['mute'] as bool,
      volume: (p['volume'] as num).toInt(),
    );
  }

  @override
  Future<void> setMuted(bool value) async {
    await _request('ssap://audio/setMute', {'mute': value});
  }

  @override
  bool get requiresPairing => true;

  @override
  bool get isConnected => _connected;

  Uri _wsUri() {
    final port = device.port ?? insecurePort;
    final scheme = port == securePort ? 'wss' : 'ws';
    return Uri.parse('$scheme://${device.host}:$port');
  }

  HttpClient _permissiveClient() {
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) {
      if (host != device.host) return false;
      final fingerprint = sha256.convert(cert.der).toString();
      final trusted = device.tlsFingerprint;
      if (trusted != null) return trusted == fingerprint;
      if (!_establishTrust) return false;
      device = device.copyWith(tlsFingerprint: fingerprint);
      return true;
    };
    client.connectionTimeout = const Duration(seconds: 8);
    return client;
  }

  Future<void> _open() async {
    await _closeSockets();
    try {
      _channel = IOWebSocketChannel.connect(
        _wsUri(),
        customClient: _permissiveClient(),
        pingInterval: const Duration(seconds: 20),
      );
    } catch (e) {
      throw RemoteTransportException('webOS socket failed: $e');
    }
    _sub = _channel!.stream.listen(
      _onMessage,
      onError: _onSocketDown,
      onDone: () => _onSocketDown('socket closed'),
      cancelOnError: false,
    );
    await _channel!.ready.timeout(const Duration(seconds: 8));
    _register();
  }

  void _register() {
    final payload = <String, dynamic>{
      'forcePairing': false,
      'pairingType': 'PROMPT',
      'manifest': _manifest,
    };
    final key = device.pairingToken;
    if (key != null && key.isNotEmpty) {
      payload['client-key'] = key;
    }
    _channel!.sink.add(
      jsonEncode({'type': 'register', 'id': 'register_0', 'payload': payload}),
    );
  }

  void _onMessage(dynamic raw) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final id = msg['id']?.toString();
    final type = msg['type']?.toString();

    if (type == 'registered') {
      _connected = true;
      final payload = msg['payload'];
      final key = payload is Map ? payload['client-key']?.toString() : null;
      if (key != null && key.isNotEmpty) {
        device = device.copyWith(pairingToken: key);
      }
      _pairing?.complete(PairingResult(PairingStatus.success, device: device));
      _pairing = null;
      return;
    }

    if (type == 'error') {
      final error = msg['error']?.toString() ?? 'unknown error';
      if (id == 'register_0') {
        _connected = false;
        _pairing?.complete(
          PairingResult(PairingStatus.rejected, message: error),
        );
        _pairing = null;
      }
      final waiter = id == null ? null : _pending.remove(id);
      waiter?.completeError(RemoteTransportException(error));
      return;
    }

    if (id != null) {
      final waiter = _pending.remove(id);
      final payload = msg['payload'];
      if (payload is Map && payload['returnValue'] == false) {
        waiter?.completeError(RemoteTransportException('TV refused request'));
      } else {
        waiter?.complete(
          payload is Map<String, dynamic> ? payload : <String, dynamic>{},
        );
      }
    }
  }

  void _onSocketDown(Object error) {
    _connected = false;
    for (final waiter in _pending.values) {
      waiter.completeError(RemoteTransportException('$error'));
    }
    _pending.clear();
    _pairing?.complete(
      PairingResult(PairingStatus.failed, message: 'Connection lost: $error'),
    );
    _pairing = null;
  }

  @override
  Future<PairingResult> pair() async {
    _establishTrust = !device.isPaired;
    final completer = Completer<PairingResult>();
    _pairing = completer;
    try {
      await _open();
    } catch (e) {
      _pairing = null;
      return PairingResult(PairingStatus.failed, message: '$e');
    }
    return completer.future.timeout(
      const Duration(seconds: 40),
      onTimeout: () {
        _pairing = null;
        return const PairingResult(
          PairingStatus.timeout,
          message: 'No response — accept the prompt on the TV',
        );
      },
    );
  }

  @override
  Future<void> connect() async {
    if (!device.isPaired) {
      throw RemoteAuthException('Pair with this TV before connecting');
    }
    final result = await pair();
    if (!result.isSuccess) {
      throw RemoteAuthException(
        result.message ?? 'webOS refused the client key',
      );
    }
  }

  @override
  Future<void> disconnect() async {
    await _closeSockets();
    _connected = false;
  }

  Future<void> _closeSockets() async {
    await _sub?.cancel();
    _sub = null;
    await _pointer?.sink.close();
    _pointer = null;
    await _channel?.sink.close();
    _channel = null;
  }

  /// Asks the TV where its pointer-input endpoint lives, then connects to it.
  /// Cached for the life of the session — the path is stable while connected.
  Future<IOWebSocketChannel> _openPointerSocket() async {
    final existing = _pointer;
    if (existing != null) return existing;

    final payload = await _request(
      'ssap://com.webos.service.networkinput/getPointerInputSocket',
    );
    final path = payload['socketPath']?.toString();
    if (path == null || path.isEmpty) {
      throw RemoteTransportException('TV did not return a pointer socket path');
    }
    if (!isDeviceEndpoint(Uri.parse(path), device.host))
      throw RemoteTransportException('TV returned an unsafe pointer endpoint');
    final socket = IOWebSocketChannel.connect(
      Uri.parse(path),
      customClient: _permissiveClient(),
    );
    // Drained so the socket stays open; the pointer channel is write-only for
    // our purposes but errors still need somewhere to go.
    socket.stream.listen(
      (_) {},
      onError: (_) => _pointer = null,
      onDone: () => _pointer = null,
    );
    try {
      await socket.ready.timeout(const Duration(seconds: 8));
    } catch (_) {
      await socket.sink.close();
      rethrow;
    }
    _pointer = socket;
    return socket;
  }

  Future<Map<String, dynamic>> _request(
    String uri, [
    Map<String, dynamic>? payload,
  ]) async {
    final channel = _channel;
    if (channel == null || !_connected) {
      throw RemoteTransportException('Not connected to ${device.name}');
    }
    final id = 'req_${_nextId++}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    channel.sink.add(
      jsonEncode({
        'type': 'request',
        'id': id,
        'uri': uri,
        'payload': ?payload,
      }),
    );
    return completer.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () {
        _pending.remove(id);
        throw RemoteTransportException('webOS request $uri timed out');
      },
    );
  }

  @override
  Future<void> sendKey(RemoteKey key) async {
    // Mute is a setter, not a toggle command, so it gets its own branch.
    if (key == RemoteKey.mute) {
      final status = await _request('ssap://audio/getStatus');
      if (status['mute'] is! bool) {
        throw RemoteTransportException('TV did not return mute state');
      }
      final muted = status['mute'] == true;
      await _request('ssap://audio/setMute', {'mute': !muted});
      return;
    }

    final uri = _ssapUris[key];
    if (uri != null) {
      await _request(uri);
      return;
    }

    final button = _pointerButtons[key];
    if (button != null) {
      final socket = await _openPointerSocket();
      // The pointer protocol is newline-delimited text terminated by a blank
      // line — not JSON, unlike everything else on this TV.
      socket.sink.add('type:button\nname:$button\n\n');
      return;
    }

    throw UnsupportedError('webOS has no mapping for $key');
  }

  @override
  Future<void> sendText(String text) async {
    await _request('ssap://com.webos.service.ime/insertText', {
      'text': text,
      'replace': false,
    });
  }

  /// Installed apps as `{appId: title}`.
  Future<Map<String, String>> fetchApps() async {
    final payload = await _request(
      'ssap://com.webos.applicationManager/listApps',
    );
    final apps = <String, String>{};
    final list = payload['apps'];
    if (list is List) {
      for (final app in list) {
        if (app is Map) {
          final id = app['id']?.toString();
          final title = app['title']?.toString() ?? id;
          if (id != null) apps[id] = title!;
        }
      }
    }
    return apps;
  }

  Future<void> launchApp(String appId) =>
      _request('ssap://system.launcher/launch', {'id': appId});

  @override
  Future<bool> ping() async {
    if (_connected) return true;
    try {
      final socket = await Socket.connect(
        device.host,
        device.port ?? insecurePort,
        timeout: const Duration(seconds: 3),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}

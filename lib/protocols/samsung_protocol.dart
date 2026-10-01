import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:web_socket_channel/io.dart';

import '../core/remote_key.dart';
import '../core/capabilities.dart';
import '../core/tv_protocol.dart';

/// Samsung Tizen sets (2016 and later).
///
/// Two things make this adapter fiddly, and both are the TV's doing:
///
/// 1. Port 8002 is TLS with a **self-signed** certificate, so the handshake
///    only completes if we explicitly accept an untrusted cert for this host.
/// 2. The token is issued exactly once, in the `ms.channel.connect` event right
///    after the user accepts the on-screen prompt. Lose it and the user has to
///    walk back to the TV, so it is persisted the moment it arrives.
class SamsungProtocol extends TvProtocol {
  SamsungProtocol(super.device, {this.appName = 'Universal Remote'});

  final String appName;

  IOWebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Completer<PairingResult>? _pairing;
  bool _connected = false;
  bool _establishTrust = false;

  static const int securePort = 8002;
  static const int insecurePort = 8001;

  /// Tizen key codes. Samsung accepts many more; these are the ones a physical
  /// remote actually exposes.
  static const Map<RemoteKey, String> _keyCodes = {
    RemoteKey.power: 'KEY_POWER',
    RemoteKey.powerOff: 'KEY_POWEROFF',
    RemoteKey.powerOn: 'KEY_POWERON',
    RemoteKey.up: 'KEY_UP',
    RemoteKey.down: 'KEY_DOWN',
    RemoteKey.left: 'KEY_LEFT',
    RemoteKey.right: 'KEY_RIGHT',
    RemoteKey.select: 'KEY_ENTER',
    RemoteKey.back: 'KEY_RETURN',
    RemoteKey.home: 'KEY_HOME',
    RemoteKey.menu: 'KEY_MENU',
    RemoteKey.exit: 'KEY_EXIT',
    RemoteKey.info: 'KEY_INFO',
    RemoteKey.volumeUp: 'KEY_VOLUP',
    RemoteKey.volumeDown: 'KEY_VOLDOWN',
    RemoteKey.mute: 'KEY_MUTE',
    RemoteKey.channelUp: 'KEY_CHUP',
    RemoteKey.channelDown: 'KEY_CHDOWN',
    RemoteKey.play: 'KEY_PLAY',
    RemoteKey.pause: 'KEY_PAUSE',
    RemoteKey.playPause: 'KEY_PLAY_BACK',
    RemoteKey.stop: 'KEY_STOP',
    RemoteKey.rewind: 'KEY_REWIND',
    RemoteKey.fastForward: 'KEY_FF',
    RemoteKey.record: 'KEY_REC',
    RemoteKey.input: 'KEY_SOURCE',
    RemoteKey.digit0: 'KEY_0',
    RemoteKey.digit1: 'KEY_1',
    RemoteKey.digit2: 'KEY_2',
    RemoteKey.digit3: 'KEY_3',
    RemoteKey.digit4: 'KEY_4',
    RemoteKey.digit5: 'KEY_5',
    RemoteKey.digit6: 'KEY_6',
    RemoteKey.digit7: 'KEY_7',
    RemoteKey.digit8: 'KEY_8',
    RemoteKey.digit9: 'KEY_9',
    RemoteKey.red: 'KEY_RED',
    RemoteKey.green: 'KEY_GREEN',
    RemoteKey.yellow: 'KEY_YELLOW',
    RemoteKey.blue: 'KEY_BLUE',
  };

  @override
  Set<RemoteKey> get supportedKeys => _keyCodes.keys.toSet();

  @override
  RemoteCapabilities get capabilities =>
      const RemoteCapabilities(text: true, wake: true);

  @override
  bool get requiresPairing => true;

  @override
  bool get isConnected => _connected;

  Uri _wsUri() {
    final port = device.port ?? securePort;
    final scheme = port == insecurePort ? 'ws' : 'wss';
    final name = base64.encode(utf8.encode(appName));
    final token = device.pairingToken;
    final query = StringBuffer('name=$name');
    // Sending a stale token is worse than sending none: the TV closes the
    // socket instead of re-prompting.
    if (token != null && token.isNotEmpty && token != 'pending') {
      query.write('&token=$token');
    }
    return Uri.parse(
      '$scheme://${device.host}:$port/api/v2/channels/samsung.remote.control?$query',
    );
  }

  /// Tizen ships a self-signed cert, so first explicit pairing records the certificate
  /// fingerprint. Reconnect rejects a changed self-signed certificate.
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
    await _closeSocket();
    try {
      _channel = IOWebSocketChannel.connect(
        _wsUri(),
        customClient: _permissiveClient(),
        pingInterval: const Duration(seconds: 20),
      );
    } catch (e) {
      throw RemoteTransportException('Samsung socket failed: $e');
    }
    _sub = _channel!.stream.listen(
      _onMessage,
      onError: _onSocketDown,
      onDone: () => _onSocketDown('socket closed'),
      cancelOnError: false,
    );
    await _channel!.ready.timeout(const Duration(seconds: 8));
  }

  void _onMessage(dynamic raw) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    switch (msg['event']) {
      case 'ms.channel.connect':
        _connected = true;
        final data = msg['data'];
        final token = data is Map ? data['token']?.toString() : null;
        if (token != null && token.isNotEmpty) {
          device = device.copyWith(pairingToken: token);
        }
        _pairing?.complete(
          PairingResult(PairingStatus.success, device: device),
        );
        _pairing = null;

      case 'ms.channel.unauthorized':
        _connected = false;
        _pairing?.complete(
          const PairingResult(
            PairingStatus.rejected,
            message: 'The TV refused the pairing request',
          ),
        );
        _pairing = null;

      case 'ms.channel.timeOut':
        _connected = false;
        _pairing?.complete(
          const PairingResult(
            PairingStatus.timeout,
            message: 'The TV prompt timed out',
          ),
        );
        _pairing = null;
    }
  }

  void _onSocketDown(Object error) {
    _connected = false;
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
    // The prompt sits on screen for about half a minute; outlast it slightly.
    return completer.future.timeout(
      const Duration(seconds: 35),
      onTimeout: () {
        _pairing = null;
        return const PairingResult(
          PairingStatus.timeout,
          message: 'No response from the TV — accept the prompt on screen',
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
        result.message ?? 'Samsung refused the session',
      );
    }
  }

  @override
  Future<void> disconnect() async {
    await _closeSocket();
    _connected = false;
  }

  Future<void> _closeSocket() async {
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
  }

  @override
  Future<void> sendKey(RemoteKey key) async {
    final code = _keyCodes[key];
    if (code == null) {
      throw UnsupportedError('Samsung has no mapping for $key');
    }
    _send({
      'method': 'ms.remote.control',
      'params': {
        'Cmd': 'Click',
        'DataOfCmd': code,
        'Option': 'false',
        'TypeOfRemote': 'SendRemoteKey',
      },
    });
  }

  @override
  Future<void> sendText(String text) async {
    _send({
      'method': 'ms.remote.control',
      'params': {
        'Cmd': base64.encode(utf8.encode(text)),
        'DataOfCmd': 'base64',
        'TypeOfRemote': 'SendInputString',
      },
    });
  }

  void _send(Map<String, dynamic> payload) {
    final channel = _channel;
    if (channel == null || !_connected) {
      throw RemoteTransportException('Not connected to ${device.name}');
    }
    channel.sink.add(jsonEncode(payload));
  }

  /// Port 8001 answers `/api/v2/` unauthenticated, which makes it a reliable
  /// liveness probe that does not disturb the control socket.
  @override
  Future<bool> ping() async {
    final client = _permissiveClient();
    try {
      final req = await client
          .getUrl(Uri.parse('http://${device.host}:$insecurePort/api/v2/'))
          .timeout(const Duration(seconds: 3));
      final res = await req.close().timeout(const Duration(seconds: 3));
      await res.drain<void>();
      return res.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}

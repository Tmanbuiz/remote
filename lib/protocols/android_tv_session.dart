import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/tv_protocol.dart';
import 'android_tv_wire.dart';
import 'protobuf_wire.dart';
import 'tv_certificate.dart';

abstract class AndroidTvTransport {
  Stream<Uint8List> get messages;
  String get peerCertificate;
  Future<void> send(List<int> message);
  Future<void> close();
}

typedef AndroidTvConnector = Future<AndroidTvTransport> Function(
  String host,
  int port,
  ClientIdentity identity,
  String? fingerprint,
);

class SecureAndroidTvTransport implements AndroidTvTransport {
  SecureAndroidTvTransport._(this._socket) {
    _subscription = _socket.listen(
      (chunk) {
        try {
          for (final frame in _frames.add(chunk)) {
            _messages.add(frame);
          }
        } catch (error, stack) {
          _messages.addError(error, stack);
          _socket.destroy();
        }
      },
      onError: (Object error, StackTrace stack) {
        _messages.addError(error, stack);
      },
      onDone: () {
        unawaited(_messages.close());
      },
    );
  }
  final SecureSocket _socket;
  final _frames = ProtoFrames();
  final _messages = StreamController<Uint8List>();
  late final StreamSubscription<Uint8List> _subscription;

  static Future<AndroidTvTransport> connect(
    String host,
    int port,
    ClientIdentity identity,
    String? fingerprint,
  ) async {
    final socket = await SecureSocket.connect(
      host,
      port,
      context: identity.context(),
      timeout: const Duration(seconds: 8),
      onBadCertificate: (cert) =>
          fingerprint == null ||
          certificateFingerprint(cert.pem) == fingerprint,
    );
    final peer = socket.peerCertificate;
    if (peer == null ||
        (fingerprint != null &&
            certificateFingerprint(peer.pem) != fingerprint)) {
      socket.destroy();
      throw RemoteAuthException(
        'The TV certificate changed. Pair this TV again.',
      );
    }
    return SecureAndroidTvTransport._(socket);
  }

  @override
  Stream<Uint8List> get messages => _messages.stream;
  @override
  String get peerCertificate => _socket.peerCertificate!.pem;
  @override
  Future<void> send(List<int> message) async {
    _socket.add(Proto.frame(message));
    await _socket.flush();
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    _socket.destroy();
    await _messages.close();
  }
}

/// Each pairing/control session owns its socket and outstanding handshake.
/// Codes are never logged, and commands are allowed only after RemoteStart.
class AndroidTvSession {
  AndroidTvSession({AndroidTvConnector? connector})
    : _connector = connector ?? SecureAndroidTvTransport.connect;
  final AndroidTvConnector _connector;
  AndroidTvTransport? _transport;
  StreamSubscription<Uint8List>? _subscription;
  Completer<void>? _pairReady, _pairFinished, _controlReady;
  bool _pairing = false;
  bool _configured = false;
  bool isReady = false;
  int features = 0;
  int _imeCounter = 0, _fieldCounter = 0;
  bool _hasTextField = false;
  String model = '', serviceVersion = '';
  // PING=1, KEY=2, IME=4, POWER=32, VOLUME=64, APP_LINK=512.
  static const requestedFeatures = 1 | 2 | 4 | 32 | 64 | 512;

  String get peerCertificate => _transport!.peerCertificate;

  Future<void> beginPairing(
    String host,
    ClientIdentity identity, {
    int port = 6467,
  }) async {
    await close();
    _pairing = true;
    _pairReady = Completer<void>();
    _pairReady!.future.ignore();
    try {
      _transport = await _connector(host, port, identity, null);
      _listen();
      await _transport!.send(AndroidTvWire.requestPairing());
      await _pairReady!.future.timeout(const Duration(seconds: 12));
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<String> finishPairing(String pin, ClientIdentity identity) async {
    if (!_pairing || _transport == null) {
      throw RemoteAuthException('Start pairing again to obtain a new TV code.');
    }
    final digest = AndroidTvWire.secret(
      pin,
      identity.certificate,
      peerCertificate,
    );
    _pairFinished = Completer<void>();
    _pairFinished!.future.ignore();
    await _transport!.send(AndroidTvWire.pairing(40, Proto.bytes(1, digest)));
    await _pairFinished!.future.timeout(const Duration(seconds: 12));
    final fingerprint = certificateFingerprint(peerCertificate);
    await close();
    return fingerprint;
  }

  Future<void> connect(
    String host,
    int port,
    ClientIdentity identity,
    String fingerprint,
  ) async {
    await close();
    _pairing = false;
    _controlReady = Completer<void>();
    _controlReady!.future.ignore();
    try {
      _transport = await _connector(host, port, identity, fingerprint);
      _listen();
      await _controlReady!.future.timeout(const Duration(seconds: 12));
    } catch (_) {
      await close();
      rethrow;
    }
  }

  void _listen() {
    _subscription = _transport!.messages.listen(
      (message) {
        try {
          _handle(message);
        } catch (error) {
          _fail(error);
        }
      },
      onError: (Object error) {
        _fail(error);
      },
      onDone: () {
        _fail(RemoteTransportException('Android TV closed the connection.'));
      },
    );
  }

  void _send(List<int> data) {
    unawaited(
      _transport!.send(data).catchError((Object error) {
        _fail(error);
      }),
    );
  }

  void _handle(Uint8List data) {
    final message = Proto.decode(data);
    if (_pairing) {
      if (Proto.integer(message, 2) != 200) {
        throw RemoteAuthException(
          'The TV rejected pairing. Check the displayed code.',
        );
      }
      if (message.containsKey(11)) {
        _send(AndroidTvWire.pairingOptions());
      } else if (message.containsKey(20)) {
        _send(AndroidTvWire.pairingConfiguration());
      } else if (message.containsKey(31)) {
        if (!(_pairReady?.isCompleted ?? true)) _pairReady!.complete();
      } else if (message.containsKey(41)) {
        if (!(_pairFinished?.isCompleted ?? true)) _pairFinished!.complete();
      }
      return;
    }
    if (message.containsKey(1)) {
      final configuration = Proto.nested(message, 1);
      features = Proto.integer(configuration, 1) & requestedFeatures;
      if ((features & 2) == 0) {
        throw RemoteTransportException(
          'This Remote Service does not support key control. Update it on the TV.',
        );
      }
      final info = Proto.nested(configuration, 2);
      model = Proto.string(info, 1);
      serviceVersion = Proto.string(info, 6);
      _configured = true;
      _send(AndroidTvWire.configuration(features));
    } else if (message.containsKey(2)) {
      _send(Proto.bytes(2, Proto.number(1, features)));
    } else if (message.containsKey(8)) {
      _send(
        Proto.bytes(
          9,
          Proto.number(1, Proto.integer(Proto.nested(message, 8), 1)),
        ),
      );
    } else if (message.containsKey(21)) {
      final ime = Proto.nested(message, 21);
      _imeCounter = Proto.integer(ime, 1);
      _fieldCounter = Proto.integer(ime, 2);
      _hasTextField = true;
    } else if (message.containsKey(40)) {
      if (!_configured) {
        throw const FormatException('RemoteStart before configuration');
      }
      isReady = true;
      if (!(_controlReady?.isCompleted ?? true)) _controlReady!.complete();
    } else if (message.containsKey(3)) {
      throw RemoteTransportException(
        'The TV Remote Service rejected the request.',
      );
    }
  }

  void _fail(Object error) {
    isReady = false;
    for (final pending in [_pairReady, _pairFinished, _controlReady]) {
      if (pending != null && !pending.isCompleted) pending.completeError(error);
    }
  }

  Future<void> sendKey(int code) async {
    if (!isReady) {
      throw RemoteTransportException(
        'Connect to the TV before sending a command.',
      );
    }
    await _transport!.send(AndroidTvWire.key(code));
  }

  Future<void> sendText(String text) async {
    if (!isReady || (features & 4) == 0 || !_hasTextField) {
      throw UnsupportedError(
        'Open a text field on the TV before sending text.',
      );
    }
    await _transport!.send(
      AndroidTvWire.text(text, _imeCounter, _fieldCounter),
    );
  }

  Future<void> close() async {
    _fail(RemoteTransportException('Session closed.'));
    isReady = false;
    _configured = false;
    _hasTextField = false;
    await _subscription?.cancel();
    _subscription = null;
    final old = _transport;
    _transport = null;
    if (old != null) await old.close();
  }
}
